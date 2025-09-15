/*
 *  Copyright 2025 The WebRTC project authors.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MEDIA_BASE_EXTERNAL_AUDIO_SOURCE_H_
#define MEDIA_BASE_EXTERNAL_AUDIO_SOURCE_H_

#include <cstddef>
#include <cstdint>
#include <optional>

#include "api/call/audio_sink.h"
#include "media/base/audio_source.h"
#include "rtc_base/synchronization/mutex.h"

namespace webrtc {

// Simple external push-only AudioSource. Call Push(...) with 10 ms (or any
// size) PCM frames and they will be forwarded to the attached sink (a single
// sender).
class ExternalAudioSource : public cricket::AudioSource {
 public:
  ExternalAudioSource() = default;
  ~ExternalAudioSource() override = default;

  // Pushes interleaved 16-bit PCM audio to the attached sink.
  void Push(const int16_t* samples,
            size_t number_of_frames,
            int sample_rate_hz,
            size_t number_of_channels,
            std::optional<int64_t> absolute_capture_timestamp_ms);

  // cricket::AudioSource implementation.
  void SetSink(cricket::AudioSource::Sink* sink) override;

 private:
  Mutex lock_;
  cricket::AudioSource::Sink* sink_ RTC_GUARDED_BY(lock_) = nullptr;
};

}  // namespace webrtc

#endif  // MEDIA_BASE_EXTERNAL_AUDIO_SOURCE_H_
