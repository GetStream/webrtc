/*
 * Copyright 2025 The WebRTC project authors. All Rights Reserved.
 *
 * Use of this source code is governed by a BSD-style license
 * that can be found in the LICENSE file in the root of the source
 * tree. An additional intellectual property rights grant can be found
 * in the file PATENTS. All contributing project authors may
 * be found in the AUTHORS file in the root of the source tree.
 */

#include "sdk/objc/native/src/objc_audio_track_source.h"

#include <algorithm>
#include <optional>

#import "sdk/objc/base/RTCAudioFrame+Private.h"

#include "absl/container/flat_hash_set.h"
#include "rtc_base/checks.h"
#include "rtc_base/logging.h"
#include "rtc_base/synchronization/mutex.h"
#include <pthread.h>

namespace webrtc {
namespace {
webrtc::Mutex& RegistryMutex() {
  static auto* mutex = new webrtc::Mutex();
  return *mutex;
}

absl::flat_hash_set<const AudioSourceInterface*>& Registry() {
  static auto* registry =
      new absl::flat_hash_set<const AudioSourceInterface*>();
  return *registry;
}
}  // namespace

ObjCAudioTrackSource::ObjCAudioTrackSource() {
  RegisterInstance(this);
}

ObjCAudioTrackSource::~ObjCAudioTrackSource() {
  UnregisterInstance(this);
}

MediaSourceInterface::SourceState ObjCAudioTrackSource::state() const {
  return MediaSourceInterface::kLive;
}

bool ObjCAudioTrackSource::remote() const {
  return false;
}

void ObjCAudioTrackSource::AddSink(AudioTrackSinkInterface* sink) {
  if (!sink) {
    return;
  }
  webrtc::MutexLock lock(&sink_lock_);
  if (std::find(sinks_.begin(), sinks_.end(), sink) == sinks_.end()) {
    sinks_.push_back(sink);
    RTC_LOG(LS_VERBOSE) << "ObjCAudioTrackSource added sink=" << sink
                        << " total_sinks=" << sinks_.size();
  }
}

void ObjCAudioTrackSource::RemoveSink(AudioTrackSinkInterface* sink) {
  webrtc::MutexLock lock(&sink_lock_);
  sinks_.erase(std::remove(sinks_.begin(), sinks_.end(), sink), sinks_.end());
  RTC_LOG(LS_VERBOSE) << "ObjCAudioTrackSource removed sink=" << sink
                      << " total_sinks=" << sinks_.size();
}

void ObjCAudioTrackSource::OnCapturedFrame(RTC_OBJC_TYPE(RTCAudioFrame) *frame) {
  if (!frame) {
    return;
  }

  const uintptr_t thread_id = reinterpret_cast<uintptr_t>(pthread_self());
  RTC_LOG(LS_ERROR) << "ObjCAudioTrackSource::OnCapturedFrame thread=" << thread_id;

  const int16_t* data = frame.int16Data;
  if (!data) {
    return;
  }

  const int sample_rate = frame.sampleRate;
  const size_t channels = frame.channels;
  const size_t frames = frame.frames;
  const std::optional<int64_t> capture_timestamp_ms =
      frame.timestampNs >= 0 ? std::optional<int64_t>(frame.timestampNs / 1000000)
                             : std::nullopt;

  RTC_LOG(LS_VERBOSE) << "ObjCAudioTrackSource received frame frames=" << frames
                      << " channels=" << channels
                      << " sample_rate=" << sample_rate
                      << " timestamp_ms="
                      << (capture_timestamp_ms ? *capture_timestamp_ms : -1);

  webrtc::MutexLock lock(&sink_lock_);
  for (auto* sink : sinks_) {
    if (!sink) {
      continue;
    }
    RTC_LOG(LS_VERBOSE) << "ObjCAudioTrackSource forwarding to sink=" << sink;
    sink->OnData(data, /*bits_per_sample=*/16, sample_rate, channels, frames,
                 capture_timestamp_ms);
  }
}

ObjCAudioTrackSource* ObjCAudioTrackSource::FromAudioSource(
    AudioSourceInterface* source) {
  if (!source) {
    return nullptr;
  }
  webrtc::MutexLock lock(&RegistryMutex());
  if (Registry().contains(source)) {
    return static_cast<ObjCAudioTrackSource*>(const_cast<AudioSourceInterface*>(source));
  }
  return nullptr;
}

void ObjCAudioTrackSource::RegisterInstance(ObjCAudioTrackSource* instance) {
  webrtc::MutexLock lock(&RegistryMutex());
  Registry().insert(instance);
}

void ObjCAudioTrackSource::UnregisterInstance(ObjCAudioTrackSource* instance) {
  webrtc::MutexLock lock(&RegistryMutex());
  Registry().erase(instance);
}

}  // namespace webrtc
