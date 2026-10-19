/*
 * ASIO audio output for mpv, from OpenMusic.
 *
 * This file is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free
 * Software Foundation, either version 3 of the License, or (at your option)
 * any later version (it builds on Steinberg's ASIO SDK, which is GPLv3).
 *
 * A pull output, like ao_jack: the driver's buffer switch asks mpv for each
 * half of its double buffer. Where mpv has the driver's own sample format
 * (Int16, Int32, Float32, Float64) it writes straight into the driver's
 * buffers, so nothing is converted on the way. The device runs at the
 * stream's rate when it can, otherwise at the nearest rate it can and mpv
 * resamples.
 *
 * Devices are "asio/<driver name>"; with --audio-device=auto this output
 * never picks a driver by itself.
 */

#include <stdio.h>
#include <string.h>

#include "config.h"
#include "common/msg.h"

#include "ao.h"
#include "internal.h"
#include "audio/format.h"
#include "osdep/timer.h"

#include "asio/asio_host.h"

#if !HAVE_GPL
#error GPL only
#endif

struct priv {
    struct asio_host_info info;
};

static void fill(void *ctx, void **planes, long frames)
{
    struct ao *ao = ctx;
    struct priv *p = ao->priv;

    int64_t end_time = mp_time_us();
    end_time += (p->info.output_latency + frames) / (double)ao->samplerate * 1000000.0;

    ao_read_data(ao, planes, frames, end_time);
}

static void reset_request(void *ctx)
{
    ao_request_reload(ctx);
}

static int init(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!ao->device || !ao->device[0]) {
        MP_VERBOSE(ao, "no driver chosen (--audio-device=asio/<name>)\n");
        return -1;
    }

    struct mp_chmap_sel sel = {0};
    mp_chmap_sel_add_waveext(&sel);
    if (!ao_chmap_sel_adjust(ao, &sel, &ao->channels))
        return -1;

    char error[256] = {0};
    if (asio_host_open(ao->device, ao->channels.num, ao->samplerate, fill,
                       reset_request, ao, &p->info, error, sizeof(error)) < 0)
    {
        MP_ERR(ao, "%s\n", error);
        return -1;
    }

    if (!ao_chmap_sel_get_def(ao, &sel, &ao->channels, p->info.channels)) {
        asio_host_close(ao);
        return -1;
    }

    switch (p->info.layout) {
    case ASIO_HOST_S16P:    ao->format = AF_FORMAT_S16P;    break;
    case ASIO_HOST_FLOATP:  ao->format = AF_FORMAT_FLOATP;  break;
    case ASIO_HOST_DOUBLEP: ao->format = AF_FORMAT_DOUBLEP; break;
    default:                ao->format = AF_FORMAT_S32P;    break;
    }
    if (ao->samplerate != p->info.rate)
        MP_INFO(ao, "the driver can't run at %d Hz, converting to %d Hz\n",
                ao->samplerate, p->info.rate);
    ao->samplerate = p->info.rate;
    ao->device_buffer = p->info.buffer_frames;

    MP_VERBOSE(ao, "%s: %d Hz, %d channels, %s, %ld-frame buffers, %ld frames latency\n",
               ao->device, p->info.rate, p->info.channels, p->info.sample_type,
               p->info.buffer_frames, p->info.output_latency);
    return 0;
}

static void uninit(struct ao *ao)
{
    asio_host_close(ao);
}

static void start(struct ao *ao)
{
    asio_host_start(ao);
}

static void reset(struct ao *ao)
{
    asio_host_stop(ao);
}

static void list_devs(struct ao *ao, struct ao_device_list *list)
{
    char names[32][64];
    int n = asio_host_list(names, 32);
    for (int i = 0; i < n; i++) {
        char desc[80];
        snprintf(desc, sizeof(desc), "ASIO: %s", names[i]);
        ao_device_list_add(list, ao, &(struct ao_device_desc){names[i], desc});
    }
}

const struct ao_driver audio_out_asio = {
    .description = "ASIO audio output (OpenMusic)",
    .name        = "asio",
    .init        = init,
    .uninit      = uninit,
    .start       = start,
    .reset       = reset,
    .list_devs   = list_devs,
    .priv_size   = sizeof(struct priv),
};
