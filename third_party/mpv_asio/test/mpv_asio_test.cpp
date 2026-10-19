// End-to-end test of mpv's "asio" audio output (ao_asio.c) in the libmpv
// built by tool/build_libmpv_windows.sh, run under Wine with test_driver.cpp
// by tool/test_asio_wine.sh. It plays FLAC files the way the app does and
// checks what the driver received.
#include <windows.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>

#include <mpv/client.h>

static int failures = 0;
#define CHECK(cond)                                       \
  do {                                                    \
    if (!(cond)) {                                        \
      std::printf("FAIL line %d: %s\n", __LINE__, #cond); \
      ++failures;                                         \
    }                                                     \
  } while (0)

struct Played {
  uint64_t frames = 0;
  int peak = 0;
  uint64_t mismatched = 0;
};

static Played DriverStats() {
  using Fn = void (*)(uint64_t*, int*, uint64_t*);
  auto fn = reinterpret_cast<Fn>(
      reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"openmusic_test_asio.dll"), "TestDriverStats")));
  Played p;
  if (fn) fn(&p.frames, &p.peak, &p.mismatched);
  return p;
}

static mpv_handle* mpv;

static std::string Get(const char* name) {
  char* v = mpv_get_property_string(mpv, name);
  std::string s = v ? v : "";
  mpv_free(v);
  return s;
}

static void Set(const char* name, const std::string& value) {
  const int err = mpv_set_property_string(mpv, name, value.c_str());
  if (err < 0) {
    std::printf("FAIL setting %s=%s: %s\n", name, value.c_str(), mpv_error_string(err));
    ++failures;
  }
}

struct Run {
  double seconds = 0;
  double slowest_read_ms = 0;  // the longest a property read blocked while playing
  std::string out_format, out_rate;
};

// Plays `file` to the end, reading properties all along like the app's UI
// does; `during` runs once, `at_ms` into playback.
template <typename F>
static Run PlayToEnd(const char* file, int at_ms, F during) {
  Run run;
  const ULONGLONG start = GetTickCount64();
  const char* cmd[] = {"loadfile", file, nullptr};
  mpv_command(mpv, cmd);
  bool done_once = false;
  for (;;) {
    mpv_event* e = mpv_wait_event(mpv, 0.02);
    if (e->event_id == MPV_EVENT_END_FILE) {
      auto* end = static_cast<mpv_event_end_file*>(e->data);
      if (end->reason == MPV_END_FILE_REASON_ERROR) {
        std::printf("FAIL mpv: %s\n", mpv_error_string(end->error));
        ++failures;
      }
      break;
    }
    if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
      auto* m = static_cast<mpv_event_log_message*>(e->data);
      std::printf("  [%s] %s", m->prefix, m->text);
    }
    const ULONGLONG t = GetTickCount64();
    const double pos = std::atof(Get("time-pos").c_str());
    Get("audio-params/samplerate");
    const std::string f = Get("audio-out-params/format");
    const double took = static_cast<double>(GetTickCount64() - t);
    // Not in the last half second: at the end of the playlist mpv waits for
    // the final buffer to play out (ao_drain), with every output.
    const bool playing = pos > 0 && pos < std::atof(Get("duration").c_str()) - 0.5;
    if (playing && took > run.slowest_read_ms) {
      run.slowest_read_ms = took;
      if (getenv("SLOW_READS")) std::printf("  slow read %.0f ms at %llu ms\n", took, GetTickCount64() - start);
    }
    if (!f.empty()) {
      run.out_format = f;
      run.out_rate = Get("audio-out-params/samplerate");
    }
    if (!done_once && GetTickCount64() - start > static_cast<ULONGLONG>(at_ms)) {
      done_once = true;
      during();
    }
    if (GetTickCount64() - start > 20000) {
      std::printf("FAIL playback didn't end\n");
      ++failures;
      break;
    }
  }
  Sleep(300);  // the driver's last buffers
  run.seconds = static_cast<double>(GetTickCount64() - start) / 1000.0;
  return run;
}

static Run PlayToEnd(const char* file) {
  return PlayToEnd(file, 0, [] {});
}

