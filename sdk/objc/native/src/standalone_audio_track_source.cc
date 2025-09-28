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

#include <algorithm>
#include <atomic>
#include <cstdlib>

#include "sdk/objc/native/src/standalone_audio_send_helper.h"
#include "rtc_base/logging.h"

namespace webrtc {

namespace {

constexpr int kBitsPerSample = 16;

}  // namespace

StandaloneAudioTrackSource::StandaloneAudioTrackSource()
    : state_(MediaSourceInterface::kInitializing), started_(false) {}

StandaloneAudioTrackSource::~StandaloneAudioTrackSource() = default;

void StandaloneAudioTrackSource::Start() {
  bool expected = false;
  if (started_.compare_exchange_strong(expected, true)) {
    RTC_LOG(LS_INFO) << "StandaloneAudioTrackSource::Start";
    SetState(MediaSourceInterface::kLive);
  }
}

void StandaloneAudioTrackSource::Stop() {
  bool expected = true;
  if (started_.compare_exchange_strong(expected, false)) {
    RTC_LOG(LS_INFO) << "StandaloneAudioTrackSource::Stop";
    SetState(MediaSourceInterface::kEnded);
  }
}

MediaSourceInterface::SourceState StandaloneAudioTrackSource::state() const {
  return state_.load();
}

void StandaloneAudioTrackSource::AddSink(AudioTrackSinkInterface* sink) {
  RTC_DCHECK(sink);
  MutexLock lock(&sink_lock_);
  RTC_DCHECK(std::find(sinks_.begin(), sinks_.end(), sink) == sinks_.end());
  sinks_.push_back(sink);
  RTC_LOG(LS_INFO) << "StandaloneAudioTrackSource::AddSink count="
                   << sinks_.size();
}

void StandaloneAudioTrackSource::RemoveSink(AudioTrackSinkInterface* sink) {
  RTC_DCHECK(sink);
  MutexLock lock(&sink_lock_);
  auto it = std::find(sinks_.begin(), sinks_.end(), sink);
  if (it != sinks_.end()) {
    sinks_.erase(it);
    RTC_LOG(LS_INFO) << "StandaloneAudioTrackSource::RemoveSink count="
                     << sinks_.size();
  }
}

void StandaloneAudioTrackSource::PushAudioFrame(const AudioFrame& frame) {
  if (!started_.load()) {
    return;
  }

  MutexLock lock(&sink_lock_);
  if (sinks_.empty()) {
    return;
  }

  const int16_t* audio_data = frame.data();
  const size_t samples_per_channel = frame.samples_per_channel();
  const size_t num_channels = frame.num_channels();
  const int sample_rate = frame.sample_rate_hz();
  RTC_DCHECK(audio_data);

  static std::atomic<uint32_t> frame_counter{0};
  const uint32_t current = ++frame_counter;
  if (current % 100 == 0) {
    const size_t total_samples = samples_per_channel * num_channels;
    int32_t max_abs = 0;
    int64_t accum_abs = 0;
    for (size_t i = 0; i < total_samples; ++i) {
      const int32_t value = audio_data[i];
      const int32_t abs_value = std::abs(value);
      max_abs = std::max(max_abs, abs_value);
      accum_abs += abs_value;
    }
    const float mean_abs = total_samples > 0
                               ? static_cast<float>(accum_abs) /
                                     static_cast<float>(total_samples)
                               : 0.0f;
    RTC_LOG(LS_INFO) << "StandaloneAudioTrackSource push: rate=" << sample_rate
                     << "Hz channels=" << num_channels
                     << " samples/ch=" << samples_per_channel
                     << " avg_abs=" << mean_abs
                     << " max_abs=" << max_abs
                     << " muted=" << (frame.muted() ? "true" : "false");
  }

  for (auto* sink : sinks_) {
    sink->OnData(audio_data, kBitsPerSample, sample_rate, num_channels,
                 samples_per_channel, frame.absolute_capture_timestamp_ms());
  }
}

StandaloneAudioTrackSource::AudioSendStreamPtr
StandaloneAudioTrackSource::CreateSendStream(
    Call* call,
    const AudioSendStream::Config& config) {
  RTC_DCHECK(call);
  auto helper = std::make_unique<StandaloneAudioSendHelper>(call, config);
  RTC_CHECK(helper->audio_send_stream());
  return helper;
}

void StandaloneAudioTrackSource::SetState(SourceState new_state) {
  SourceState old_state = state_.exchange(new_state);
  if (old_state != new_state) {
    FireOnChanged();
  }
}

}  // namespace webrtc
