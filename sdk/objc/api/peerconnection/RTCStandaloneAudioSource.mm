/*
 *  Copyright 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCStandaloneAudioSource+Private.h"

#import "RTCAudioFrame.h"
#import "RTCAudioSource+Private.h"
#import "RTCPeerConnectionFactory+Private.h"

#include <utility>

#include "api/audio/audio_frame.h"
#include "api/make_ref_counted.h"
#include "rtc_base/checks.h"
#include "sdk/objc/native/src/standalone_audio_track_source.h"

namespace {

using NativeStandaloneSource = webrtc::StandaloneAudioTrackSource;

}  // namespace

@implementation RTC_OBJC_TYPE(RTCStandaloneAudioSource) {
  rtc::scoped_refptr<NativeStandaloneSource> _nativeStandaloneSource;
}

@synthesize nativeStandaloneSource = _nativeStandaloneSource;

- (instancetype)initWithFactory:(RTC_OBJC_TYPE(RTCPeerConnectionFactory) *)factory
        nativeStandaloneSource:
            (rtc::scoped_refptr<NativeStandaloneSource>)nativeStandaloneSource {
  RTC_DCHECK(factory);
  RTC_DCHECK(nativeStandaloneSource);
  self = [super initWithFactory:factory nativeAudioSource:nativeStandaloneSource];
  if (self) {
    _nativeStandaloneSource = std::move(nativeStandaloneSource);
  }
  return self;
}

- (instancetype)initWithFactory:(RTC_OBJC_TYPE(RTCPeerConnectionFactory) *)factory {
  RTC_DCHECK(factory);
  auto native_source = rtc::make_ref_counted<NativeStandaloneSource>();
  return [self initWithFactory:factory nativeStandaloneSource:native_source];
}

- (void)start {
  _nativeStandaloneSource->Start();
}

- (void)stop {
  _nativeStandaloneSource->Stop();
}

- (void)pushAudioFrame:(RTC_OBJC_TYPE(RTCAudioFrame) *)frame {
  if (!frame) {
    return;
  }

  webrtc::AudioFrame native_frame;
  native_frame.SetSampleRateAndChannelSize(frame.sampleRateHz);

  native_frame.UpdateFrame(frame.timestamp,
                           static_cast<const int16_t *>(frame.data.bytes),
                           frame.framesPerChannel, frame.sampleRateHz,
                           webrtc::AudioFrame::kNormalSpeech,
                           webrtc::AudioFrame::kVadUnknown, frame.channels);

  if (frame.absoluteCaptureTimestampMs != nil) {
    native_frame.set_absolute_capture_timestamp_ms(
        frame.absoluteCaptureTimestampMs.longLongValue);
  }

  _nativeStandaloneSource->PushAudioFrame(native_frame);
}

@end
