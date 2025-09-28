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
struct PCMLevelStats {
  double rms;
  int32_t maxAbs;
  bool allZero;
};

struct PCMLevelAccumulator {
  long double sumSquares = 0;
  int32_t maxAbs = 0;
  size_t sampleCount = 0;
  bool allZero = true;

  void AddSamples(const int16_t *samples, size_t count) {
    if (!samples || count == 0) {
      return;
    }
    sampleCount += count;
    for (size_t i = 0; i < count; ++i) {
      const int32_t sample = samples[i];
      if (sample != 0) {
        allZero = false;
      }
      const int32_t absSample = sample < 0 ? -sample : sample;
      if (absSample > maxAbs) {
        maxAbs = absSample;
      }
      sumSquares += static_cast<long double>(sample) *
                    static_cast<long double>(sample);
    }
  }

  PCMLevelStats Finalize() const {
    PCMLevelStats stats;
    stats.maxAbs = maxAbs;
    stats.allZero = allZero;
    stats.rms = sampleCount > 0
                     ? std::sqrt(static_cast<double>(sumSquares / sampleCount))
                     : 0.0;
    return stats;
  }
};
}

@interface RTC_OBJC_TYPE(RTCPCMAudioCapturer) () {
  id<RTC_OBJC_TYPE(RTCAudioCapturerDelegate)> _delegate;
  NSMutableData *_pendingData;
  int _sampleRateHz;
  NSUInteger _channels;
  uint32_t _timestamp;
  BOOL _hasPendingTimestampMs;
  double _pendingTimestampMs;
  uint32_t _frameCounter;
  CFAbsoluteTime _lastFormatResetTime;
  size_t _consecutiveZeroFrames;
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
    _frameCounter = 0;
    _lastFormatResetTime = 0;
    _consecutiveZeroFrames = 0;
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
    const size_t pendingBeforeReset = _pendingData.length;
    const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    const double deltaMs = _lastFormatResetTime > 0
                               ? (now - _lastFormatResetTime) * 1000.0
                               : 0.0;
    _sampleRateHz = sampleRate;
    _channels = channels;
    _timestamp = 0;
    [_pendingData setLength:0];
    _hasPendingTimestampMs = NO;
    _frameCounter = 0;
    _lastFormatResetTime = now;
    _consecutiveZeroFrames = 0;
    RTCLogInfo(@"RTCPCMAudioCapturer format reset: %d Hz, %lu ch pending=%zuB delta=%.2fms",
               _sampleRateHz,
               (unsigned long)_channels,
               pendingBeforeReset,
               deltaMs);
  }

  size_t bytesPerFrame = channels * sizeof(int16_t);
  size_t chunkBytes = framesPerChunk * bytesPerFrame;
  const size_t pendingBytesBeforeAppend = _pendingData.length;

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

  size_t totalIncomingBytes = 0;
  PCMLevelAccumulator intakeAccumulator;
  for (UInt32 i = 0; i < audioBufferList->mNumberBuffers; ++i) {
    const AudioBuffer &audioBuffer = audioBufferList->mBuffers[i];
    if (audioBuffer.mData && audioBuffer.mDataByteSize > 0) {
      totalIncomingBytes += audioBuffer.mDataByteSize;
      intakeAccumulator.AddSamples(static_cast<const int16_t *>(audioBuffer.mData),
                                   audioBuffer.mDataByteSize / sizeof(int16_t));
    }
  }
  if (totalIncomingBytes > 0) {
    const PCMLevelStats intakeStats = intakeAccumulator.Finalize();
    RTCLogInfo(@"RTCPCMAudioCapturer PCM buffer: rate=%.1fHz channels=%u bits=%u flags=0x%08x incoming=%zuB pendingBefore=%zuB rms=%.2f max=%d zero=%@",
               asbd->mSampleRate,
               static_cast<unsigned>(asbd->mChannelsPerFrame),
               static_cast<unsigned>(asbd->mBitsPerChannel),
               static_cast<unsigned>(asbd->mFormatFlags),
               totalIncomingBytes,
               pendingBytesBeforeAppend,
               intakeStats.rms,
               intakeStats.maxAbs,
               intakeStats.allZero ? @"YES" : @"NO");
  } else {
    RTCLogInfo(@"RTCPCMAudioCapturer PCM buffer: rate=%.1fHz channels=%u bits=%u flags=0x%08x incoming=0B pendingBefore=%zuB",
               asbd->mSampleRate,
               static_cast<unsigned>(asbd->mChannelsPerFrame),
               static_cast<unsigned>(asbd->mBitsPerChannel),
               static_cast<unsigned>(asbd->mFormatFlags),
               pendingBytesBeforeAppend);
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

    ++_frameCounter;
    const size_t chunkLength = chunk.length;
    if (chunkLength != chunkBytes) {
      RTCLogWarning(@"RTCPCMAudioCapturer unexpected chunk size: %zuB (expected %zuB) pending=%luB",
                    chunkLength,
                    chunkBytes,
                    (unsigned long)_pendingData.length);
    }
    PCMLevelAccumulator chunkAccumulator;
    chunkAccumulator.AddSamples(static_cast<const int16_t *>(chunk.bytes),
                                chunkLength / sizeof(int16_t));
    const PCMLevelStats chunkStats = chunkAccumulator.Finalize();
    RTCLogVerbose(@"RTCPCMAudioCapturer chunk #%u frames=%zu bytes=%zu pending=%luB ts=%u absTs=%@ rms=%.2f max=%d zero=%@",
                  _frameCounter,
                  framesPerChunk,
                  chunkLength,
                  (unsigned long)_pendingData.length,
                  _timestamp,
                  absoluteCaptureTimestamp ? absoluteCaptureTimestamp.stringValue : @"nil",
                  chunkStats.rms,
                  chunkStats.maxAbs,
                  chunkStats.allZero ? @"YES" : @"NO");

    RTC_OBJC_TYPE(RTCAudioFrame) *frame =
        [[RTC_OBJC_TYPE(RTCAudioFrame) alloc] initWithData:chunk
                                             sampleRateHz:_sampleRateHz
                                                 channels:_channels
                                          framesPerChannel:framesPerChunk
                                                 timestamp:_timestamp
                                absoluteCaptureTimestampMs:absoluteCaptureTimestamp];
    const NSUInteger expectedFramesPerChannel =
        _sampleRateHz > 0 ? static_cast<NSUInteger>(_sampleRateHz / 100) : 0;
    if (expectedFramesPerChannel > 0) {
      NSAssert(frame.framesPerChannel == expectedFramesPerChannel,
               @"Unexpected framesPerChannel %lu (expected %lu) for rate %d",
               (unsigned long)frame.framesPerChannel,
               (unsigned long)expectedFramesPerChannel,
               _sampleRateHz);
    }
    const NSData *frameData = frame.data;
    PCMLevelAccumulator frameAccumulator;
    frameAccumulator.AddSamples(static_cast<const int16_t *>(frameData.bytes),
                                frameData.length / sizeof(int16_t));
    const PCMLevelStats frameStats = frameAccumulator.Finalize();
    if (frameStats.allZero) {
      ++_consecutiveZeroFrames;
    } else {
      _consecutiveZeroFrames = 0;
    }
    RTCLogVerbose(@"RTCPCMAudioCapturer push #%u rate=%dHz channels=%lu frames=%lu bytes=%lu rms=%.2f max=%d zeroRun=%zu",
                  _frameCounter,
                  frame.sampleRateHz,
                  (unsigned long)frame.channels,
                  (unsigned long)frame.framesPerChannel,
                  (unsigned long)frameData.length,
                  frameStats.rms,
                  frameStats.maxAbs,
                  _consecutiveZeroFrames);
    [_delegate pushAudioFrame:frame];
    _timestamp += framesPerChunk;
  }

  if (_pendingData.length > 0 && !std::isnan(nextChunkTimestampMs)) {
    _pendingTimestampMs = nextChunkTimestampMs;
    _hasPendingTimestampMs = YES;
  }
}

@end
