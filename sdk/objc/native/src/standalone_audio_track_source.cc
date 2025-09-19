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

#include "sdk/objc/native/src/standalone_audio_send_helper.h"

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
    SetState(MediaSourceInterface::kLive);
  }
}

void StandaloneAudioTrackSource::Stop() {
  bool expected = true;
  if (started_.compare_exchange_strong(expected, false)) {
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
}

void StandaloneAudioTrackSource::RemoveSink(AudioTrackSinkInterface* sink) {
  RTC_DCHECK(sink);
  MutexLock lock(&sink_lock_);
  auto it = std::find(sinks_.begin(), sinks_.end(), sink);
  if (it != sinks_.end()) {
    sinks_.erase(it);
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
