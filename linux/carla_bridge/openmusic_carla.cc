// A LADSPA plugin that runs the user's audio plugins (VST2, LV2, CLAP, ...)
// through Carla, so they can sit in mpv's filter chain like the equalizer:
//
//   af=lavfi=[ladspa=file=<bundle>/lib/libopenmusic_carla.so:plugin=openmusic_carla]
//
// Each instance starts Carla's "rack" (a native plugin that hosts plugins in
// series) and loads the project the user made in Carla's own window:
// $OPENMUSIC_PLUGINS, or $XDG_CONFIG_HOME/openmusic/plugins.carxp.
//
// Carla is loaded with dlopen when an instance starts, so neither building
// nor running the app needs it; without it (or without a project) the audio
// passes through untouched. Only the few Carla declarations used are
// repeated below (their layout is fixed by Carla's ABI, CarlaNative.h).

#include <dlfcn.h>
#include <sys/stat.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// ── LADSPA (ladspa.h, version 1.1) ─────────────────────────────────────────

typedef float LADSPA_Data;
typedef void* LADSPA_Handle;
typedef int LADSPA_PortDescriptor;
typedef int LADSPA_PortRangeHintDescriptor;
typedef int LADSPA_Properties;

struct LADSPA_PortRangeHint {
  LADSPA_PortRangeHintDescriptor HintDescriptor;
  LADSPA_Data LowerBound;
  LADSPA_Data UpperBound;
};

struct LADSPA_Descriptor {
  unsigned long UniqueID;
  const char* Label;
  LADSPA_Properties Properties;
  const char* Name;
  const char* Maker;
  const char* Copyright;
  unsigned long PortCount;
  const LADSPA_PortDescriptor* PortDescriptors;
  const char* const* PortNames;
  const LADSPA_PortRangeHint* PortRangeHints;
  void* ImplementationData;
  LADSPA_Handle (*instantiate)(const LADSPA_Descriptor*, unsigned long sampleRate);
  void (*connect_port)(LADSPA_Handle, unsigned long port, LADSPA_Data* location);
  void (*activate)(LADSPA_Handle);
  void (*run)(LADSPA_Handle, unsigned long sampleCount);
  void (*run_adding)(LADSPA_Handle, unsigned long sampleCount);
  void (*set_run_adding_gain)(LADSPA_Handle, LADSPA_Data gain);
  void (*deactivate)(LADSPA_Handle);
  void (*cleanup)(LADSPA_Handle);
};

static const int kPortInput = 0x1, kPortOutput = 0x2, kPortAudio = 0x8;

// ── Carla native plugin API (CarlaNative.h / CarlaNativePlugin.h / CarlaHost.h) ─

typedef void* NativeHostHandle;
typedef void* NativePluginHandle;
typedef void* CarlaHostHandle;
struct NativeMidiEvent;
struct NativeParameter;
struct NativeMidiProgram;

struct NativeTimeInfoBBT {
  bool valid;
  int32_t bar, beat;
  double tick, barStartTick;
  float beatsPerBar, beatType;
  double ticksPerBeat, beatsPerMinute;
};

struct NativeTimeInfo {
  bool playing;
  uint64_t frame;
  uint64_t usecs;
  NativeTimeInfoBBT bbt;
};

struct NativeHostDescriptor {
  NativeHostHandle handle;
  const char* resourceDir;
  const char* uiName;
  uintptr_t uiParentId;
  uint32_t (*get_buffer_size)(NativeHostHandle);
  double (*get_sample_rate)(NativeHostHandle);
  bool (*is_offline)(NativeHostHandle);
  const NativeTimeInfo* (*get_time_info)(NativeHostHandle);
  bool (*write_midi_event)(NativeHostHandle, const NativeMidiEvent*);
  void (*ui_parameter_changed)(NativeHostHandle, uint32_t, float);
  void (*ui_midi_program_changed)(NativeHostHandle, uint8_t, uint32_t, uint32_t);
  void (*ui_custom_data_changed)(NativeHostHandle, const char*, const char*);
  void (*ui_closed)(NativeHostHandle);
  const char* (*ui_open_file)(NativeHostHandle, bool, const char*, const char*);
  const char* (*ui_save_file)(NativeHostHandle, bool, const char*, const char*);
  intptr_t (*dispatcher)(NativeHostHandle, int opcode, int32_t, intptr_t, void*, float);
};

