/*
 * Copyright 2024 The WebRTC project authors. All Rights Reserved.
 *
 * Use of this source code is governed by a BSD-style license
 * that can be found in the LICENSE file in the root of the source
 * tree. An additional intellectual property rights grant can be found
 * in the file PATENTS.  All contributing project authors may
 * be found in the AUTHORS file in the root of the source tree.
 */

#include "sdk/objc/native/src/standalone_audio_send_helper.h"

#include <utility>

#include "audio/audio_send_stream.h"
#include "audio/channel_send.h"
#include "call/call.h"
#include "rtc_base/checks.h"

namespace webrtc {

StandaloneAudioSendHelper::StandaloneAudioSendHelper(
    Call* call,
    const AudioSendStream::Config& config)
    : call_(call) {
  RTC_DCHECK(call_);
  audio_send_stream_ = call_->CreateAudioSendStream(config);
  RTC_CHECK(audio_send_stream_);

  auto* internal_stream =
      static_cast<webrtc::internal::AudioSendStream*>(audio_send_stream_);
  channel_send_ = internal_stream->GetChannel();
  rtp_rtcp_ = channel_send_ ? channel_send_->GetRtpRtcp() : nullptr;
}

StandaloneAudioSendHelper::~StandaloneAudioSendHelper() {
  if (call_ && audio_send_stream_) {
    call_->DestroyAudioSendStream(audio_send_stream_);
  }
}

}  // namespace webrtc