int main(int argc, char** argv) {
  if (argc < 5) {
    std::printf("usage: mpv_asio_test 44k16.flac 48k24.flac 96k24.flac 44k16-6s.flac\n");
    return 2;
  }
  mpv = mpv_create();
  // What AudioEngine sets for an ASIO output.
  Set("audio-device", "asio/OpenMusic Test");
  Set("audio-samplerate", "0");
  Set("volume", "100");
  Set("vid", "no");
  CHECK(mpv_initialize(mpv) >= 0);
  if (getenv("MPV_LOG")) mpv_request_log_messages(mpv, "v");

  // 0. The driver is listed the way the app shows it.
  const std::string devices = Get("audio-device-list");
  CHECK(devices.find("\"name\":\"asio/OpenMusic Test\"") != std::string::npos);
  CHECK(devices.find("\"description\":\"ASIO: OpenMusic Test\"") != std::string::npos);

  // 1. 16-bit / 44.1 kHz: s16 straight into the driver's Int16 buffers, every
  // sample intact, in real time, and mpv stays responsive meanwhile.
  Played before = DriverStats();
  Run r = PlayToEnd(argv[1]);
  Played after = DriverStats();
  std::printf("44.1k/16: %.2f s for 2 s; out %s @ %s; played %llu frames, peak %d; slowest read %.0f ms\n",
              r.seconds, r.out_format.c_str(), r.out_rate.c_str(),
              static_cast<unsigned long long>(after.frames - before.frames), after.peak, r.slowest_read_ms);
  // What mpv must write for the driver's format: its own where mpv has it.
  const char* type = getenv("OPENMUSIC_TEST_ASIO_TYPE");
  const std::string want_format = !type || std::string(type) == "16" ? "s16p"
                                  : std::string(type) == "19"        ? "floatp"
                                                                     : "s32p";
  CHECK(r.out_format == want_format && r.out_rate == "44100");
  CHECK(r.seconds > 1.9 && r.seconds < 3.5);
  CHECK(after.frames - before.frames > 44100 * 19 / 10);
  CHECK(after.peak == 16384);
  CHECK(after.mismatched == 0);
  CHECK(r.slowest_read_ms < 100);

  // 2. 24-bit / 48 kHz: the device follows the song.
  before = DriverStats();
  r = PlayToEnd(argv[2]);
  after = DriverStats();
  std::printf("48k/24: out %s @ %s; played %llu frames; slowest read %.0f ms\n", r.out_format.c_str(),
              r.out_rate.c_str(), static_cast<unsigned long long>(after.frames - before.frames), r.slowest_read_ms);
  CHECK(r.out_rate == "48000");
  CHECK(after.frames - before.frames > 48000 * 19 / 10);
  CHECK(r.slowest_read_ms < 100);

  // 3. 96 kHz, which the driver can't run at: mpv converts to 48 kHz by itself.
  before = DriverStats();
  r = PlayToEnd(argv[3]);
  after = DriverStats();
  std::printf("96k: out %s @ %s; played %llu frames\n", r.out_format.c_str(), r.out_rate.c_str(),
              static_cast<unsigned long long>(after.frames - before.frames));
  CHECK(r.out_rate == "48000");
  CHECK(after.frames - before.frames > 48000 * 19 / 10);

  // 4. Pausing stops the sound within a buffer or two, and resumes.
  before = DriverStats();
  r = PlayToEnd(argv[4], 1500, [] {
    Set("pause", "yes");
    Sleep(100);
    const uint64_t at_pause = DriverStats().frames;
    Sleep(800);
    const uint64_t later = DriverStats().frames;
    std::printf("after pausing: %llu frames still played\n", static_cast<unsigned long long>(later - at_pause));
    CHECK(later - at_pause < 44100 / 20);
    Set("pause", "no");
  });
  after = DriverStats();
  std::printf("6 s with a 0.9 s pause: %.2f s, played %llu frames\n", r.seconds,
              static_cast<unsigned long long>(after.frames - before.frames));
  CHECK(after.frames - before.frames > 44100 * 58 / 10);
  CHECK(r.seconds > 6.5);

  // 5. An output reload mid-song (AudioEngine does one when settings change).
  before = DriverStats();
  r = PlayToEnd(argv[4], 2000, [] {
    const char* reload[] = {"ao-reload", nullptr};
    CHECK(mpv_command(mpv, reload) >= 0);
  });
  after = DriverStats();
  std::printf("ao-reload mid-song: %.2f s, played %llu frames\n", r.seconds,
              static_cast<unsigned long long>(after.frames - before.frames));
  CHECK(after.frames - before.frames > 44100 * 55 / 10);

  // 6. Seeking is instant too: no queue of old audio to play out first.
  {
    const char* load[] = {"loadfile", argv[4], nullptr};
    mpv_command(mpv, load);
    Sleep(1000);
    const ULONGLONG t = GetTickCount64();
    const char* seek[] = {"seek", "4", "absolute", nullptr};
    CHECK(mpv_command(mpv, seek) >= 0);
    std::printf("seek took %llu ms\n", GetTickCount64() - t);
    CHECK(GetTickCount64() - t < 200);
    Sleep(500);
    const double pos = std::atof(Get("time-pos").c_str());
    std::printf("position after seeking to 4 s: %.2f\n", pos);
    CHECK(pos > 4.2 && pos < 5.0);
    const char* stop[] = {"stop", nullptr};
    mpv_command(mpv, stop);
  }

  mpv_terminate_destroy(mpv);
  std::printf(failures == 0 ? "all mpv ASIO tests passed\n" : "%d mpv ASIO test(s) failed\n", failures);
  return failures == 0 ? 0 : 1;
}
