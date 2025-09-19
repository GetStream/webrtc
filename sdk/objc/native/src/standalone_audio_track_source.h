/*
 *  Copyright 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef SDK_OBJC_NATIVE_SRC_STANDALONE_AUDIO_TRACK_SOURCE_H_
#define SDK_OBJC_NATIVE_SRC_STANDALONE_AUDIO_TRACK_SOURCE_H_

#include <atomic>
#include <functional>
#include <memory>
#include <vector>

#include "api/audio/audio_frame.h"
#include "api/media_stream_interface.h"
#include "api/notifier.h"
#include "call/audio_send_stream.h"
#include "call/call.h"
#include "rtc_base/checks.h"
#include "rtc_base/synchronization/mutex.h"
#include "rtc_base/thread_annotations.h"

namespace webrtc {

// StandaloneAudioTrackSource provides a manual audio pipeline surface that can
// be fed with 10 ms PCM frames without relying on AudioTransportImpl.
class StandaloneAudioTrackSource : public Notifier<AudioSourceInterface> {
 public:
  StandaloneAudioTrackSource();
  ~StandaloneAudioTrackSource() override;

  void Start();
  void Stop();

  // MediaSourceInterface implementation.
  SourceState state() const override;
  bool remote() const override { return false; }

  // AudioSourceInterface implementation.
  void AddSink(AudioTrackSinkInterface* sink) override;
  void RemoveSink(AudioTrackSinkInterface* sink) override;

  // Allows callers to push 10 ms 16-bit PCM frames directly into the source.
  void PushAudioFrame(const AudioFrame& frame);

  using AudioSendStreamPtr =
      std::unique_ptr<AudioSendStream, std::function<void(AudioSendStream*)>>;

  // Creates a dedicated AudioSendStream associated with the supplied Call.
  AudioSendStreamPtr CreateSendStream(Call* call,
                                      const AudioSendStream::Config& config);

 private:
  void SetState(SourceState new_state);

  std::atomic<SourceState> state_;
  std::atomic<bool> started_;

  mutable Mutex sink_lock_;
  std::vector<AudioTrackSinkInterface*> sinks_ RTC_GUARDED_BY(sink_lock_);
};

}  // namespace webrtc

#endif  // SDK_OBJC_NATIVE_SRC_STANDALONE_AUDIO_TRACK_SOURCE_H_
