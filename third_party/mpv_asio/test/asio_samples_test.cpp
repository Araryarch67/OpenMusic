// Unit tests for asio_samples.cpp, the conversion ao_asio uses for driver
// formats mpv can't write itself (24-bit packed, right-justified 32-bit).
// Plain C++, run on Linux by tool/test_asio_core.sh.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "asio_samples.h"

using namespace openmusic_asio;

static int failures = 0;
#define CHECK(cond)                                       \
  do {                                                    \
    if (!(cond)) {                                        \
      std::printf("FAIL line %d: %s\n", __LINE__, #cond); \
      ++failures;                                         \
    }                                                     \
  } while (0)

int main() {
  // Left-justified 32-bit samples, as mpv's s32 hands them over: full scale,
  // a 24-bit value, a 16-bit value, silence and the most negative sample.
  const std::vector<int32_t> src = {INT32_MAX, 0x12345600, 0x7FFF0000, 0, INT32_MIN, -0x00000100};

  {  // Int24LSB: the top 24 bits, packed little-endian in 3 bytes.
    std::vector<uint8_t> out(src.size() * 3);
    Encode(AsioSampleType::kInt24LSB, src.data(), 1, src.size(), out.data());
    CHECK(out[3] == 0x56 && out[4] == 0x34 && out[5] == 0x12);  // 0x123456, every bit kept
    CHECK(out[0] == 0xFF && out[1] == 0xFF && out[2] == 0x7F);
    CHECK(out[12] == 0x00 && out[13] == 0x00 && out[14] == 0x80);
    CHECK(out[15] == 0xFF && out[16] == 0xFF && out[17] == 0xFF);  // -1 in 24 bits
  }
  {  // Right-justified: the same value, shifted down, sign kept.
    std::vector<int32_t> out(src.size());
    Encode(AsioSampleType::kInt32LSB24, src.data(), 1, src.size(), out.data());
    CHECK(out[1] == 0x123456 && out[4] == -0x800000 && out[5] == -1);
    Encode(AsioSampleType::kInt32LSB16, src.data(), 1, src.size(), out.data());
    CHECK(out[2] == 0x7FFF && out[4] == -0x8000);
    Encode(AsioSampleType::kInt32LSB20, src.data(), 1, src.size(), out.data());
    CHECK(out[1] == 0x12345 && out[4] == -0x80000);
    Encode(AsioSampleType::kInt32LSB18, src.data(), 1, src.size(), out.data());
    CHECK(out[1] == (0x12345600 >> 14));
  }
  {  // Int16LSB and Int32LSB, with a stride (one channel of interleaved stereo).
    const std::vector<int32_t> stereo = {0x7FFF0000, 1, -0x10000, 2};
    std::vector<int16_t> s16(2);
    Encode(AsioSampleType::kInt16LSB, stereo.data(), 2, 2, s16.data());
    CHECK(s16[0] == 0x7FFF && s16[1] == -1);
    std::vector<int32_t> s32(2);
    Encode(AsioSampleType::kInt32LSB, stereo.data() + 1, 2, 2, s32.data());
    CHECK(s32[0] == 1 && s32[1] == 2);
  }
  {  // Floats: ±1.0 scale.
    std::vector<float> f(src.size());
    Encode(AsioSampleType::kFloat32LSB, src.data(), 1, src.size(), f.data());
    CHECK(std::fabs(f[0] - 1.0f) < 1e-6f && f[3] == 0.0f && f[4] == -1.0f);
    std::vector<double> d(src.size());
    Encode(AsioSampleType::kFloat64LSB, src.data(), 1, src.size(), d.data());
    CHECK(d[4] == -1.0 && std::fabs(d[1] - 0x12345600 / 2147483648.0) < 1e-12);
  }
  CHECK(SampleBytes(AsioSampleType::kInt24LSB) == 3 && SampleBytes(AsioSampleType::kFloat64LSB) == 8);
  CHECK(IsSupported(17) && !IsSupported(0) && !IsSupported(32));  // 32: a DSD type

  std::printf(failures == 0 ? "all ASIO sample tests passed\n" : "%d ASIO sample test(s) failed\n", failures);
  return failures == 0 ? 0 : 1;
}
