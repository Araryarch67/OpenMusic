// A minimal ASIO driver for the ASIO output's end-to-end test under Wine
// (tool/test_asio_wine.sh): two outputs at 44.1 or 48 kHz, in the sample format
// OPENMUSIC_TEST_ASIO_TYPE names (an ASIOSampleType, Int16LSB by default), a 512-frame
// double buffer switched by a timer thread in real time, like a sound card's
// clock would. It keeps what the host wrote, so the test can check the samples
// really arrived (TestDriverStats).
#include <windows.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <mutex>
#include <thread>

#include "asiosys.h"
#include "asio.h"
#include "iasiodrv.h"

// {5C1E4D52-8A4F-4E5B-9D7B-0E6A1F3C2B11}, also registered by the test script.
static const CLSID kClsid = {0x5c1e4d52, 0x8a4f, 0x4e5b, {0x9d, 0x7b, 0x0e, 0x6a, 0x1f, 0x3c, 0x2b, 0x11}};

static std::atomic<long> objects{0};

struct Stats {
  uint64_t frames = 0;      // frames played that carried sound
  int peak = 0;             // loudest sample
  uint64_t mismatched = 0;  // frames where left and right differ
};
static std::mutex stats_mutex;
static Stats stats;

extern "C" __declspec(dllexport) void TestDriverStats(uint64_t* frames, int* peak, uint64_t* mismatched) {
  std::lock_guard<std::mutex> lock(stats_mutex);
  *frames = stats.frames;
  *peak = stats.peak;
  *mismatched = stats.mismatched;
}

namespace {

constexpr long kOutputs = 2;
constexpr long kFrames = 512;

class Driver : public IASIO {
 public:
  Driver() { ++objects; }
  virtual ~Driver() {
    stop();
    --objects;
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
    // ASIO hosts ask for the driver's CLSID as the interface id.
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, kClsid)) {
      *out = static_cast<IASIO*>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return static_cast<ULONG>(++refs_); }
  ULONG STDMETHODCALLTYPE Release() override {
    const long n = --refs_;
    if (n == 0) delete this;
    return static_cast<ULONG>(n);
  }

  ASIOBool init(void*) override { return ASIOTrue; }
  void getDriverName(char* name) override { std::strcpy(name, "OpenMusic Test"); }
  long getDriverVersion() override { return 1; }
  void getErrorMessage(char* s) override { std::strcpy(s, ""); }

  ASIOError start() override {
    if (!callbacks_) return ASE_NotPresent;
    if (running_.exchange(true)) return ASE_OK;
    clock_ = std::thread([this] { Clock(); });
    return ASE_OK;
  }
  ASIOError stop() override {
    running_ = false;
    if (clock_.joinable()) clock_.join();
    return ASE_OK;
  }

  ASIOError getChannels(long* in, long* out) override {
    *in = 0;
    *out = kOutputs;
    return ASE_OK;
  }
  ASIOError getLatencies(long* in, long* out) override {
    *in = 0;
    *out = kFrames;
    return ASE_OK;
  }
  ASIOError getBufferSize(long* min, long* max, long* preferred, long* granularity) override {
    *min = *max = *preferred = kFrames;
    *granularity = 0;
    return ASE_OK;
  }
  ASIOError canSampleRate(ASIOSampleRate rate) override {
    return rate == 44100.0 || rate == 48000.0 ? ASE_OK : ASE_NoClock;
  }
  ASIOError getSampleRate(ASIOSampleRate* rate) override {
    *rate = rate_;
    return ASE_OK;
  }
  ASIOError setSampleRate(ASIOSampleRate rate) override {
    if (canSampleRate(rate) != ASE_OK) return ASE_NoClock;
    rate_ = rate;
    return ASE_OK;
  }
  ASIOError getClockSources(ASIOClockSource* clocks, long* n) override {
    clocks[0] = {};
    clocks[0].index = 0;
    clocks[0].associatedChannel = -1;
    clocks[0].associatedGroup = -1;
    clocks[0].isCurrentSource = ASIOTrue;
    std::strcpy(clocks[0].name, "Internal");
    *n = 1;
    return ASE_OK;
  }
  ASIOError setClockSource(long) override { return ASE_OK; }
  ASIOError getSamplePosition(ASIOSamples* pos, ASIOTimeStamp* stamp) override {
    const uint64_t p = position_.load();
    pos->hi = static_cast<unsigned long>(p >> 32);
    pos->lo = static_cast<unsigned long>(p);
    stamp->hi = stamp->lo = 0;
    return ASE_OK;
  }
  ASIOError getChannelInfo(ASIOChannelInfo* info) override {
    if (info->isInput || info->channel < 0 || info->channel >= kOutputs) return ASE_InvalidParameter;
    info->isActive = ASIOTrue;
    info->channelGroup = 0;
    info->type = type_;
    std::strcpy(info->name, info->channel == 0 ? "Left" : "Right");
    return ASE_OK;
  }
  ASIOError createBuffers(ASIOBufferInfo* infos, long n, long size, ASIOCallbacks* callbacks) override {
    if (size != kFrames || n < 1 || n > kOutputs) return ASE_InvalidMode;
    for (long i = 0; i < n; ++i) {
      if (infos[i].isInput || infos[i].channelNum >= kOutputs) return ASE_InvalidParameter;
      for (int half = 0; half < 2; ++half) {
        infos[i].buffers[half] = buffers_[infos[i].channelNum][half];
      }
    }
    channels_ = n;
    callbacks_ = callbacks;
    return ASE_OK;
  }
  ASIOError disposeBuffers() override {
    stop();
    callbacks_ = nullptr;
    return ASE_OK;
  }
  ASIOError controlPanel() override { return ASE_NotPresent; }
  ASIOError future(long, void*) override { return ASE_InvalidParameter; }
  ASIOError outputReady() override { return ASE_OK; }

