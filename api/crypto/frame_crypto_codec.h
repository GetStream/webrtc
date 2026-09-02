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

#ifndef API_CRYPTO_FRAME_CRYPTO_CODEC_H_
#define API_CRYPTO_FRAME_CRYPTO_CODEC_H_

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "api/array_view.h"
#include "api/crypto/frame_encryption_manager.h"

namespace webrtc {

// How much of a media frame we leave in the clear so RTP/SFU/decoders can
// still see codec headers. The rest is AES-GCM ciphertext.
// kUnsupported means this codec must not be encrypted (fail closed).
enum class FrameCodecSupport { kOk, kUnsupported };

// Fills `clear_bytes` with how many leading bytes stay unencrypted.
// Audio (Opus): 1 byte. VP8/VP9: 10 on keyframes, 3 on delta. H.264: up to
// and including the first two bytes of the first coded slice (type 1 or 5).
// AV1 and H.265 return kUnsupported.
FrameCodecSupport GetClearBytes(const FrameCryptoInput& in,
                                size_t* clear_bytes);

// JS `getCodecProfile` / `isSupportedCodec`: exact lowercase names only.
// No pin → leave the frame's codec alone. `opus` on video, or any name
// without a clear-byte rule (av1, h265, "H264"), is unsupported.
bool ApplyEncodeCodecPin(FrameCryptoInput* in);

// Perf / logs: the pin if present, else opus / vp8 / vp9 / h264 / unknown.
std::string FrameCodecLabel(const FrameCryptoInput& in);

// H.264 forbids 00 00 00 / 00 00 01 / 00 00 02 / 00 00 03 in the RBSP.
// When we encrypt after a clear header, the ciphertext can create those
// patterns, so we insert 0x03 after two zeros. Unescape reverses that.
// `seed_zeros` is how many trailing zeros the clear header already has,
// because the pattern can straddle the clear/cipher boundary.
int BoundarySeedZeros(ArrayView<const uint8_t> clear_header);
size_t RbspEscapedLength(ArrayView<const uint8_t> data, int seed_zeros);
void RbspEscapeInto(uint8_t* dst,
                    ArrayView<const uint8_t> data,
                    int seed_zeros);
std::vector<uint8_t> RbspUnescape(ArrayView<const uint8_t> data,
                                  int seed_zeros);

}  // namespace webrtc

#endif  // API_CRYPTO_FRAME_CRYPTO_CODEC_H_
