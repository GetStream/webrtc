/*
 *  Copyright 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCAudioFrame.h"

#include <algorithm>
#include <cstring>

#import "RTCAudioFrame+Private.h"

#include "rtc_base/checks.h"

@implementation RTC_OBJC_TYPE(RTCAudioFrame) {
  NSData *_pcmData;
  NSUInteger _frames;
  NSUInteger _channels;
  int _sampleRate;
  int64_t _timestampNs;
}

@synthesize pcmData = _pcmData;
@synthesize frames = _frames;
@synthesize channels = _channels;
@synthesize sampleRate = _sampleRate;
@synthesize timestampNs = _timestampNs;

- (instancetype)initWithPCM:(const int16_t *)pcm
                      frames:(NSUInteger)frames
                  sampleRate:(int)sampleRate
                    channels:(NSUInteger)channels
                 timestampNs:(int64_t)timestampNs {
  NSParameterAssert(pcm);
  NSParameterAssert(frames > 0);
  NSParameterAssert(sampleRate > 0);
  NSParameterAssert(channels > 0);

  self = [super init];
  if (self) {
    const NSUInteger sampleCount = frames * channels;
    const NSUInteger byteCount = sampleCount * sizeof(int16_t);
    _pcmData = [[NSData alloc] initWithBytes:pcm length:byteCount];
    _frames = frames;
    _channels = channels;
    _sampleRate = sampleRate;
    _timestampNs = timestampNs;
  }
  return self;
}

- (const int16_t *)int16Data {
  return reinterpret_cast<const int16_t *>(_pcmData.bytes);
}

- (void)fillNativeAudioFrame:(webrtc::AudioFrame *)frame {
  RTC_DCHECK(frame);
  const size_t samplesPerChannel = _frames;
  const size_t channelCount = _channels;

  frame->ResetWithoutMuting();
  frame->SetSampleRateAndChannelSize(_sampleRate);
  auto buffer = frame->mutable_data(samplesPerChannel, channelCount);
  RTC_DCHECK_EQ(buffer.size(), samplesPerChannel * channelCount);

  const int16_t *src = reinterpret_cast<const int16_t *>(_pcmData.bytes);
  std::copy(src, src + buffer.size(), buffer.begin());

  frame->timestamp_ = 0;  // The caller may override if RTP timestamps are relevant.
  frame->elapsed_time_ms_ = -1;
  frame->ntp_time_ms_ = -1;
  frame->set_absolute_capture_timestamp_ms(_timestampNs / 1000000);
}

@end
