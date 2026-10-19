// The ASIO driver host behind mpv's "asio" audio output (ao_asio.c).
//
// ASIO drivers are COM objects tied to the thread that loaded them, so every
// driver call runs on one control thread of this host; the driver calls back
// on its own real-time thread. Only one driver can be loaded at a time: a new
// open takes the driver over from the previous owner (mpv may create the next
// audio output before it destroys the old one).
#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The planar sample layout the fill callback writes, as mpv formats.
enum asio_host_layout {
  ASIO_HOST_S16P,     // straight into the driver's Int16LSB buffers
  ASIO_HOST_S32P,     // straight into Int32LSB, or converted for 24-bit types
  ASIO_HOST_FLOATP,   // straight into Float32LSB
  ASIO_HOST_DOUBLEP,  // straight into Float64LSB
};

struct asio_host_info {
  int layout;            // enum asio_host_layout
  int channels;          // outputs in use
  int rate;              // what the driver runs at
  long buffer_frames;
  long output_latency;   // frames, as the driver reports it
  char sample_type[16];  // the driver's own format, e.g. "Int24LSB"
};

// On the driver's thread: write `frames` samples of each channel to `planes`.
typedef void (*asio_host_fill_fn)(void *ctx, void **planes, long frames);
// The driver wants to be reopened (its buffer size or rate changed).
typedef void (*asio_host_reset_fn)(void *ctx);

// Names of the installed drivers; returns how many (at most `max`).
int asio_host_list(char (*names)[64], int max);

// Loads and prepares `name` for `channels` outputs at `rate`, or the nearest
// rate the driver can run at (info->rate). 0 on success, else -1 with `error`.
int asio_host_open(const char *name, int channels, int rate, asio_host_fill_fn fill, asio_host_reset_fn reset,
                   void *ctx, struct asio_host_info *info, char *error, size_t error_size);

// These do nothing unless `ctx` still owns the driver.
void asio_host_start(void *ctx);
void asio_host_stop(void *ctx);
void asio_host_close(void *ctx);

#ifdef __cplusplus
}
#endif