struct NativePluginDescriptor {
  int category, hints, supports;
  uint32_t audioIns, audioOuts, midiIns, midiOuts, paramIns, paramOuts;
  const char *name, *label, *maker, *copyright;
  NativePluginHandle (*instantiate)(const NativeHostDescriptor*);
  void (*cleanup)(NativePluginHandle);
  uint32_t (*get_parameter_count)(NativePluginHandle);
  const NativeParameter* (*get_parameter_info)(NativePluginHandle, uint32_t);
  float (*get_parameter_value)(NativePluginHandle, uint32_t);
  uint32_t (*get_midi_program_count)(NativePluginHandle);
  const NativeMidiProgram* (*get_midi_program_info)(NativePluginHandle, uint32_t);
  void (*set_parameter_value)(NativePluginHandle, uint32_t, float);
  void (*set_midi_program)(NativePluginHandle, uint8_t, uint32_t, uint32_t);
  void (*set_custom_data)(NativePluginHandle, const char*, const char*);
  void (*ui_show)(NativePluginHandle, bool);
  void (*ui_idle)(NativePluginHandle);
  void (*ui_set_parameter_value)(NativePluginHandle, uint32_t, float);
  void (*ui_set_midi_program)(NativePluginHandle, uint8_t, uint32_t, uint32_t);
  void (*ui_set_custom_data)(NativePluginHandle, const char*, const char*);
  void (*activate)(NativePluginHandle);
  void (*deactivate)(NativePluginHandle);
  void (*process)(NativePluginHandle, float** in, float** out, uint32_t frames, const NativeMidiEvent*, uint32_t);
  // (more fields follow; not used)
};

