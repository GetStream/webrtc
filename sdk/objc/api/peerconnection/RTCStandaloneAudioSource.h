/*
 *  Copyright 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCAudioSource.h"

NS_ASSUME_NONNULL_BEGIN

@class RTC_OBJC_TYPE(RTCAudioFrame);
@class RTC_OBJC_TYPE(RTCPeerConnectionFactory);

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCStandaloneAudioSource) : RTC_OBJC_TYPE(RTCAudioSource)

- (instancetype)init NS_UNAVAILABLE;

- (instancetype)initWithFactory:
                    (RTC_OBJC_TYPE(RTCPeerConnectionFactory) *)factory;

- (void)start;
- (void)stop;

- (void)pushAudioFrame:(RTC_OBJC_TYPE(RTCAudioFrame) *)frame;

@end

NS_ASSUME_NONNULL_END
