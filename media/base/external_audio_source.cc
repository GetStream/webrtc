/*
 *  Copyright 2025 The WebRTC project authors.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "media/base/external_audio_source.h"

#include "rtc_base/checks.h"

namespace webrtc {

void ExternalAudioSource::SetSink(cricket::AudioSource::Sink* sink) {
  MutexLock lock(&lock_);
  if (!sink && sink_) {
    sink_->OnClose();
  }
  sink_ = sink;
}

void ExternalAudioSource::Push(const int16_t* samples,
                           size_t number_of_frames,
                           int sample_rate_hz,
                           size_t number_of_channels,
                           std::optional<int64_t> absolute_capture_timestamp_ms) {
  RTC_DCHECK(samples);
  RTC_DCHECK_GE(number_of_channels, 1u);
  RTC_DCHECK_GE(sample_rate_hz, 8000);
  MutexLock lock(&lock_);
  if (!sink_) {
    return;
  }
  sink_->OnData(static_cast<const void*>(samples), /*bits_per_sample=*/16,
                sample_rate_hz, number_of_channels, number_of_frames,
                absolute_capture_timestamp_ms);
}

}  // namespace webrtc
