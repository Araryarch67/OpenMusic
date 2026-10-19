#include "asio_samples.h"

#include <cstring>

namespace openmusic_asio {

bool IsSupported(int asio_sample_type) {
  switch (static_cast<AsioSampleType>(asio_sample_type)) {
    case AsioSampleType::kInt16LSB:
    case AsioSampleType::kInt24LSB:
    case AsioSampleType::kInt32LSB:
    case AsioSampleType::kFloat32LSB:
    case AsioSampleType::kFloat64LSB:
    case AsioSampleType::kInt32LSB16:
    case AsioSampleType::kInt32LSB18:
    case AsioSampleType::kInt32LSB20:
    case AsioSampleType::kInt32LSB24:
      return true;
  }
  return false;
}

int SampleBytes(AsioSampleType type) {
  switch (type) {
    case AsioSampleType::kInt16LSB:
      return 2;
    case AsioSampleType::kInt24LSB:
      return 3;
    case AsioSampleType::kFloat64LSB:
      return 8;
    default:
      return 4;
  }
}

void Encode(AsioSampleType type, const int32_t* src, size_t stride, size_t frames, void* dst) {
  auto* out = static_cast<uint8_t*>(dst);
  for (size_t i = 0; i < frames; ++i, src += stride) {
    const int32_t s = *src;
    switch (type) {
      case AsioSampleType::kInt16LSB: {
        const auto v = static_cast<int16_t>(s >> 16);
        std::memcpy(out + i * 2, &v, 2);
        break;
      }
      case AsioSampleType::kInt24LSB: {
        const auto v = static_cast<uint32_t>(s) >> 8;
        out[i * 3] = static_cast<uint8_t>(v);
        out[i * 3 + 1] = static_cast<uint8_t>(v >> 8);
        out[i * 3 + 2] = static_cast<uint8_t>(v >> 16);
        break;
      }
      case AsioSampleType::kInt32LSB:
        std::memcpy(out + i * 4, &s, 4);
        break;
      case AsioSampleType::kFloat32LSB: {
        const auto v = static_cast<float>(s / 2147483648.0);
        std::memcpy(out + i * 4, &v, 4);
        break;
      }
      case AsioSampleType::kFloat64LSB: {
        const double v = s / 2147483648.0;
        std::memcpy(out + i * 8, &v, 8);
        break;
      }
      // Right-justified in 32 bits: 16, 18, 20 or 24 significant bits.
      case AsioSampleType::kInt32LSB16: {
        const int32_t v = s >> 16;
        std::memcpy(out + i * 4, &v, 4);
        break;
      }
      case AsioSampleType::kInt32LSB18: {
        const int32_t v = s >> 14;
        std::memcpy(out + i * 4, &v, 4);
        break;
      }
      case AsioSampleType::kInt32LSB20: {
        const int32_t v = s >> 12;
        std::memcpy(out + i * 4, &v, 4);
        break;
      }
      case AsioSampleType::kInt32LSB24: {
        const int32_t v = s >> 8;
        std::memcpy(out + i * 4, &v, 4);
        break;
      }
    }
  }
}

}  // namespace openmusic_asio
