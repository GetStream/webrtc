/*
 * Copyright 2025 The WebRTC project authors. All Rights Reserved.
 *
 * Use of this source code is governed by a BSD-style license
 * that can be found in the LICENSE file in the root of the source
 * tree. An additional intellectual property rights grant can be found
 * in the file PATENTS. All contributing project authors may
 * be found in the AUTHORS file in the root of the source tree.
 */

#ifndef SDK_OBJC_NATIVE_SRC_OBJC_AUDIO_TRACK_SOURCE_H_
#define SDK_OBJC_NATIVE_SRC_OBJC_AUDIO_TRACK_SOURCE_H_

#import <Foundation/Foundation.h>

#include <vector>

#include "api/audio_options.h"
#include "api/media_stream_interface.h"
#include "api/notifier.h"
#include "rtc_base/synchronization/mutex.h"
#include "sdk/objc/base/RTCMacros.h"

RTC_FWD_DECL_OBJC_CLASS(RTC_OBJC_TYPE(RTCAudioFrame));

namespace webrtc {

class ObjCAudioTrackSource : public Notifier<AudioSourceInterface> {
 public:
  ObjCAudioTrackSource();
  ~ObjCAudioTrackSource() override;

  // AudioSourceInterface overrides.
  SourceState state() const override;
  bool remote() const override;
  const AudioOptions options() const override { return options_; }
  void AddSink(AudioTrackSinkInterface* sink) override;
  void RemoveSink(AudioTrackSinkInterface* sink) override;

  void OnCapturedFrame(RTC_OBJC_TYPE(RTCAudioFrame) *frame);

 static ObjCAudioTrackSource* FromAudioSource(AudioSourceInterface* source);

 private:
  static void RegisterInstance(ObjCAudioTrackSource* instance);
  static void UnregisterInstance(ObjCAudioTrackSource* instance);

  AudioOptions options_;
  webrtc::Mutex sink_lock_;
  std::vector<AudioTrackSinkInterface*> sinks_ RTC_GUARDED_BY(sink_lock_);
};

}  // namespace webrtc

#endif  // SDK_OBJC_NATIVE_SRC_OBJC_AUDIO_TRACK_SOURCE_H_
