/*
 * Copyright 2025 The WebRTC project authors. All Rights Reserved.
 *
 * Use of this source code is governed by a BSD-style license
 * that can be found in the LICENSE file in the root of the source
 * tree. An additional intellectual property rights grant can be found
 * in the file PATENTS. All contributing project authors may
 * be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCAudioPCMChunker.h"

#include <algorithm>
#include <vector>

#include <cstring>

#import "RTCAudioFrame.h"

#include "rtc_base/checks.h"
#include "rtc_base/time_utils.h"

namespace {
constexpr double kNanosecondsPerSecond = 1e9;
}

@implementation RTC_OBJC_TYPE(RTCAudioPCMChunker) {
  std::vector<int16_t> _pending;
  NSUInteger _channels;
  int _sampleRate;
  NSUInteger _framesPerChunk;
  NSUInteger _samplesPerChunk;
  int64_t _nextChunkTimestampNs;
}

- (instancetype)initWithSampleRate:(int)sampleRate channels:(NSUInteger)channels {
  self = [super init];
  if (self) {
    [self resetWithSampleRate:sampleRate channels:channels];
  }
  return self;
}

- (void)resetWithSampleRate:(int)sampleRate channels:(NSUInteger)channels {
  RTC_DCHECK_GT(sampleRate, 0);
  RTC_DCHECK_GT(channels, 0u);

  _sampleRate = sampleRate;
  _channels = channels;
  _framesPerChunk = static_cast<NSUInteger>(sampleRate / 100);
  RTC_DCHECK_GT(_framesPerChunk, 0u);
  _samplesPerChunk = _framesPerChunk * channels;
  [self flush];
}

- (void)flush {
  _pending.clear();
  _nextChunkTimestampNs = -1;
}

- (NSUInteger)pendingFrames {
  if (_channels == 0) {
    return 0;
  }
  return _pending.size() / _channels;
}

- (int)sampleRate {
  return _sampleRate;
}

- (NSUInteger)channels {
  return _channels;
}

- (void)consumePCM:(const int16_t *)samples
            frames:(NSUInteger)frames
       sampleRate:(int)sampleRate
         channels:(NSUInteger)channels
      timestampNs:(int64_t)timestampNs
           handler:(void (^)(RTC_OBJC_TYPE(RTCAudioFrame) *))handler {
  if (frames == 0 || !samples) {
    return;
  }
  RTC_DCHECK(handler);

  if (sampleRate > 0 && channels > 0 &&
      (sampleRate != _sampleRate || channels != _channels)) {
    [self resetWithSampleRate:sampleRate channels:channels];
  }
  if (_channels == 0 || _framesPerChunk == 0) {
    return;
  }

  const size_t incomingSamples = frames * _channels;
  const size_t previousSize = _pending.size();
  _pending.resize(previousSize + incomingSamples);
  memcpy(_pending.data() + previousSize, samples, incomingSamples * sizeof(int16_t));

  if (_nextChunkTimestampNs < 0) {
    if (timestampNs >= 0) {
      _nextChunkTimestampNs = timestampNs;
    } else {
      _nextChunkTimestampNs = rtc::TimeNanos();
    }
  }

  const size_t chunkSamples = _samplesPerChunk;
  const int64_t chunkDurationNs =
      static_cast<int64_t>(kNanosecondsPerSecond * _framesPerChunk / _sampleRate);

  while (_pending.size() >= chunkSamples) {
    RTC_OBJC_TYPE(RTCAudioFrame) *frame =
        [[RTC_OBJC_TYPE(RTCAudioFrame) alloc] initWithPCM:_pending.data()
                                                    frames:_framesPerChunk
                                                sampleRate:_sampleRate
                                                  channels:_channels
                                               timestampNs:_nextChunkTimestampNs];
    handler(frame);

    _pending.erase(_pending.begin(), _pending.begin() + chunkSamples);
    _nextChunkTimestampNs += chunkDurationNs;
  }

  if (_pending.empty()) {
    _nextChunkTimestampNs = -1;
  }
}

@end
