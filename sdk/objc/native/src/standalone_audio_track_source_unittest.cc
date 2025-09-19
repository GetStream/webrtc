/*
 *  Copyright 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "sdk/objc/native/src/standalone_audio_track_source.h"

#include <cstdint>
#include <optional>
#include <vector>

#include "api/audio/audio_frame.h"
#include "test/gtest.h"

namespace webrtc {
namespace {

constexpr int kSampleRateHz = 48000;
constexpr size_t kChannels = 1;
constexpr int64_t kCaptureTimestampMs = 1234;

class RecordingSink : public AudioTrackSinkInterface {
 public:
  void OnData(const void* audio_data,
              int bits_per_sample,
              int sample_rate,
              size_t number_of_channels,
              size_t number_of_frames,
              std::optional<int64_t> absolute_capture_timestamp_ms) override {
    ++callback_count_;
    bits_per_sample_ = bits_per_sample;
    sample_rate_ = sample_rate;
    channels_ = number_of_channels;
    frames_ = number_of_frames;
    capture_timestamp_ = absolute_capture_timestamp_ms;

    const int16_t* typed_data = static_cast<const int16_t*>(audio_data);
    size_t sample_count = number_of_channels * number_of_frames;
    last_data_.assign(typed_data, typed_data + sample_count);
  }

  void Reset() {
    callback_count_ = 0;
    bits_per_sample_ = 0;
    sample_rate_ = 0;
    channels_ = 0;
    frames_ = 0;
    capture_timestamp_.reset();
    last_data_.clear();
  }

  int callback_count() const { return callback_count_; }
  int bits_per_sample() const { return bits_per_sample_; }
  int sample_rate() const { return sample_rate_; }
  size_t channels() const { return channels_; }
  size_t frames() const { return frames_; }
  const std::vector<int16_t>& last_data() const { return last_data_; }
  const std::optional<int64_t>& capture_timestamp() const {
    return capture_timestamp_;
  }

 private:
  int callback_count_ = 0;
  int bits_per_sample_ = 0;
  int sample_rate_ = 0;
  size_t channels_ = 0;
  size_t frames_ = 0;
  std::optional<int64_t> capture_timestamp_;
  std::vector<int16_t> last_data_;
};

AudioFrame CreateTestFrame() {
  AudioFrame frame;
  frame.SetSampleRateAndChannelSize(kSampleRateHz);
  const size_t samples_per_channel = frame.samples_per_channel();

  std::vector<int16_t> payload(samples_per_channel * kChannels);
  for (size_t i = 0; i < payload.size(); ++i) {
    payload[i] = static_cast<int16_t>(i & 0xFF);
  }
  frame.UpdateFrame(/*timestamp=*/0, payload.data(), samples_per_channel,
                    kSampleRateHz, AudioFrame::kNormalSpeech,
                    AudioFrame::kVadActive, kChannels);
  frame.set_absolute_capture_timestamp_ms(kCaptureTimestampMs);
  return frame;
}

TEST(StandaloneAudioTrackSourceTest, DeliversFramesToRegisteredSink) {
  StandaloneAudioTrackSource source;
  RecordingSink sink;

  source.AddSink(&sink);
  source.Start();

  AudioFrame frame = CreateTestFrame();
  source.PushAudioFrame(frame);

  EXPECT_EQ(MediaSourceInterface::kLive, source.state());
  ASSERT_EQ(1, sink.callback_count());
  EXPECT_EQ(16, sink.bits_per_sample());
  EXPECT_EQ(kSampleRateHz, sink.sample_rate());
  EXPECT_EQ(kChannels, sink.channels());
  EXPECT_EQ(frame.samples_per_channel(), sink.frames());

  std::vector<int16_t> expected(frame.samples_per_channel() * kChannels);
  for (size_t i = 0; i < expected.size(); ++i) {
    expected[i] = static_cast<int16_t>(i & 0xFF);
  }
  EXPECT_EQ(expected, sink.last_data());
  ASSERT_TRUE(sink.capture_timestamp().has_value());
  EXPECT_EQ(kCaptureTimestampMs, sink.capture_timestamp().value());

  source.Stop();
  EXPECT_EQ(MediaSourceInterface::kEnded, source.state());
}

TEST(StandaloneAudioTrackSourceTest, IgnoresPushWhenNotStarted) {
  StandaloneAudioTrackSource source;
  RecordingSink sink;
  source.AddSink(&sink);

  AudioFrame frame = CreateTestFrame();
  source.PushAudioFrame(frame);
  EXPECT_EQ(0, sink.callback_count());
  EXPECT_EQ(MediaSourceInterface::kInitializing, source.state());
}

TEST(StandaloneAudioTrackSourceTest, RemoveSinkStopsDelivery) {
  StandaloneAudioTrackSource source;
  RecordingSink sink;
  source.AddSink(&sink);
  source.Start();

  AudioFrame frame = CreateTestFrame();
  source.PushAudioFrame(frame);
  ASSERT_EQ(1, sink.callback_count());

  source.RemoveSink(&sink);
  source.PushAudioFrame(frame);
  EXPECT_EQ(1, sink.callback_count());
}

}  // namespace
}  // namespace webrtc
