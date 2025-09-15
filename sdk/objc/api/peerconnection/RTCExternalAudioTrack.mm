// Objective-C++ implementation
#import "RTCExternalAudioTrack.h"
#import "RTCRtpSender+Private.h"
#import "RTCPeerConnectionFactory.h"
#import "RTCAudioSource.h"
#import "RTCAudioTrack+Private.h"
#import <CoreMedia/CoreMedia.h>

#include <vector>
#include "rtc_base/time_utils.h"

#include "media/base/external_audio_source.h"
#include "pc/rtp_sender.h"

@implementation RTC_OBJC_TYPE (RTCExternalAudioTrack) {
  std::unique_ptr<webrtc::ExternalAudioSource> _nativeSource;
  BOOL _attached;
  // Buffering for 10 ms chunking.
  std::vector<int16_t> _accum;
  int _chunkFrames;
  int _sampleRate;
  int _channels;
}

- (instancetype)initWithFactory:(RTC_OBJC_TYPE(RTCPeerConnectionFactory) *)factory
                         trackId:(NSString *)trackId {
  // Create a regular audio source (unused for PCM injection), then init via
  // the public RTCAudioTrack initializer for compatibility.
  RTC_OBJC_TYPE(RTCAudioSource) *audioSource = [factory audioSourceWithConstraints:nil];
  self = [super initWithFactory:factory source:audioSource trackId:trackId];
  if (self) {
    _nativeSource = std::make_unique<webrtc::ExternalAudioSource>();
    _attached = NO;
    _sampleRate = 48000;
    _channels = 1;
    _chunkFrames = _sampleRate / 100;
    _accum.reserve(_chunkFrames * _channels * 2);
  }
  return self;
}

- (BOOL)attachToSender:(RTC_OBJC_TYPE(RTCRtpSender) *)sender {
  if (!sender) return NO;
  BOOL ok = webrtc::AttachExternalAudioSourceToSender(sender.nativeRtpSender.get(), _nativeSource.get());
  _attached = ok;
  return ok;
}

- (void)setDefaultSampleRate:(int)sampleRate channels:(int)channels {
  if (sampleRate <= 0 || channels <= 0) return;
  _sampleRate = sampleRate;
  _channels = channels;
  _chunkFrames = _sampleRate / 100;
  _accum.clear();
}

- (void)pushPCM:(const int16_t *)samples frames:(size_t)frames {
  int64_t now_ms = webrtc::TimeMillis();
  [self pushPCM:samples
          frames:frames
      sampleRate:_sampleRate
        channels:_channels
     captureTimeNs:now_ms * 1000000];
}

- (void)pushPCM:(const int16_t *)samples
         frames:(size_t)frames
     sampleRate:(int)sampleRate
       channels:(int)channels
  captureTimeNs:(int64_t)captureTimeNs {
  if (!_attached) {
    // Not attached yet: do nothing to avoid unbounded buffering.
    return;
  }
  if (sampleRate != _sampleRate || channels != _channels) {
    _sampleRate = sampleRate;
    _channels = channels;
    _chunkFrames = _sampleRate / 100;
    _accum.clear();
  }
  size_t total = frames * channels;
  _accum.insert(_accum.end(), samples, samples + total);
  const size_t chunkSamples = static_cast<size_t>(_chunkFrames) * _channels;
  while (_accum.size() >= chunkSamples) {
    // ExternalAudioSource expects timestamp in milliseconds.
    _nativeSource->Push(_accum.data(), _chunkFrames, _sampleRate, _channels,
                        captureTimeNs / 1000000);
    // Erase consumed samples.
    _accum.erase(_accum.begin(), _accum.begin() + chunkSamples);
  }
}

- (void)pushPCM:(const int16_t *)samples
         frames:(size_t)frames
     sampleRate:(int)sampleRate
       channels:(int)channels {
  int64_t now_ms = webrtc::TimeMillis();
  [self pushPCM:samples
          frames:frames
      sampleRate:sampleRate
        channels:channels
     captureTimeNs:now_ms * 1000000];
}

