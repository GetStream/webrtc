/*
 * Copyright 2025 The WebRTC project authors. All Rights Reserved.
 *
 * Use of this source code is governed by a BSD-style license
 * that can be found in the LICENSE file in the root of the source
 * tree. An additional intellectual property rights grant can be found
 * in the file PATENTS. All contributing project authors may
 * be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCCMSampleBufferAudioCapturer.h"

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

#import "sdk/objc/base/RTCAudioFrame.h"
#import "sdk/objc/base/RTCAudioPCMChunker.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

namespace {
constexpr double kNanosecondsPerSecond = 1e9;
}  // namespace

@interface RTC_OBJC_TYPE(RTCCMSampleBufferAudioCapturer) () {
  RTC_OBJC_TYPE(RTCAudioPCMChunker) *_chunker;
  std::vector<int16_t> _interleavedScratch;
  BOOL _running;
}

@end

@implementation RTC_OBJC_TYPE(RTCCMSampleBufferAudioCapturer)

- (instancetype)initWithDelegate:(id<RTC_OBJC_TYPE(RTCAudioCapturerDelegate)>)delegate {
  self = [super initWithDelegate:delegate];
  if (self) {
    _chunker = nil;
    _running = NO;
  }
  return self;
}

- (void)start {
  if (_running) {
    return;
  }
  _running = YES;
  if (_chunker) {
    [_chunker flush];
  }
}

- (void)stop {
  if (!_running) {
    return;
  }
  _running = NO;
  if (_chunker) {
    [_chunker flush];
  }
}

- (BOOL)isRunning {
  return _running;
}

- (void)captureSampleBuffer:(CMSampleBufferRef)sampleBuffer {
  if (!_running || sampleBuffer == nil) {
    return;
  }
  if (!CMSampleBufferIsValid(sampleBuffer) || !CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }

  CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
  if (!formatDescription) {
    return;
  }

  const AudioStreamBasicDescription *asbd =
      CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
  if (!asbd) {
    return;
  }
  if (asbd->mFormatID != kAudioFormatLinearPCM) {
    return;
  }
  if ((asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0 ||
      (asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) == 0) {
    return;
  }
  if (asbd->mBitsPerChannel != 16) {
    return;
  }

  const BOOL nonInterleaved =
      (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  const NSUInteger channels = asbd->mChannelsPerFrame;
  if (channels == 0) {
    return;
  }

  const double sampleRateDouble = asbd->mSampleRate;
  if (sampleRateDouble <= 0.0) {
    return;
  }
  const int sampleRate = static_cast<int>(std::llround(sampleRateDouble));
  if (sampleRate <= 0) {
    return;
  }

  size_t frames = CMSampleBufferGetNumSamples(sampleBuffer);
  if (frames == 0) {
    return;
  }

  int64_t timestampNs = -1;
  const CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  if (CMTIME_IS_NUMERIC(presentationTime) && presentationTime.timescale != 0) {
    CMTime nanos = CMTimeConvertScale(presentationTime,
                                      NSEC_PER_SEC,
                                      kCMTimeRoundingMethod_Default);
    if (CMTIME_IS_NUMERIC(nanos) && nanos.timescale != 0) {
      if (nanos.timescale == NSEC_PER_SEC) {
        timestampNs = nanos.value;
      } else {
        const double seconds = CMTimeGetSeconds(nanos);
        if (std::isfinite(seconds)) {
          timestampNs = static_cast<int64_t>(std::llround(seconds * kNanosecondsPerSecond));
        }
      }
    }
  }

  const size_t audioBufferListSize = sizeof(AudioBufferList) +
                                     (channels > 0 ? (channels - 1) * sizeof(AudioBuffer) : 0);
  std::vector<uint8_t> audioBufferStorage(audioBufferListSize);
  memset(audioBufferStorage.data(), 0, audioBufferStorage.size());
  AudioBufferList *audioBufferList =
      reinterpret_cast<AudioBufferList *>(audioBufferStorage.data());

  CMBlockBufferRef blockBuffer = nullptr;
  size_t sizeOut = audioBufferListSize;
  const OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      &sizeOut,
      audioBufferList,
      audioBufferListSize,
      kCFAllocatorSystemDefault,
      kCFAllocatorSystemDefault,
      kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
      &blockBuffer);
  if (status != noErr) {
    if (blockBuffer) {
      CFRelease(blockBuffer);
    }
    return;
  }

  const size_t samplesExpected = frames * channels;
  const size_t bytesPerSample = sizeof(int16_t);
  const size_t bytesExpected = samplesExpected * bytesPerSample;

  const int buffers = audioBufferList->mNumberBuffers;
  const bool hasSingleInterleavedBuffer = !nonInterleaved && buffers == 1;

  const int16_t *interleavedSamples = nullptr;
  size_t framesAvailable = frames;

  if (hasSingleInterleavedBuffer) {
    const AudioBuffer &audioBuffer = audioBufferList->mBuffers[0];
    interleavedSamples = static_cast<const int16_t *>(audioBuffer.mData);
    if (!interleavedSamples) {
      CFRelease(blockBuffer);
      return;
    }
    const size_t bytesAvailable = audioBuffer.mDataByteSize;
    if (bytesExpected > 0) {
      framesAvailable = std::min(frames, bytesAvailable / (channels * bytesPerSample));
    }
  } else {
    _interleavedScratch.resize(samplesExpected);
    int16_t *dest = _interleavedScratch.data();
    if (!dest) {
      CFRelease(blockBuffer);
      return;
    }

    size_t writtenSamples = 0;
    if (nonInterleaved && buffers == static_cast<int>(channels)) {
      framesAvailable = std::numeric_limits<size_t>::max();
      for (NSUInteger channelIndex = 0; channelIndex < channels; ++channelIndex) {
        const AudioBuffer &buffer = audioBufferList->mBuffers[channelIndex];
        const int16_t *source = static_cast<const int16_t *>(buffer.mData);
        if (!source) {
          CFRelease(blockBuffer);
          return;
        }
        const size_t channelFrames = buffer.mDataByteSize / bytesPerSample;
        framesAvailable = std::min(framesAvailable, channelFrames);
        for (size_t frameIndex = 0; frameIndex < channelFrames; ++frameIndex) {
          const size_t destIndex = frameIndex * channels + channelIndex;
          if (destIndex >= samplesExpected) {
            break;
          }
          dest[destIndex] = source[frameIndex];
        }
      }
      if (framesAvailable == std::numeric_limits<size_t>::max()) {
        framesAvailable = 0;
      }
    } else {
      for (int bufferIndex = 0; bufferIndex < buffers; ++bufferIndex) {
        const AudioBuffer &buffer = audioBufferList->mBuffers[bufferIndex];
        const size_t samplesInBuffer = buffer.mDataByteSize / bytesPerSample;
        const size_t samplesToCopy = std::min(samplesInBuffer, samplesExpected - writtenSamples);
        if (samplesToCopy == 0) {
          continue;
        }
        const int16_t *source = static_cast<const int16_t *>(buffer.mData);
        if (!source) {
          CFRelease(blockBuffer);
          return;
        }
        memcpy(dest + writtenSamples, source, samplesToCopy * bytesPerSample);
        writtenSamples += samplesToCopy;
        if (writtenSamples >= samplesExpected) {
          break;
        }
      }
      framesAvailable = writtenSamples / channels;
    }

    framesAvailable = std::min(framesAvailable, frames);
    interleavedSamples = dest;
  }

  CFRelease(blockBuffer);

  if (!interleavedSamples || framesAvailable == 0) {
    return;
  }

  if (!_chunker) {
    _chunker = [[RTC_OBJC_TYPE(RTCAudioPCMChunker) alloc] initWithSampleRate:sampleRate
                                                                     channels:channels];
  } else if ([_chunker sampleRate] != sampleRate || [_chunker channels] != channels) {
    [_chunker resetWithSampleRate:sampleRate channels:channels];
  }

  __weak __typeof(self) weakSelf = self;
  [_chunker consumePCM:interleavedSamples
                frames:framesAvailable
           sampleRate:sampleRate
             channels:channels
          timestampNs:timestampNs
               handler:^(RTC_OBJC_TYPE(RTCAudioFrame) *frame) {
                 __strong __typeof(weakSelf) strongSelf = weakSelf;
                 if (!strongSelf || !strongSelf.isRunning) {
                   return;
                 }
                 id<RTC_OBJC_TYPE(RTCAudioCapturerDelegate)> delegate = strongSelf.delegate;
                 if (!delegate) {
                   return;
                 }
                 [delegate capturer:strongSelf didCaptureAudioFrame:frame];
               }];
}

@end
