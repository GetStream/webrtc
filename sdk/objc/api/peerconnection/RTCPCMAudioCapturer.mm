/*
 * Copyright 2024 The WebRTC project authors. All Rights Reserved.
 *
 * Use of this source code is governed by a BSD-style license
 * that can be found in the LICENSE file in the root of the source
 * tree. An additional intellectual property rights grant can be found
 * in the file PATENTS.  All contributing project authors may
 * be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCPCMAudioCapturer.h"

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#include <cmath>

#import "RTCLogging.h"
#import "RTCAudioFrame.h"
#import "RTCAudioSource.h"

namespace {
constexpr size_t kBitsPerSample = 16;
constexpr double kChunkDurationMs = 10.0;
}

@interface RTC_OBJC_TYPE(RTCPCMAudioCapturer) () {
  id<RTC_OBJC_TYPE(RTCAudioCapturerDelegate)> _delegate;
  NSMutableData *_pendingData;
  int _sampleRateHz;
  NSUInteger _channels;
  uint32_t _timestamp;
  BOOL _hasPendingTimestampMs;
  double _pendingTimestampMs;
}
@end

@implementation RTC_OBJC_TYPE(RTCPCMAudioCapturer)

- (instancetype)initWithDelegate:(id<RTC_OBJC_TYPE(RTCAudioCapturerDelegate)>)delegate {
  NSParameterAssert(delegate);
  self = [super init];
  if (self) {
    _delegate = delegate;
    _pendingData = [NSMutableData data];
    _sampleRateHz = 0;
    _channels = 0;
    _timestamp = 0;
    _hasPendingTimestampMs = NO;
    _pendingTimestampMs = 0.0;
  }
  return self;
}

- (id<RTC_OBJC_TYPE(RTCAudioCapturerDelegate)>)delegate {
  return _delegate;
}

- (void)captureBuffer:(CMSampleBufferRef)buffer {
  if (!buffer) {
    return;
  }

  size_t sampleCount = CMSampleBufferGetNumSamples(buffer);
  if (sampleCount == 0) {
    return;
  }

  CMAudioFormatDescriptionRef format = CMSampleBufferGetFormatDescription(buffer);
  if (!format) {
    RTCLogError(@"CMSampleBuffer without format description");
    return;
  }

  const AudioStreamBasicDescription *asbd =
      CMAudioFormatDescriptionGetStreamBasicDescription(format);
  if (!asbd) {
    RTCLogError(@"Unable to obtain stream description from CMSampleBuffer");
    return;
  }

  if (asbd->mFormatID != kAudioFormatLinearPCM) {
    RTCLogError(@"Unsupported audio format: %u", static_cast<unsigned>(asbd->mFormatID));
    return;
  }

  if (!(asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) ||
      (asbd->mFormatFlags & kAudioFormatFlagIsFloat) ||
      (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ||
      (asbd->mFormatFlags & kAudioFormatFlagIsBigEndian) ||
      asbd->mBitsPerChannel != kBitsPerSample) {
    RTCLogError(@"CMSampleBuffer must contain interleaved 16-bit PCM audio");
    return;
  }

  int sampleRate = static_cast<int>(asbd->mSampleRate);
  if (sampleRate <= 0) {
    RTCLogError(@"Invalid sample rate %d", sampleRate);
    return;
  }

  NSUInteger channels = asbd->mChannelsPerFrame;
  if (channels == 0) {
    RTCLogError(@"Audio buffer reports zero channels");
    return;
  }

  size_t framesPerChunk = static_cast<size_t>(sampleRate / 100);
  if (framesPerChunk == 0 || sampleRate % 100 != 0) {
    RTCLogError(@"Sample rate %d unsupported for 10ms framing", sampleRate);
    return;
  }

  BOOL formatChanged = (_sampleRateHz != sampleRate) || (_channels != channels);
  if (formatChanged) {
    _sampleRateHz = sampleRate;
    _channels = channels;
    _timestamp = 0;
    [_pendingData setLength:0];
    _hasPendingTimestampMs = NO;
  }

  size_t bytesPerFrame = channels * sizeof(int16_t);
  size_t chunkBytes = framesPerChunk * bytesPerFrame;

  size_t bufferListSize = 0;
  OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      buffer, &bufferListSize, nullptr, 0, nullptr, nullptr, 0, nullptr);
  if (status != noErr) {
    RTCLogError(@"Failed to query audio buffer list size (status=%d)", status);
    return;
  }

  AudioBufferList *audioBufferList =
      static_cast<AudioBufferList *>(malloc(bufferListSize));
  if (!audioBufferList) {
    RTCLogError(@"Failed to allocate audio buffer list");
    return;
  }

  CMBlockBufferRef blockBuffer = nullptr;
  status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      buffer, &bufferListSize, audioBufferList, bufferListSize, nullptr, nullptr,
      0, &blockBuffer);
  if (status != noErr) {
    RTCLogError(@"Failed to extract audio buffer list (status=%d)", status);
    free(audioBufferList);
    return;
  }

  for (UInt32 i = 0; i < audioBufferList->mNumberBuffers; ++i) {
    const AudioBuffer &audioBuffer = audioBufferList->mBuffers[i];
    if (audioBuffer.mData && audioBuffer.mDataByteSize > 0) {
      [_pendingData appendBytes:audioBuffer.mData length:audioBuffer.mDataByteSize];
    }
  }

  CFRelease(blockBuffer);
  free(audioBufferList);

  CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(buffer);
  BOOL hasPts = CMTIME_IS_NUMERIC(presentationTime);
  double nextChunkTimestampMs = NAN;
  if (_hasPendingTimestampMs) {
    nextChunkTimestampMs = _pendingTimestampMs;
    _hasPendingTimestampMs = NO;
  } else if (hasPts) {
    nextChunkTimestampMs = CMTimeGetSeconds(presentationTime) * 1000.0;
  }

  while (_pendingData.length >= chunkBytes) {
    NSData *chunk = [_pendingData subdataWithRange:NSMakeRange(0, chunkBytes)];
    [_pendingData replaceBytesInRange:NSMakeRange(0, chunkBytes)
                            withBytes:nullptr
                               length:0];

    NSNumber *absoluteCaptureTimestamp = nil;
    if (!std::isnan(nextChunkTimestampMs)) {
      absoluteCaptureTimestamp =
          @(llround(nextChunkTimestampMs));
      nextChunkTimestampMs += kChunkDurationMs;
    }

    RTC_OBJC_TYPE(RTCAudioFrame) *frame =
        [[RTC_OBJC_TYPE(RTCAudioFrame) alloc] initWithData:chunk
                                             sampleRateHz:_sampleRateHz
                                                 channels:_channels
                                          framesPerChannel:framesPerChunk
                                                 timestamp:_timestamp
                                absoluteCaptureTimestampMs:absoluteCaptureTimestamp];
    [_delegate pushAudioFrame:frame];
    _timestamp += framesPerChunk;
  }

  if (_pendingData.length > 0 && !std::isnan(nextChunkTimestampMs)) {
    _pendingTimestampMs = nextChunkTimestampMs;
    _hasPendingTimestampMs = YES;
  }
}

@end
