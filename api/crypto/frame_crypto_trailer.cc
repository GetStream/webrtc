/*
 * Copyright 2026 Stream
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "api/crypto/frame_crypto_trailer.h"

#include <algorithm>

#include "rtc_base/checks.h"

namespace webrtc {
namespace {

void WriteBe16(ArrayView<uint8_t> p, uint16_t v) {
  RTC_CHECK_GE(p.size(), 2u);
  p[0] = static_cast<uint8_t>(v >> 8);
  p[1] = static_cast<uint8_t>(v);
}

void WriteBe32(ArrayView<uint8_t> p, uint32_t v) {
  RTC_CHECK_GE(p.size(), 4u);
  p[0] = static_cast<uint8_t>(v >> 24);
  p[1] = static_cast<uint8_t>(v >> 16);
  p[2] = static_cast<uint8_t>(v >> 8);
  p[3] = static_cast<uint8_t>(v);
}

uint16_t ReadBe16(ArrayView<const uint8_t> p) {
  RTC_CHECK_GE(p.size(), 2u);
  return static_cast<uint16_t>((uint16_t{p[0]} << 8) | uint16_t{p[1]});
}

uint32_t ReadBe32(ArrayView<const uint8_t> p) {
  RTC_CHECK_GE(p.size(), 4u);
  return (uint32_t{p[0]} << 24) | (uint32_t{p[1]} << 16) |
         (uint32_t{p[2]} << 8) | uint32_t{p[3]};
}

}  // namespace

std::optional<uint8_t> ReadFramingVersion(ArrayView<const uint8_t> src) {
  // version (1) + magic (4) sit at the very end, so we can identify a frame
  // even when we do not yet know the full 20-byte trailer layout.
  constexpr size_t kIdent = 5;
  if (src.size() < kIdent) {
    return std::nullopt;
  }
  const size_t start = src.size() - kIdent;
  if (ReadBe32(src.subspan(start + 1, 4)) != kFrameTrailerMagic) {
    return std::nullopt;
  }
  return src[start];
}

std::optional<FrameTrailer> ReadFrameTrailer(ArrayView<const uint8_t> src) {
  if (src.size() < kFrameTrailerLen) {
    return std::nullopt;
  }
  const auto version = ReadFramingVersion(src);
  // Wrong version: still "framed", just not one we can decrypt. Callers
  // must not fall through to the plaintext path.
  if (!version || *version != kFrameTrailerVersion) {
    return std::nullopt;
  }
  const size_t start = src.size() - kFrameTrailerLen;
  // Byte 13-14: high bit means the ciphertext+trailer were RBSP-escaped.
  const uint16_t raw = ReadBe16(src.subspan(start + 13, 2));
  const uint16_t clear_bytes = raw & kFrameTrailerMaxClearBytes;
  // Overrun cannot be a valid trailer. Decrypt then re-checks version/magic
  // on the tail to decide unsupported-version vs plaintext.
  if (clear_bytes > src.size() - kFrameTrailerLen) {
    return std::nullopt;
  }
  FrameTrailer trailer;
  trailer.frame_counter = ReadBe32(src.subspan(start, 4));
  const ArrayView<const uint8_t> prefix = src.subspan(start + 4, 8);
  std::copy(prefix.begin(), prefix.end(), trailer.iv_prefix.begin());
  trailer.key_index = src[start + 12];
  trailer.clear_bytes = clear_bytes;
  trailer.is_rbsp = (raw & kFrameTrailerRbspFlag) != 0;
  return trailer;
}

std::optional<FrameTrailer> ReadUnescapedTrailerFields(
    ArrayView<const uint8_t> unit) {
  // After unescape, only counter / prefix / keyIndex need a second read:
  // those 13 bytes sit inside the escaped region. Magic and version were
  // already checked on the raw tail and never change in the unescape.
  if (unit.size() < kFrameTrailerLen) {
    return std::nullopt;
  }
  const size_t start = unit.size() - kFrameTrailerLen;
  FrameTrailer trailer;
  trailer.frame_counter = ReadBe32(unit.subspan(start, 4));
  const ArrayView<const uint8_t> prefix = unit.subspan(start + 4, 8);
  std::copy(prefix.begin(), prefix.end(), trailer.iv_prefix.begin());
  trailer.key_index = unit[start + 12];
  return trailer;
}

void WriteFrameTrailer(ArrayView<uint8_t> dst,
                       uint32_t counter,
                       ArrayView<const uint8_t> iv_prefix,
                       uint8_t key_index,
                       uint16_t clear_bytes,
                       bool is_rbsp) {
  RTC_CHECK_GE(dst.size(), kFrameTrailerLen);
  RTC_CHECK_EQ(iv_prefix.size(), 8u);
  WriteBe32(dst.subspan(0, 4), counter);
  std::copy(iv_prefix.begin(), iv_prefix.end(), dst.subspan(4, 8).begin());
  dst[12] = key_index;
  // OR the RBSP flag into the high bit of clearBytes. That forces the
  // high byte to >= 0x80, which breaks any 00 00 run before it can reach
  // version/magic, so a decoder can still read those last 7 bytes off
  // the raw (escaped) tail.
  WriteBe16(dst.subspan(13, 2),
            is_rbsp ? static_cast<uint16_t>(clear_bytes | kFrameTrailerRbspFlag)
                    : clear_bytes);
  dst[15] = kFrameTrailerVersion;
  WriteBe32(dst.subspan(16, 4), kFrameTrailerMagic);
}

void FillFrameIv(ArrayView<uint8_t> iv,
                 ArrayView<const uint8_t> prefix,
                 uint32_t counter) {
  // 12-byte GCM IV: 8-byte per-import prefix + 4-byte big-endian counter.
  // The prefix is what keeps two senders under a shared key from colliding.
  RTC_CHECK_GE(iv.size(), 12u);
  RTC_CHECK_EQ(prefix.size(), 8u);
  std::copy(prefix.begin(), prefix.end(), iv.begin());
  WriteBe32(iv.subspan(8, 4), counter);
}

}  // namespace webrtc