namespace {

constexpr uint32_t kBlock = 4096;

struct CarlaLib {
  const NativePluginDescriptor* (*rack)() = nullptr;
  CarlaHostHandle (*hostHandle)(const NativePluginDescriptor*, NativePluginHandle) = nullptr;
  void (*freeHostHandle)(CarlaHostHandle) = nullptr;
  bool (*loadProject)(CarlaHostHandle, const char*) = nullptr;
  const char* (*lastError)(CarlaHostHandle) = nullptr;
  uint32_t (*pluginCount)(CarlaHostHandle) = nullptr;
  std::string resources;
  bool ok = false;
};

const CarlaLib& carla() {
  static CarlaLib lib = [] {
    CarlaLib l;
    std::vector<std::string> dirs;
    if (const char* d = getenv("OPENMUSIC_CARLA_LIBS")) dirs.emplace_back(d);
    for (const char* d : {"/usr/lib/carla", "/usr/lib64/carla", "/usr/local/lib/carla", "/usr/lib/x86_64-linux-gnu/carla"})
      dirs.emplace_back(d);
    for (const auto& dir : dirs) {
      void* native = dlopen((dir + "/libcarla_native-plugin.so").c_str(), RTLD_NOW | RTLD_GLOBAL);
      if (!native) continue;
      void* host = dlopen((dir + "/libcarla_host-plugin.so").c_str(), RTLD_NOW | RTLD_GLOBAL);
      if (!host) continue;
      l.rack = reinterpret_cast<decltype(l.rack)>(dlsym(native, "carla_get_native_rack_plugin"));
      l.hostHandle = reinterpret_cast<decltype(l.hostHandle)>(dlsym(native, "carla_create_native_plugin_host_handle"));
      l.freeHostHandle = reinterpret_cast<decltype(l.freeHostHandle)>(dlsym(native, "carla_host_handle_free"));
      l.loadProject = reinterpret_cast<decltype(l.loadProject)>(dlsym(host, "carla_load_project"));
      l.lastError = reinterpret_cast<decltype(l.lastError)>(dlsym(host, "carla_get_last_error"));
      l.pluginCount = reinterpret_cast<decltype(l.pluginCount)>(dlsym(host, "carla_get_current_plugin_count"));
      // Carla looks for its resources next to its libraries' share dir.
      for (const char* r : {"/usr/share/carla/resources", "/usr/local/share/carla/resources"}) {
        struct stat st;
        if (stat(r, &st) == 0) {
          l.resources = r;
          break;
        }
      }
      if (l.resources.empty()) l.resources = dir + "/resources";
      l.ok = l.rack && l.hostHandle && l.loadProject;
      if (l.ok) break;
    }
    if (!l.ok) fprintf(stderr, "openmusic_carla: Carla not found; passing audio through\n");
    return l;
  }();
  return lib;
}

std::string projectPath() {
  if (const char* p = getenv("OPENMUSIC_PLUGINS")) return p;
  std::string base;
  if (const char* x = getenv("XDG_CONFIG_HOME"); x && *x) {
    base = x;
  } else if (const char* h = getenv("HOME")) {
    base = std::string(h) + "/.config";
  }
  return base + "/openmusic/plugins.carxp";
}

struct Instance {
  double rate = 44100;
  LADSPA_Data* ports[4] = {};
  const NativePluginDescriptor* desc = nullptr;
  NativePluginHandle plugin = nullptr;
  CarlaHostHandle host = nullptr;
  NativeHostDescriptor hostDesc{};
  NativeTimeInfo time{};
  bool active = false;
};

uint32_t bufferSize(NativeHostHandle) { return kBlock; }
double sampleRate(NativeHostHandle h) { return static_cast<Instance*>(h)->rate; }
bool isOffline(NativeHostHandle) { return false; }
const NativeTimeInfo* timeInfo(NativeHostHandle h) { return &static_cast<Instance*>(h)->time; }
bool writeMidi(NativeHostHandle, const NativeMidiEvent*) { return false; }
void uiParameter(NativeHostHandle, uint32_t, float) {}
void uiProgram(NativeHostHandle, uint8_t, uint32_t, uint32_t) {}
void uiCustom(NativeHostHandle, const char*, const char*) {}
void uiClosed(NativeHostHandle) {}
const char* uiFile(NativeHostHandle, bool, const char*, const char*) { return nullptr; }
intptr_t dispatch(NativeHostHandle, int, int32_t, intptr_t, void*, float) { return 0; }

LADSPA_Handle instantiate(const LADSPA_Descriptor*, unsigned long rate) {
  auto* in = new Instance;
  in->rate = static_cast<double>(rate);
  in->time.playing = true;
  const CarlaLib& lib = carla();
  if (!lib.ok) return in;
  const std::string project = projectPath();
  struct stat st;
  if (stat(project.c_str(), &st) != 0) return in;  // nothing set up yet: pass through

  in->hostDesc = NativeHostDescriptor{in,        lib.resources.c_str(), "OpenMusic", 0,          bufferSize, sampleRate,
                                      isOffline, timeInfo,              writeMidi,   uiParameter, uiProgram,  uiCustom,
                                      uiClosed,  uiFile,                uiFile,      dispatch};
  in->desc = lib.rack();
  in->plugin = in->desc ? in->desc->instantiate(&in->hostDesc) : nullptr;
  if (!in->plugin) {
    fprintf(stderr, "openmusic_carla: Carla's rack didn't start\n");
    in->desc = nullptr;
    return in;
  }
  in->host = lib.hostHandle(in->desc, in->plugin);
  if (!in->host || !lib.loadProject(in->host, project.c_str())) {
    fprintf(stderr, "openmusic_carla: can't load %s: %s\n", project.c_str(),
            in->host && lib.lastError ? lib.lastError(in->host) : "?");
  }
  return in;
}

void connectPort(LADSPA_Handle h, unsigned long port, LADSPA_Data* data) {
  if (port < 4) static_cast<Instance*>(h)->ports[port] = data;
}

void activate(LADSPA_Handle h) {
  auto* in = static_cast<Instance*>(h);
  if (in->plugin && !in->active) {
    in->desc->activate(in->plugin);
    in->active = true;
  }
}

void deactivate(LADSPA_Handle h) {
  auto* in = static_cast<Instance*>(h);
  if (in->plugin && in->active) {
    in->desc->deactivate(in->plugin);
    in->active = false;
  }
}

void run(LADSPA_Handle h, unsigned long frames) {
  auto* in = static_cast<Instance*>(h);
  if (!in->plugin || !in->active) {
    for (int c = 0; c < 2; c++) {
      if (in->ports[2 + c] != in->ports[c]) memmove(in->ports[2 + c], in->ports[c], frames * sizeof(LADSPA_Data));
    }
    return;
  }
  for (unsigned long done = 0; done < frames;) {
    const uint32_t n = static_cast<uint32_t>(frames - done < kBlock ? frames - done : kBlock);
    float* inputs[2] = {in->ports[0] + done, in->ports[1] + done};
    float* outputs[2] = {in->ports[2] + done, in->ports[3] + done};
    in->desc->process(in->plugin, inputs, outputs, n, nullptr, 0);
    in->time.frame += n;
    done += n;
  }
}

void cleanup(LADSPA_Handle h) {
  auto* in = static_cast<Instance*>(h);
  deactivate(h);
  if (in->host && carla().freeHostHandle) carla().freeHostHandle(in->host);
  if (in->plugin) in->desc->cleanup(in->plugin);
  delete in;
}

const LADSPA_PortDescriptor kPorts[4] = {kPortInput | kPortAudio, kPortInput | kPortAudio, kPortOutput | kPortAudio,
                                         kPortOutput | kPortAudio};
const char* const kPortNames[4] = {"In L", "In R", "Out L", "Out R"};
const LADSPA_PortRangeHint kHints[4] = {};

const LADSPA_Descriptor kDescriptor = {
    0x4F4D4331,  // "OMC1"
    "openmusic_carla",
    0,
    "OpenMusic audio plugins (Carla)",
    "OpenMusic",
    "GPL-3.0-or-later",
    4,
    kPorts,
    kPortNames,
    kHints,
    nullptr,
    instantiate,
    connectPort,
    activate,
    run,
    nullptr,
    nullptr,
    deactivate,
    cleanup,
};

}  // namespace

extern "C" __attribute__((visibility("default"))) const LADSPA_Descriptor* ladspa_descriptor(unsigned long index) {
  return index == 0 ? &kDescriptor : nullptr;
}
