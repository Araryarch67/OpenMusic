#include "asio_host.h"

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "asiosys.h"  // must come first among the SDK headers
#include "asio.h"
#include "asiodrivers.h"
#include "asio_samples.h"

// From the SDK's asiodrivers.cpp.
extern AsioDrivers* asioDrivers;
bool loadAsioDriver(char* name);

namespace {

using openmusic_asio::AsioSampleType;

constexpr int kMaxChannels = 8;
constexpr int kCommonRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

// ── Control thread: every driver call happens here ─────────────────────────

std::mutex task_mutex;
std::condition_variable task_cv;
std::deque<std::function<void()>> tasks;
std::once_flag control_started;

// Runs `f` on the control thread and waits for it.
void OnControl(const std::function<void()>& f) {
  std::call_once(control_started, [] {
    std::thread([] {
      CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
      for (;;) {
        std::function<void()> task;
        {
          std::unique_lock<std::mutex> lock(task_mutex);
          task_cv.wait(lock, [] { return !tasks.empty(); });
          task = std::move(tasks.front());
          tasks.pop_front();
        }
        task();
      }
    }).detach();  // lives as long as the process
  });
  std::mutex m;
  std::condition_variable cv;
  bool done = false;
  {
    std::lock_guard<std::mutex> lock(task_mutex);
    tasks.push_back([&] {
      f();
      std::lock_guard<std::mutex> lock(m);
      done = true;
      cv.notify_one();
    });
  }
  task_cv.notify_one();
  std::unique_lock<std::mutex> lock(m);
  cv.wait(lock, [&] { return done; });
}

// ── Driver state (control thread, except where atomic) ─────────────────────

std::string loaded_driver;
ASIOBufferInfo buffers[kMaxChannels];
AsioSampleType type = AsioSampleType::kInt32LSB;
bool direct = false;  // mpv writes into the driver's buffers itself
int active_channels = 0;
long buffer_frames = 0;
bool output_ready = false;
int running_rate = 0;
ASIOCallbacks callbacks;
std::vector<int32_t> scratch[kMaxChannels];  // for types mpv can't write directly
bool driver_running = false;

// Who gets the driver's callbacks. Swapped only while the driver is stopped.
std::atomic<void*> owner{nullptr};
asio_host_fill_fn owner_fill = nullptr;
asio_host_reset_fn owner_reset = nullptr;

const char* TypeName(AsioSampleType t) {
  switch (t) {
    case AsioSampleType::kInt16LSB: return "Int16LSB";
    case AsioSampleType::kInt24LSB: return "Int24LSB";
    case AsioSampleType::kInt32LSB: return "Int32LSB";
    case AsioSampleType::kFloat32LSB: return "Float32LSB";
    case AsioSampleType::kFloat64LSB: return "Float64LSB";
    case AsioSampleType::kInt32LSB16: return "Int32LSB16";
    case AsioSampleType::kInt32LSB18: return "Int32LSB18";
    case AsioSampleType::kInt32LSB20: return "Int32LSB20";
    case AsioSampleType::kInt32LSB24: return "Int32LSB24";
  }
  return "?";
}

// ── Driver callbacks ───────────────────────────────────────────────────────

void Fill(long index) {
  void* ctx = owner.load(std::memory_order_acquire);
  void* planes[kMaxChannels];
  const long frames = buffer_frames;
  for (int c = 0; c < active_channels; ++c) {
    planes[c] = direct ? buffers[c].buffers[index] : static_cast<void*>(scratch[c].data());
  }
  if (ctx && owner_fill) {
    owner_fill(ctx, planes, frames);
  } else {
    for (int c = 0; c < active_channels; ++c) {
      std::memset(planes[c], 0, static_cast<size_t>(frames) * (direct ? openmusic_asio::SampleBytes(type) : 4));
    }
  }
  if (!direct) {
    for (int c = 0; c < active_channels; ++c) {
      openmusic_asio::Encode(type, scratch[c].data(), 1, static_cast<size_t>(frames), buffers[c].buffers[index]);
    }
  }
  if (output_ready) ASIOOutputReady();
}

void OnBufferSwitch(long index, ASIOBool /*direct*/) { Fill(index); }

ASIOTime* OnBufferSwitchTimeInfo(ASIOTime* params, long index, ASIOBool /*direct*/) {
  Fill(index);
  return params;
}

void RequestReset() {
  void* ctx = owner.load();
  if (ctx && owner_reset) owner_reset(ctx);
}

void OnSampleRateChanged(ASIOSampleRate rate) {
  // Changed behind our back (the driver's control panel, an external clock):
  // mpv has to reopen the output to convert to the new rate.
  if (static_cast<int>(rate) != running_rate) RequestReset();
}

long OnAsioMessage(long selector, long value, void* /*message*/, double* /*opt*/) {
  switch (selector) {
    case kAsioSelectorSupported:
      return value == kAsioEngineVersion || value == kAsioResetRequest || value == kAsioResyncRequest ||
             value == kAsioLatenciesChanged || value == kAsioSupportsTimeInfo;
    case kAsioEngineVersion:
      return 2;
    case kAsioResetRequest:
      // E.g. the buffer size changed in the driver's control panel.
      RequestReset();
      return 1;
    case kAsioResyncRequest:
    case kAsioLatenciesChanged:
      return 1;
    case kAsioSupportsTimeInfo:
      return 0;  // plain bufferSwitch is all this host needs
  }
  return 0;
}

// ── Driver lifetime (control thread) ───────────────────────────────────────

void ExitDriver() {
  if (loaded_driver.empty()) return;
  if (driver_running) ASIOStop();
  driver_running = false;
  ASIODisposeBuffers();
  ASIOExit();
  if (asioDrivers) asioDrivers->removeCurrentDriver();
  loaded_driver.clear();
  active_channels = 0;
}

// The rate to run at when the driver can't do `rate`: the same family
// (44.1 / 48 kHz multiples) first, then the nearest at or below, then above.
int PickRate(int rate) {
  if (ASIOCanSampleRate(rate) == ASE_OK) return rate;
  int best = 0;
  long long best_score = 0;
  for (int r : kCommonRates) {
    if (ASIOCanSampleRate(r) != ASE_OK) continue;
    const bool same_family = (r % 44100 == 0) == (rate % 44100 == 0);
    const long long score = (same_family ? 0 : 1LL << 40) + (r <= rate ? rate - r : (1LL << 39) + r - rate);
    if (!best || score < best_score) {
      best = r;
      best_score = score;
    }
  }
  return best;
}

void Fail(char* error, size_t size, const std::string& message) { std::snprintf(error, size, "%s", message.c_str()); }

int Open(const std::string& name, int channels, int rate, asio_host_info* info, char* error, size_t error_size) {
  ExitDriver();
  std::vector<char> c_name(name.begin(), name.end());
  c_name.push_back('\0');
  if (!loadAsioDriver(c_name.data())) {
    Fail(error, error_size, "couldn't load the ASIO driver \"" + name + "\"");
    return -1;
  }
  ASIODriverInfo driver_info = {};
  driver_info.asioVersion = 2;
  driver_info.sysRef = GetDesktopWindow();
  if (ASIOInit(&driver_info) != ASE_OK) {
    Fail(error, error_size, std::string("the ASIO driver didn't start: ") + driver_info.errorMessage);
    asioDrivers->removeCurrentDriver();
    return -1;
  }
  loaded_driver = name;

  long inputs = 0, outputs = 0;
  long min_size = 0, max_size = 0, preferred = 0, granularity = 0;
  if (ASIOGetChannels(&inputs, &outputs) != ASE_OK || outputs < 1 ||
      ASIOGetBufferSize(&min_size, &max_size, &preferred, &granularity) != ASE_OK) {
    Fail(error, error_size, "the ASIO driver has no usable output");
    ExitDriver();
    return -1;
  }
  active_channels = static_cast<int>(std::min<long>({outputs, static_cast<long>(channels), kMaxChannels}));
  for (int c = 0; c < active_channels; ++c) {
    ASIOChannelInfo channel = {};
    channel.channel = c;
    channel.isInput = ASIOFalse;
    if (ASIOGetChannelInfo(&channel) != ASE_OK || !openmusic_asio::IsSupported(channel.type)) {
      Fail(error, error_size, "the ASIO driver uses a sample format this player can't write (type " +
                                  std::to_string(channel.type) + ")");
      ExitDriver();
      return -1;
    }
    if (c == 0) type = static_cast<AsioSampleType>(channel.type);
    if (static_cast<AsioSampleType>(channel.type) != type) {
      Fail(error, error_size, "the ASIO driver's outputs use different sample formats");
      ExitDriver();
      return -1;
    }
    buffers[c] = {};
    buffers[c].isInput = ASIOFalse;
    buffers[c].channelNum = c;
  }

  const int run_at = PickRate(rate);
  if (run_at && ASIOSetSampleRate(run_at) != ASE_OK) {
    Fail(error, error_size, "the ASIO driver refused " + std::to_string(run_at) + " Hz");
    ExitDriver();
    return -1;
  }
  ASIOSampleRate now = 0;
  ASIOGetSampleRate(&now);
  running_rate = static_cast<int>(now);

  buffer_frames = preferred;
  switch (type) {
    case AsioSampleType::kInt16LSB: info->layout = ASIO_HOST_S16P; direct = true; break;
    case AsioSampleType::kInt32LSB: info->layout = ASIO_HOST_S32P; direct = true; break;
    case AsioSampleType::kFloat32LSB: info->layout = ASIO_HOST_FLOATP; direct = true; break;
    case AsioSampleType::kFloat64LSB: info->layout = ASIO_HOST_DOUBLEP; direct = true; break;
    default: info->layout = ASIO_HOST_S32P; direct = false; break;
  }
  for (int c = 0; c < active_channels; ++c) {
    scratch[c].assign(direct ? 0 : static_cast<size_t>(std::max(preferred, max_size)), 0);
  }
  callbacks.bufferSwitch = OnBufferSwitch;
  callbacks.sampleRateDidChange = OnSampleRateChanged;
  callbacks.asioMessage = OnAsioMessage;
  callbacks.bufferSwitchTimeInfo = OnBufferSwitchTimeInfo;
  if (ASIOCreateBuffers(buffers, active_channels, buffer_frames, &callbacks) != ASE_OK) {
    Fail(error, error_size, "the ASIO driver couldn't create its buffers");
    ExitDriver();
    return -1;
  }
  output_ready = ASIOOutputReady() == ASE_OK;

  long in_latency = 0, out_latency = 0;
  ASIOGetLatencies(&in_latency, &out_latency);
  info->channels = active_channels;
  info->rate = running_rate;
  info->buffer_frames = buffer_frames;
  info->output_latency = out_latency;
  std::snprintf(info->sample_type, sizeof(info->sample_type), "%s", TypeName(type));
  return 0;
}

}  // namespace

