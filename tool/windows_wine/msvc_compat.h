// Force-included into every file of the Wine test build (tool/build_windows_wine.sh):
// what MSVC lets Flutter's C++ wrapper and the plugins get away with.
#pragma once

#include <cmath>
#include <codecvt>
#include <locale>
#include <memory>
#include <ostream>

// event_channel.h prints a unique_ptr, which only C++20 (and MSVC's C++17) allows.
namespace std {
template <class C, class Tr, class T, class D>
basic_ostream<C, Tr>& operator<<(basic_ostream<C, Tr>& out, const unique_ptr<T, D>& p) {
  return out << static_cast<const void*>(p.get());
}
}  // namespace std