- (void)pushCMSampleBuffer:(CMSampleBufferRef)sb {
  if (!_attached || sb == NULL) return;

  // Extract format description and stream basic description.
  CMAudioFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
  const AudioStreamBasicDescription *asbd =
      CMAudioFormatDescriptionGetStreamBasicDescription(fmt);
  if (!asbd) return;

  // Only linear PCM is supported here.
  if (asbd->mFormatID != kAudioFormatLinearPCM) return;

  const bool isFloat = (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
  const bool nonInterleaved =
      (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
  const int inChannels = static_cast<int>(asbd->mChannelsPerFrame);
  const int frames = static_cast<int>(CMSampleBufferGetNumSamples(sb));
  if (inChannels <= 0 || frames <= 0) return;

  // Map audio buffer list.
  const size_t ablSize = sizeof(AudioBufferList) +
                         (std::max(1, inChannels) - 1) * sizeof(AudioBuffer);
  AudioBufferList *abl = static_cast<AudioBufferList *>(malloc(ablSize));
  CMBlockBufferRef blockBuf = NULL;
  OSStatus st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sb, NULL, abl, ablSize, NULL, NULL,
      kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuf);
  if (st != noErr) {
    free(abl);
    return;
  }

  // Downmix to mono Int16.
  std::vector<int16_t> mono(frames);

  auto clampFloatToInt16 = [](float x) -> int16_t {
    if (x > 1.0f) x = 1.0f;
    if (x < -1.0f) x = -1.0f;
    return static_cast<int16_t>(lrintf(x * static_cast<float>(INT16_MAX)));
  };

  if (isFloat) {
    if (nonInterleaved) {
      // abl->mNumberBuffers == inChannels, each buffer one channel.
      float **ch = reinterpret_cast<float **>(alloca(sizeof(float *) * inChannels));
      for (int c = 0; c < inChannels; ++c) {
        ch[c] = static_cast<float *>(abl->mBuffers[c].mData);
      }
      for (int i = 0; i < frames; ++i) {
        float sum = 0.0f;
        for (int c = 0; c < inChannels; ++c) sum += ch[c][i];
        mono[i] = clampFloatToInt16(sum / static_cast<float>(inChannels));
      }
    } else {
      // Interleaved float32.
      const float *data = static_cast<const float *>(abl->mBuffers[0].mData);
      for (int i = 0; i < frames; ++i) {
        float sum = 0.0f;
        for (int c = 0; c < inChannels; ++c) sum += data[i * inChannels + c];
        mono[i] = clampFloatToInt16(sum / static_cast<float>(inChannels));
      }
    }
  } else {
    // Int16 path.
    if (nonInterleaved) {
      int16_t **ch = reinterpret_cast<int16_t **>(alloca(sizeof(int16_t *) * inChannels));
      for (int c = 0; c < inChannels; ++c) {
        ch[c] = static_cast<int16_t *>(abl->mBuffers[c].mData);
      }
      for (int i = 0; i < frames; ++i) {
        int sum = 0;
        for (int c = 0; c < inChannels; ++c) sum += ch[c][i];
        mono[i] = static_cast<int16_t>(sum / inChannels);
      }
    } else {
      const int16_t *data = static_cast<const int16_t *>(abl->mBuffers[0].mData);
      for (int i = 0; i < frames; ++i) {
        int sum = 0;
        for (int c = 0; c < inChannels; ++c) sum += data[i * inChannels + c];
        mono[i] = static_cast<int16_t>(sum / inChannels);
      }
    }
  }

  // Compute timestamp in nanoseconds from sample buffer PTS, if available.
  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
  int64_t ptsNs = 0;
  if (CMTIME_IS_VALID(pts) && pts.timescale != 0) {
    ptsNs = (static_cast<int64_t>(pts.value) * 1000000000LL) /
            static_cast<int64_t>(pts.timescale);
  }

  // Push using explicit format; we downmixed to mono.
  [self pushPCM:mono.data()
          frames:static_cast<size_t>(frames)
      sampleRate:static_cast<int>(asbd->mSampleRate)
        channels:1
     captureTimeNs:ptsNs];

  // Cleanup
  if (blockBuf) CFRelease(blockBuf);
  free(abl);
}

@end
