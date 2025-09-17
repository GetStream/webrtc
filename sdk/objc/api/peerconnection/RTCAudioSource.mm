/*
 *  Copyright 2016 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <Foundation/Foundation.h>

#import "RTCAudioSource+Private.h"
#import "sdk/objc/base/RTCAudioCapturer.h"
#import "sdk/objc/base/RTCAudioFrame.h"

#include "rtc_base/checks.h"
#include "sdk/objc/native/src/objc_audio_track_source.h"

@interface RTC_OBJC_TYPE (RTCAudioSource) () <RTC_OBJC_TYPE(RTCAudioCapturerDelegate)>
- (void)pushAudioFrame:(RTC_OBJC_TYPE(RTCAudioFrame) *)frame;
@end

@implementation RTC_OBJC_TYPE (RTCAudioSource) {
  dispatch_queue_t _captureQueue;
}

@synthesize volume = _volume;
@synthesize nativeAudioSource = _nativeAudioSource;

- (instancetype)
      initWithFactory:(RTC_OBJC_TYPE(RTCPeerConnectionFactory) *)factory
    nativeAudioSource:
        (webrtc::scoped_refptr<webrtc::AudioSourceInterface>)nativeAudioSource {
  RTC_DCHECK(factory);
  RTC_DCHECK(nativeAudioSource);

  self = [super initWithFactory:factory
                  nativeMediaSource:nativeAudioSource
                               type:RTC_OBJC_TYPE(RTCMediaSourceTypeAudio)];
  if (self) {
    _nativeAudioSource = nativeAudioSource;
    _captureQueue = dispatch_queue_create("org.webrtc.audio.capturer", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (instancetype)
      initWithFactory:(RTC_OBJC_TYPE(RTCPeerConnectionFactory) *)factory
    nativeMediaSource:
        (webrtc::scoped_refptr<webrtc::MediaSourceInterface>)nativeMediaSource
                 type:(RTC_OBJC_TYPE(RTCMediaSourceType))type {
  RTC_DCHECK_NOTREACHED();
  return nil;
}

- (NSString *)description {
  NSString *stateString = [[self class] stringForState:self.state];
  return [NSString stringWithFormat:@"RTC_OBJC_TYPE(RTCAudioSource)( %p ): %@",
                                    self,
                                    stateString];
}

- (void)setVolume:(double)volume {
  _volume = volume;
  _nativeAudioSource->SetVolume(volume);
}

#pragma mark - RTCAudioCapturerDelegate

- (void)capturer:(RTC_OBJC_TYPE(RTCAudioCapturer) *)capturer
    didCaptureAudioFrame:(RTC_OBJC_TYPE(RTCAudioFrame) *)frame {
  if (!frame) {
    return;
  }
  dispatch_async(_captureQueue, ^{
    [self pushAudioFrame:frame];
  });
}

#pragma mark - Private

- (void)pushAudioFrame:(RTC_OBJC_TYPE(RTCAudioFrame) *)frame {
  webrtc::ObjCAudioTrackSource *pushable =
      webrtc::ObjCAudioTrackSource::FromAudioSource(_nativeAudioSource.get());
  if (!pushable) {
    return;
  }
  pushable->OnCapturedFrame(frame);
}

@end
