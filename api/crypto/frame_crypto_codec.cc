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

#include "api/crypto/frame_crypto_codec.h"

#include "api/video/video_codec_type.h"

#include <optional>
#include <string>

namespace webrtc {
namespace {

// Annex-B start codes mark NAL units: 00 00 01 (3 bytes) or 00 00 00 01 (4).
// `offset` is where to resume after the previous NAL. On success, `pos` is
// the start-code index and `len` is 3 or 4.
bool FindAnnexBStartCode(ArrayView<const uint8_t> data,
                         size_t offset,
                         size_t* pos,
                         size_t* len) {
  for (size_t i = offset; i + 2 < data.size(); ++i) {
    if (data[i] == 0 && data[i + 1] == 0) {
      if (data[i + 2] == 1) {
        *pos = i;
        *len = 3;
        return true;
      }
      if (data[i + 2] == 0 && i + 3 < data.size() && data[i + 3] == 1) {
        *pos = i;
        *len = 4;
        return true;
      }
    }
  }
  return false;
}

// Leave the start code plus the first two bytes of the first coded slice
// (NAL type 1 = non-IDR, 5 = IDR) in the clear. SPS/PPS stay fully encrypted
// if they appear first; we skip them until we find a slice. If there is no
// slice, encrypt the whole frame (clear_bytes = 0).
size_t H264ClearBytes(ArrayView<const uint8_t> data) {
  size_t pos = 0;
  size_t len = 0;
  size_t offset = 0;
  while (FindAnnexBStartCode(data, offset, &pos, &len)) {
    const size_t header_pos = pos + len;
    if (header_pos >= data.size()) {
      break;
    }
    // Lower 5 bits are the NAL unit type.
    const uint8_t nalu_type = data[header_pos] & 0x1f;
    if (nalu_type == 1 || nalu_type == 5) {
      const size_t clear = pos + len + 2;
      return clear > data.size() ? data.size() : clear;
    }
    offset = header_pos;
  }
  return 0;
}

}  // namespace

// Count trailing 0x00 bytes in the clear header, capped at 2. Those zeros
// count toward the "two zeros then 00..03" start-code pattern when we start
// escaping the ciphertext that follows.
int BoundarySeedZeros(ArrayView<const uint8_t> clear_header) {
  int zeros = 0;
  const size_t n = clear_header.size();
  while (zeros < 2 && static_cast<size_t>(zeros) < n &&
         clear_header[n - 1 - zeros] == 0) {
    zeros++;
  }
  return zeros;
}

// How many bytes RbspEscapeInto will write. Same walk as escape, but only
// counts the extra 0x03 insertions.
size_t RbspEscapedLength(ArrayView<const uint8_t> data, int seed_zeros) {
  size_t total = data.size();
  int zeros = seed_zeros;
  for (size_t i = 0; i < data.size(); ++i) {
    const uint8_t byte = data[i];
    // After two zeros, 0, 1, 2, or 3 would look like a start code / emulation.
    // Insert 0x03 and reset the zero run.
    if (zeros >= 2 && byte <= 3) {
      total++;
      zeros = 0;
    }
    zeros = byte == 0 ? zeros + 1 : 0;
  }
  return total;
}

void RbspEscapeInto(uint8_t* dst,
                    ArrayView<const uint8_t> data,
                    int seed_zeros) {
  size_t j = 0;
  int zeros = seed_zeros;
  for (size_t i = 0; i < data.size(); ++i) {
    const uint8_t byte = data[i];
    if (zeros >= 2 && byte <= 3) {
      dst[j++] = 3;
      // The 0x03 is not a payload zero, so the run resets before we copy
      // `byte` (which may itself be 0 and start a new run).
      zeros = 0;
    }
    dst[j++] = byte;
    zeros = byte == 0 ? zeros + 1 : 0;
  }
}

// Drop 0x03 bytes that were inserted as emulation prevention. A real 0x03
// after two zeros is an escape only when the next byte is also <= 3.
std::vector<uint8_t> RbspUnescape(ArrayView<const uint8_t> data,
                                  int seed_zeros) {
  auto is_escape = [&](size_t i, int zeros) {
    return zeros >= 2 && data[i] == 3 && i + 1 < data.size() &&
           data[i + 1] <= 3;
  };
  size_t remove = 0;
  int zeros = seed_zeros;
  for (size_t i = 0; i < data.size(); ++i) {
    if (is_escape(i, zeros)) {
      remove++;
      zeros = 0;
      continue;
    }
    zeros = data[i] == 0 ? zeros + 1 : 0;
  }
  if (remove == 0) {
    return std::vector<uint8_t>(data.begin(), data.end());
  }
  std::vector<uint8_t> out(data.size() - remove);
  size_t j = 0;
  zeros = seed_zeros;
  for (size_t i = 0; i < data.size(); ++i) {
    if (is_escape(i, zeros)) {
      zeros = 0;
      continue;
    }
    out[j++] = data[i];
    zeros = data[i] == 0 ? zeros + 1 : 0;
  }
  return out;
}

FrameCodecSupport GetClearBytes(const FrameCryptoInput& in,
                                size_t* clear_bytes) {
  const size_t n = in.data.size();
  if (in.media_type == FrameCryptorTransformer::MediaType::kAudioFrame) {
    // Audio path is Opus-style: one TOC byte in the clear. A video codec or
    // keyframe flag on an audio frame is a programming error — refuse it.
    if (in.is_keyframe || in.video_codec.has_value()) {
      return FrameCodecSupport::kUnsupported;
    }
    *clear_bytes = n < 1 ? n : 1;
    return FrameCodecSupport::kOk;
  }
  if (!in.video_codec) {
    return FrameCodecSupport::kUnsupported;
  }
  if (*in.video_codec == kVideoCodecVP8 || *in.video_codec == kVideoCodecVP9) {
    // VP8/VP9 payload descriptor: 10 bytes on keyframes (includes start code
    // / frame tag), 3 on delta frames. Clamp if the frame is shorter.
    const size_t want = in.is_keyframe ? 10u : 3u;
    *clear_bytes = want > n ? n : want;
    return FrameCodecSupport::kOk;
  }
  if (*in.video_codec == kVideoCodecH264) {
    *clear_bytes = H264ClearBytes(in.data);
    return FrameCodecSupport::kOk;
  }
  // AV1, H.265, and anything else: do not guess a header size.
  return FrameCodecSupport::kUnsupported;
}

bool ApplyEncodeCodecPin(FrameCryptoInput* in) {
  // No pin: keep whatever codec the RTP frame already carried. Native
  // encoded frames usually have this; JS does not, so JS pins at attach.
  if (!in->codec_name.has_value()) {
    return true;
  }
  const std::string& name = *in->codec_name;
  // Names are exact lowercase, matching JS Object.hasOwn on the profile
  // map. "H264" / "video/vp8" are not profiles and fail closed.
  if (name == "opus") {
    // Audio-only profile: a video frame has no clear-byte rule, so the
    // JS worker drops it rather than encrypting the whole payload.
    if (in->media_type == FrameCryptorTransformer::MediaType::kVideoFrame) {
      return false;
    }
    in->video_codec.reset();
    in->is_keyframe = false;
    return true;
  }
  std::optional<VideoCodecType> codec;
  if (name == "vp8") {
    codec = kVideoCodecVP8;
  } else if (name == "vp9") {
    codec = kVideoCodecVP9;
  } else if (name == "h264") {
    codec = kVideoCodecH264;
  } else {
    // av1, h265, and anything else: JS installs a drop-all transform.
    return false;
  }
  // Pin wins over frame metadata so both sides use the same clear-byte
  // rule even if the encoder tagged the frame differently.
  in->video_codec = codec;
  return true;
}

std::string FrameCodecLabel(const FrameCryptoInput& in) {
  // Perf reports use the name the publisher passed, when they passed one.
  if (in.codec_name && !in.codec_name->empty()) {
    return *in.codec_name;
  }
  // Unlabeled audio is framed as Opus (one TOC byte). Decode never has a
  // pin, so remote audio shows up as "opus" here too.
  if (in.media_type == FrameCryptorTransformer::MediaType::kAudioFrame) {
    return "opus";
  }
  if (!in.video_codec) {
    return "unknown";
  }
  switch (*in.video_codec) {
    case kVideoCodecVP8:
      return "vp8";
    case kVideoCodecVP9:
      return "vp9";
    case kVideoCodecH264:
      return "h264";
    case kVideoCodecAV1:
      return "av1";
    case kVideoCodecH265:
      return "h265";
    default:
      return "unknown";
  }
}

}  // namespace webrtc
