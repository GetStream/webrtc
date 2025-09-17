/*
 * Copyright 2025 The WebRTC project authors. All Rights Reserved.
 *
 * Use of this source code is governed by a BSD-style license
 * that can be found in the LICENSE file in the root of the source
 * tree. An additional intellectual property rights grant can be found
 * in the file PATENTS. All contributing project authors may
 * be found in the AUTHORS file in the root of the source tree.
 */

#import "sdk/objc/base/RTCAudioCapturer.h"

NS_ASSUME_NONNULL_BEGIN

@class RTC_OBJC_TYPE(RTCAudioDeviceModule);
@class RTC_OBJC_TYPE(RTCMicrophoneAudioCapturer);

RTC_OBJC_EXPORT
@protocol RTC_OBJC_TYPE(RTCMicrophoneAudioCapturerDelegate) <RTC_OBJC_TYPE(RTCAudioCapturerDelegate)>
@optional
- (void)microphoneCapturer:(RTC_OBJC_TYPE(RTCMicrophoneAudioCapturer) *)capturer
    willCaptureAudioSamples:(int16_t *)samples
                     frames:(NSUInteger)frames
                 sampleRate:(int)sampleRate
                   channels:(NSUInteger)channels
                timestampNs:(int64_t)timestampNs;
@end

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCMicrophoneAudioCapturer) : RTC_OBJC_TYPE(RTCAudioCapturer)

- (instancetype)initWithAudioDeviceModule:(RTC_OBJC_TYPE(RTCAudioDeviceModule) *)audioDeviceModule
                                  delegate:(id<RTC_OBJC_TYPE(RTCMicrophoneAudioCapturerDelegate)>)delegate NS_DESIGNATED_INITIALIZER;

- (instancetype)initWithDelegate:(id<RTC_OBJC_TYPE(RTCAudioCapturerDelegate)>)delegate NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
