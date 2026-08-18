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

#ifndef API_CRYPTO_FRAME_CRYPTO_TRAILER_H_
#define API_CRYPTO_FRAME_CRYPTO_TRAILER_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

#include "api/array_view.h"

namespace webrtc {

// Wire layout of every encrypted frame, 20 bytes, big-endian, at the tail:
//   [0..3]   frame counter (uint32)
//   [4..11]  IV prefix (8 random bytes, fixed per key import)
//   [12]     key index (0–255)
//   [13..14] clear-byte count in the low 15 bits; high bit = RBSP escaped
//   [15]     framing version (currently 1)
//   [16..19] magic 0xe2eefeed so we can tell encrypted frames from plaintext
// AES-GCM IV is prefix || counter (12 bytes). Ciphertext+tag sits between
// the clear header and this trailer.
constexpr uint32_t kFrameTrailerMagic = 0xe2eefeed;
constexpr uint8_t kFrameTrailerVersion = 1;
constexpr size_t kFrameTrailerLen = 20;
constexpr uint16_t kFrameTrailerRbspFlag = 0x8000;
constexpr uint16_t kFrameTrailerMaxClearBytes = 0x7fff;

struct FrameTrailer {
  uint32_t frame_counter = 0;
  std::array<uint8_t, 8> iv_prefix{};
  uint8_t key_index = 0;
  uint16_t clear_bytes = 0;
  bool is_rbsp = false;
};

// Last 5 bytes are version + magic. Returns the version if magic matches,
// even when the version is not the one we implement (caller can emit
// "unsupported version" instead of treating the frame as plaintext).
std::optional<uint8_t> ReadFramingVersion(ArrayView<const uint8_t> src);

// Full 20-byte parse. nullopt = not a framed payload (too short, bad magic,
// wrong version, or clear_bytes larger than the buffer).
std::optional<FrameTrailer> ReadFrameTrailer(ArrayView<const uint8_t> src);

// After H.264 RBSP unescape, the last 20 bytes of the unit are the trailer
// again. Re-read counter / prefix / key index from that tail. Magic/version
// were already checked on the raw frame.
std::optional<FrameTrailer> ReadUnescapedTrailerFields(
    ArrayView<const uint8_t> unit);

void WriteFrameTrailer(uint8_t* dst,
                       uint32_t counter,
                       ArrayView<const uint8_t> iv_prefix,
                       uint8_t key_index,
                       uint16_t clear_bytes,
                       bool is_rbsp);

// IV = 8-byte per-import prefix || 4-byte big-endian counter. Prefix is what
// keeps two senders under a shared key from reusing the same GCM nonce.
void FillFrameIv(uint8_t iv[12],
                 ArrayView<const uint8_t> prefix,
                 uint32_t counter);

}  // namespace webrtc

#endif  // API_CRYPTO_FRAME_CRYPTO_TRAILER_H_