 private:
  // Plays one half while the host fills the other, at the current rate.
  void Clock() {
    long index = 0;
    auto next = std::chrono::steady_clock::now();
    while (running_) {
      callbacks_->bufferSwitch(index, ASIOFalse);
      Played(index);  // what the host just filled is what plays next
      index ^= 1;
      position_ += kFrames;
      next += std::chrono::microseconds(static_cast<int64_t>(kFrames * 1e6 / rate_));
      std::this_thread::sleep_until(next);
    }
  }

  // One sample, scaled to 16 bits so every format reports the same peak.
  int Sample(const void* buffer, long f) const {
    const auto* b = static_cast<const uint8_t*>(buffer);
    switch (type_) {
      case ASIOSTInt16LSB: return reinterpret_cast<const int16_t*>(b)[f];
      case ASIOSTInt24LSB: {
        const int32_t v = static_cast<int32_t>(static_cast<uint32_t>(b[f * 3]) << 8 |
                                               static_cast<uint32_t>(b[f * 3 + 1]) << 16 |
                                               static_cast<uint32_t>(b[f * 3 + 2]) << 24);
        return v >> 16;
      }
      case ASIOSTFloat32LSB: return static_cast<int>(std::lround(reinterpret_cast<const float*>(b)[f] * 32768.0));
      default: return reinterpret_cast<const int32_t*>(b)[f] >> 16;  // Int32LSB
    }
  }

  void Played(long index) {
    const void* left = buffers_[0][index];
    const void* right = buffers_[channels_ > 1 ? 1 : 0][index];
    std::lock_guard<std::mutex> lock(stats_mutex);
    for (long f = 0; f < kFrames; ++f) {
      const int l = Sample(left, f);
      if (l != 0) ++stats.frames;
      if (l != Sample(right, f)) ++stats.mismatched;
      stats.peak = std::max(stats.peak, std::abs(l));
    }
  }

  std::atomic<long> refs_{1};
  std::atomic<bool> running_{false};
  std::atomic<uint64_t> position_{0};
  std::thread clock_;
  ASIOCallbacks* callbacks_ = nullptr;
  long channels_ = 0;
  double rate_ = 44100.0;
  const ASIOSampleType type_ = [] {
    const char* t = std::getenv("OPENMUSIC_TEST_ASIO_TYPE");
    return static_cast<ASIOSampleType>(t ? std::atoi(t) : ASIOSTInt16LSB);
  }();
  int32_t samples_[kOutputs][2][kFrames] = {};  // room for the widest supported type
  void* buffers_[kOutputs][2] = {{samples_[0][0], samples_[0][1]}, {samples_[1][0], samples_[1][1]}};
};

class Factory : public IClassFactory {
 public:
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** out) override {
    if (IsEqualIID(riid, IID_IUnknown) || IsEqualIID(riid, IID_IClassFactory)) {
      *out = this;
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
  HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID riid, void** out) override {
    if (outer) return CLASS_E_NOAGGREGATION;
    auto* driver = new Driver();
    const HRESULT hr = driver->QueryInterface(riid, out);
    driver->Release();
    return hr;
  }
  HRESULT STDMETHODCALLTYPE LockServer(BOOL) override { return S_OK; }
};

Factory factory;

}  // namespace

extern "C" __declspec(dllexport) HRESULT STDAPICALLTYPE DllGetClassObject(REFCLSID clsid, REFIID riid, void** out) {
  if (!IsEqualCLSID(clsid, kClsid)) return CLASS_E_CLASSNOTAVAILABLE;
  return factory.QueryInterface(riid, out);
}

extern "C" __declspec(dllexport) HRESULT STDAPICALLTYPE DllCanUnloadNow() { return objects == 0 ? S_OK : S_FALSE; }
