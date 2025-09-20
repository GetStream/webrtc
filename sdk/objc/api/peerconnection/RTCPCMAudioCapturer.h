/*
 *  Copyright 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>

#import "sdk/objc/base/RTCMacros.h"

NS_ASSUME_NONNULL_BEGIN

@protocol RTC_OBJC_TYPE(RTCAudioCapturerDelegate);

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCPCMAudioCapturer) : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDelegate:(id<RTC_OBJC_TYPE(RTCAudioCapturerDelegate)>)delegate
    NS_DESIGNATED_INITIALIZER;

/**
 * Ingests a CMSampleBuffer containing linear PCM audio, normalizes it into 10 ms
 * chunks, and forwards the data to the delegate.
 * Unsupported formats are dropped and logged.
 */
- (void)captureBuffer:(CMSampleBufferRef)buffer;

@property(nonatomic, readonly)
    id<RTC_OBJC_TYPE(RTCAudioCapturerDelegate)> delegate;

@end

NS_ASSUME_NONNULL_END
