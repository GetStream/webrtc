/*
 *  Copyright 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef SDK_OBJC_NATIVE_SRC_STANDALONE_AUDIO_SEND_HELPER_H_
#define SDK_OBJC_NATIVE_SRC_STANDALONE_AUDIO_SEND_HELPER_H_

#include <memory>

#include "call/audio_send_stream.h"

namespace webrtc {

class Call;
class RtpRtcpInterface;

namespace voe {
class ChannelSendInterface;
}  // namespace voe

// RAII wrapper around a dedicated AudioSendStream created for standalone audio
// sources. Instances manage stream lifetime and provide access to the
// underlying ChannelSend and RtpRtcp interfaces for integration with higher
// layers.
class StandaloneAudioSendHelper {
 public:
  StandaloneAudioSendHelper(Call* call,
                            const AudioSendStream::Config& config);
  ~StandaloneAudioSendHelper();

  StandaloneAudioSendHelper(const StandaloneAudioSendHelper&) = delete;
  StandaloneAudioSendHelper& operator=(const StandaloneAudioSendHelper&) =
      delete;

  AudioSendStream* audio_send_stream() const { return audio_send_stream_; }
  const voe::ChannelSendInterface* channel_send() const { return channel_send_; }
  RtpRtcpInterface* rtp_rtcp() const { return rtp_rtcp_; }

 private:
  Call* call_ = nullptr;
  AudioSendStream* audio_send_stream_ = nullptr;
  const voe::ChannelSendInterface* channel_send_ = nullptr;
  RtpRtcpInterface* rtp_rtcp_ = nullptr;
};

}  // namespace webrtc

#endif  // SDK_OBJC_NATIVE_SRC_STANDALONE_AUDIO_SEND_HELPER_H_