extern "C" int asio_host_list(char (*names)[64], int max) {
  int count = 0;
  OnControl([&] {
    // Re-read the registry each time, so a driver installed while the app
    // runs shows up; the list can only be replaced while no driver is loaded.
    if (asioDrivers && loaded_driver.empty()) {
      delete asioDrivers;
      asioDrivers = nullptr;
    }
    if (!asioDrivers) asioDrivers = new AsioDrivers();
    constexpr long kMax = 32;
    char storage[kMax][32];
    char* list[kMax];
    for (long i = 0; i < kMax; ++i) list[i] = storage[i];
    const long n = asioDrivers->getDriverNames(list, kMax);
    for (long i = 0; i < n && count < max; ++i) std::snprintf(names[count++], 64, "%s", list[i]);
  });
  return count;
}

extern "C" int asio_host_open(const char* name, int channels, int rate, asio_host_fill_fn fill,
                              asio_host_reset_fn reset, void* ctx, asio_host_info* info, char* error,
                              size_t error_size) {
  int result = -1;
  OnControl([&] {
    // Whoever had the driver loses it: its callbacks stop with the driver.
    owner = nullptr;
    result = Open(name, channels, rate, info, error, error_size);
    if (result == 0) {
      owner_fill = fill;
      owner_reset = reset;
      owner.store(ctx, std::memory_order_release);
    }
  });
  return result;
}

extern "C" void asio_host_start(void* ctx) {
  OnControl([&] {
    if (owner.load() != ctx || loaded_driver.empty() || driver_running) return;
    driver_running = ASIOStart() == ASE_OK;
  });
}

extern "C" void asio_host_stop(void* ctx) {
  OnControl([&] {
    if (owner.load() != ctx || !driver_running) return;
    ASIOStop();
    driver_running = false;
  });
}

extern "C" void asio_host_close(void* ctx) {
  OnControl([&] {
    if (owner.load() != ctx) return;
    ExitDriver();
    owner = nullptr;
  });
}
