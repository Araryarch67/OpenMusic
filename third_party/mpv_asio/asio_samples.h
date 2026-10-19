// Writing samples in the formats ASIO drivers take (values from asio.h).
// Kept free of Windows and SDK headers so it is unit-tested on any OS
// (tool/test_asio_core.sh).
#pragma once

#include <cstddef>
#include <cstdint>

namespace openmusic_asio {

// The ASIO sample types a host has to write (values from asio.h).
enum class AsioSampleType : int {
  kInt16LSB = 16,
  kInt24LSB = 17,
  kInt32LSB = 18,
  kFloat32LSB = 19,
  kFloat64LSB = 20,
  kInt32LSB16 = 24,
  kInt32LSB18 = 25,
  kInt32LSB20 = 26,
  kInt32LSB24 = 27,
};

bool IsSupported(int asio_sample_type);

// Size in bytes of one sample of `type` in an ASIO buffer.
int SampleBytes(AsioSampleType type);

// Writes `frames` samples of one channel, read from `src` every `stride`
// values, into an ASIO buffer of `type`. Only drops bits the device can't
// take (e.g. the low 8 bits for a 24-bit device).
void Encode(AsioSampleType type, const int32_t* src, size_t stride, size_t frames, void* dst);

}  // namespace openmusic_asio
