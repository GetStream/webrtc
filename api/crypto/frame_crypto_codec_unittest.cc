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

#include <cstdint>
#include <string>
#include <vector>

#include "api/video/video_codec_type.h"
#include "test/gtest.h"

namespace webrtc {
namespace {

FrameCryptoInput Audio(ArrayView<const uint8_t> data) {
  FrameCryptoInput in;
  in.data = data;
  in.media_type = FrameCryptorTransformer::MediaType::kAudioFrame;
  in.track_type = FrameCryptorTransformer::TrackType::kAudio;
  return in;
}

FrameCryptoInput Video(ArrayView<const uint8_t> data,
                       VideoCodecType codec,
                       bool keyframe) {
  FrameCryptoInput in;
  in.data = data;
  in.media_type = FrameCryptorTransformer::MediaType::kVideoFrame;
  in.track_type = FrameCryptorTransformer::TrackType::kVideo;
  in.video_codec = codec;
  in.is_keyframe = keyframe;
  return in;
}

TEST(FrameCryptoCodec, OpusLeavesOneByteClear) {
  const uint8_t opus[] = {0x78, 0xaa, 0xbb};
  size_t clear = 99;
  EXPECT_EQ(GetClearBytes(Audio(opus), &clear), FrameCodecSupport::kOk);
  EXPECT_EQ(clear, 1u);
}

TEST(FrameCryptoCodec, EmptyAudioLeavesNothingClear) {
  size_t clear = 99;
  EXPECT_EQ(GetClearBytes(Audio({}), &clear), FrameCodecSupport::kOk);
  EXPECT_EQ(clear, 0u);
}

TEST(FrameCryptoCodec, AudioWithKeyframeOrCodecIsUnsupported) {
  const uint8_t opus[] = {0x78};
  auto keyed = Audio(opus);
  keyed.is_keyframe = true;
  size_t clear = 0;
  EXPECT_EQ(GetClearBytes(keyed, &clear), FrameCodecSupport::kUnsupported);

  auto as_video = Audio(opus);
  as_video.video_codec = kVideoCodecVP8;
  EXPECT_EQ(GetClearBytes(as_video, &clear), FrameCodecSupport::kUnsupported);
}

TEST(FrameCryptoCodec, Vp8Vp9ClearBytesAndClamp) {
  const uint8_t long_frame[12] = {};
  const uint8_t short_key[5] = {};
  size_t clear = 0;
  EXPECT_EQ(GetClearBytes(Video(long_frame, kVideoCodecVP8, false), &clear),
            FrameCodecSupport::kOk);
  EXPECT_EQ(clear, 3u);
  EXPECT_EQ(GetClearBytes(Video(long_frame, kVideoCodecVP8, true), &clear),
            FrameCodecSupport::kOk);
  EXPECT_EQ(clear, 10u);
  EXPECT_EQ(GetClearBytes(Video(short_key, kVideoCodecVP8, true), &clear),
            FrameCodecSupport::kOk);
  EXPECT_EQ(clear, 5u);
  EXPECT_EQ(GetClearBytes(Video(long_frame, kVideoCodecVP9, true), &clear),
            FrameCodecSupport::kOk);
  EXPECT_EQ(clear, 10u);
}

TEST(FrameCryptoCodec, H264FindsFirstCodedSlice) {
  // 4-byte start + IDR (type 5) + one extra slice-header byte → 6 clear.
  const uint8_t idr[] = {0, 0, 0, 1, 0x65, 0x88, 0xaa};
  size_t clear = 0;
  EXPECT_EQ(GetClearBytes(Video(idr, kVideoCodecH264, true), &clear),
            FrameCodecSupport::kOk);
  EXPECT_EQ(clear, 6u);

  // 3-byte start + IDR.
  const uint8_t idr3[] = {0, 0, 1, 0x65, 0x88, 0xaa};
  EXPECT_EQ(GetClearBytes(Video(idr3, kVideoCodecH264, true), &clear),
            FrameCodecSupport::kOk);
  EXPECT_EQ(clear, 5u);

  // SPS (type 7) then a type-1 slice. Clear starts at the slice, not SPS.
  const uint8_t sps_then_slice[] = {0, 0, 0, 1, 0x67, 0xaa,
                                    0, 0, 0, 1, 0x41, 0x88, 0xbb};
  EXPECT_EQ(GetClearBytes(Video(sps_then_slice, kVideoCodecH264, false),
                          &clear),
            FrameCodecSupport::kOk);
  EXPECT_EQ(clear, 12u);

  // SPS only: no coded slice, encrypt the whole frame.
  const uint8_t sps[] = {0, 0, 0, 1, 0x67, 0xaa};
  EXPECT_EQ(GetClearBytes(Video(sps, kVideoCodecH264, true), &clear),
            FrameCodecSupport::kOk);
  EXPECT_EQ(clear, 0u);
}

TEST(FrameCryptoCodec, Av1H265AndUnknownVideoFailClosed) {
  const uint8_t payload[] = {1, 2, 3, 4};
  size_t clear = 0;
  EXPECT_EQ(GetClearBytes(Video(payload, kVideoCodecAV1, true), &clear),
            FrameCodecSupport::kUnsupported);
  EXPECT_EQ(GetClearBytes(Video(payload, kVideoCodecH265, true), &clear),
            FrameCodecSupport::kUnsupported);
  FrameCryptoInput no_codec;
  no_codec.data = payload;
  no_codec.media_type = FrameCryptorTransformer::MediaType::kVideoFrame;
  EXPECT_EQ(GetClearBytes(no_codec, &clear), FrameCodecSupport::kUnsupported);
}

TEST(FrameCryptoCodec, RbspEscapeRoundTripAndSeed) {
  const uint8_t raw[] = {0, 0, 1, 2};
  ArrayView<const uint8_t> data(raw);
  EXPECT_EQ(RbspEscapedLength(data, 0), 5u);
  std::vector<uint8_t> escaped(5);
  RbspEscapeInto(escaped.data(), data, 0);
  const uint8_t want[] = {0, 0, 3, 1, 2};
  EXPECT_EQ(escaped, std::vector<uint8_t>(want, want + 5));
  EXPECT_EQ(RbspUnescape(escaped, 0), std::vector<uint8_t>(raw, raw + 4));

  // Two trailing zeros on the clear header count toward the next pattern.
  const uint8_t header[] = {0xaa, 0, 0};
  EXPECT_EQ(BoundarySeedZeros(header), 2);
  const uint8_t next[] = {1};
  EXPECT_EQ(RbspEscapedLength(next, 2), 2u);
  std::vector<uint8_t> seeded(2);
  RbspEscapeInto(seeded.data(), next, 2);
  EXPECT_EQ(seeded, (std::vector<uint8_t>{3, 1}));
  EXPECT_EQ(RbspUnescape(seeded, 2), std::vector<uint8_t>(next, next + 1));
}

TEST(FrameCryptoCodec, ApplyEncodeCodecPin) {
  std::vector<uint8_t> payload(16, 1);
  auto vp8 = Video(payload, kVideoCodecVP8, true);
  vp8.codec_name = "h264";
  EXPECT_TRUE(ApplyEncodeCodecPin(&vp8));
  EXPECT_EQ(*vp8.video_codec, kVideoCodecH264);

  auto av1 = Video(payload, kVideoCodecVP8, true);
  av1.codec_name = "av1";
  EXPECT_FALSE(ApplyEncodeCodecPin(&av1));

  auto upper = Video(payload, kVideoCodecVP8, true);
  upper.codec_name = "H264";
  EXPECT_FALSE(ApplyEncodeCodecPin(&upper));

  auto opus_video = Video(payload, kVideoCodecVP8, true);
  opus_video.codec_name = "opus";
  EXPECT_FALSE(ApplyEncodeCodecPin(&opus_video));

  auto opus_audio = Audio(payload);
  opus_audio.codec_name = "opus";
  EXPECT_TRUE(ApplyEncodeCodecPin(&opus_audio));
  EXPECT_FALSE(opus_audio.video_codec.has_value());

  auto from_frame = Video(payload, kVideoCodecVP8, true);
  EXPECT_TRUE(ApplyEncodeCodecPin(&from_frame));
  EXPECT_EQ(*from_frame.video_codec, kVideoCodecVP8);

  EXPECT_EQ(FrameCodecLabel(Audio(payload)), "opus");
  auto labeled = Video(payload, kVideoCodecVP9, false);
  EXPECT_EQ(FrameCodecLabel(labeled), "vp9");
  labeled.codec_name = "h264";
  EXPECT_EQ(FrameCodecLabel(labeled), "h264");
}

}  // namespace
}  // namespace webrtc
