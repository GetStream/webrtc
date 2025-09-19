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

#import "sdk/objc/base/RTCMacros.h"

NS_ASSUME_NONNULL_BEGIN

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCAudioFrame) : NSObject

- (instancetype)init NS_UNAVAILABLE;

- (instancetype)initWithData:(NSData *)data
                sampleRateHz:(int)sampleRateHz
                    channels:(NSUInteger)channels
             framesPerChannel:(NSUInteger)framesPerChannel
                    timestamp:(uint32_t)timestamp
   absoluteCaptureTimestampMs:(nullable NSNumber *)absoluteCaptureTimestampMs
    NS_DESIGNATED_INITIALIZER;

@property(nonatomic, readonly) NSData *data;
@property(nonatomic, readonly) int sampleRateHz;
@property(nonatomic, readonly) NSUInteger channels;
@property(nonatomic, readonly) NSUInteger framesPerChannel;
@property(nonatomic, readonly) uint32_t timestamp;
@property(nonatomic, readonly, nullable)
    NSNumber *absoluteCaptureTimestampMs;

@end

NS_ASSUME_NONNULL_END
