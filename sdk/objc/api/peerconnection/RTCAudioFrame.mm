/*
 *  Copyright 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCAudioFrame.h"

[[maybe_unused]] static inline size_t BytesForFrame(NSUInteger channels,
                                                    NSUInteger framesPerChannel) {
  return channels * framesPerChannel * sizeof(int16_t);
}

@implementation RTC_OBJC_TYPE(RTCAudioFrame) {
  NSData *_data;
  int _sampleRateHz;
  NSUInteger _channels;
  NSUInteger _framesPerChannel;
  uint32_t _timestamp;
  NSNumber *_absoluteCaptureTimestampMs;
}

- (instancetype)initWithData:(NSData *)data
                sampleRateHz:(int)sampleRateHz
                    channels:(NSUInteger)channels
             framesPerChannel:(NSUInteger)framesPerChannel
                    timestamp:(uint32_t)timestamp
   absoluteCaptureTimestampMs:(NSNumber *)absoluteCaptureTimestampMs {
  NSParameterAssert(sampleRateHz > 0);
  NSParameterAssert(channels > 0);
  NSParameterAssert(framesPerChannel > 0);
  NSParameterAssert(data.length == BytesForFrame(channels, framesPerChannel));

  self = [super init];
  if (self) {
    _data = [data copy];
    _sampleRateHz = sampleRateHz;
    _channels = channels;
    _framesPerChannel = framesPerChannel;
    _timestamp = timestamp;
    _absoluteCaptureTimestampMs = absoluteCaptureTimestampMs;
  }
  return self;
}

- (NSData *)data {
  return _data;
}

- (int)sampleRateHz {
  return _sampleRateHz;
}

- (NSUInteger)channels {
  return _channels;
}

- (NSUInteger)framesPerChannel {
  return _framesPerChannel;
}

- (uint32_t)timestamp {
  return _timestamp;
}

- (NSNumber *)absoluteCaptureTimestampMs {
  return _absoluteCaptureTimestampMs;
}

@end
