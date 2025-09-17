/*
 * Copyright 2025 The WebRTC project authors. All Rights Reserved.
 *
 * Use of this source code is governed by a BSD-style license
 * that can be found in the LICENSE file in the root of the source
 * tree. An additional intellectual property rights grant can be found
 * in the file PATENTS. All contributing project authors may
 * be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCMicrophoneAudioCapturer.h"

#import "RTCAudioDeviceModule+Private.h"

@interface RTC_OBJC_TYPE(RTCMicrophoneAudioCapturer) ()
@property(nonatomic, weak) RTC_OBJC_TYPE(RTCAudioDeviceModule) *audioDeviceModule;
@end

@implementation RTC_OBJC_TYPE(RTCMicrophoneAudioCapturer)

- (instancetype)initWithAudioDeviceModule:(RTC_OBJC_TYPE(RTCAudioDeviceModule) *)audioDeviceModule
                                  delegate:(id<RTC_OBJC_TYPE(RTCMicrophoneAudioCapturerDelegate)>)delegate {
  NSParameterAssert(audioDeviceModule);
  self = [super initWithDelegate:delegate];
  if (self) {
    _audioDeviceModule = audioDeviceModule;
  }
  return self;
}

- (void)start {
  if (self.isRunning) {
    return;
  }

  [super start];

  __weak typeof(self) weakSelf = self;
  [self.audioDeviceModule setMicrophoneFrameBlock:^(int16_t *samples,
                                                     size_t frames,
                                                     int sampleRate,
                                                     size_t channels,
                                                     int64_t timestampNs) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.isRunning) {
      return;
    }

    id<RTC_OBJC_TYPE(RTCMicrophoneAudioCapturerDelegate)> delegate =
        (id<RTC_OBJC_TYPE(RTCMicrophoneAudioCapturerDelegate)>)strongSelf.delegate;
    if ([delegate respondsToSelector:@selector(microphoneCapturer:willCaptureAudioSamples:frames:sampleRate:channels:timestampNs:)]) {
      [delegate microphoneCapturer:strongSelf
            willCaptureAudioSamples:samples
                             frames:frames
                         sampleRate:sampleRate
                           channels:channels
                        timestampNs:timestampNs];
    }
  }];
}

- (void)stop {
  if (!self.isRunning) {
    return;
  }

  [self.audioDeviceModule setMicrophoneFrameBlock:nil];

  [super stop];
}

@end
