// Experimental external audio track that injects audio buffers.
#import "RTCAudioTrack.h"
#import "RTCPeerConnectionFactory.h"
#import "RTCRtpSender.h"
#import <CoreMedia/CoreMedia.h>

NS_ASSUME_NONNULL_BEGIN

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE (RTCExternalAudioTrack) : RTC_OBJC_TYPE(RTCAudioTrack)

// Designated initializer.
// - Creates a native external audio source internally.
// - Initializes as a regular audio track so it can be added via addTrack.
// - The internal source is not attached until attachToSender: is called.

- (instancetype)initWithFactory:(RTC_OBJC_TYPE(RTCPeerConnectionFactory) *)factory
                         trackId:(NSString *)trackId;

// Attach this track's internal source to a sender (after addTrack).
- (BOOL)attachToSender:(RTC_OBJC_TYPE(RTCRtpSender) *)sender;

// Push interleaved 16-bit PCM (Int16).
// - Any frame length is accepted.
// - Internally buffered and emitted in 10 ms chunks based on sampleRate/channels.
// - If called before attachToSender:, samples are ignored (no-op), to avoid
//   unbounded buffering. Callers should attach first.
// - Timestamp is optional; if you want, call the variant without
//   captureTimeNs and the track will use a monotonic clock internally.
- (void)pushPCM:(const int16_t *)samples
         frames:(size_t)frames
     sampleRate:(int)sampleRate
       channels:(int)channels
  captureTimeNs:(int64_t)captureTimeNs;

// Convenience: use preconfigured defaults for sample rate and channels.
- (void)pushPCM:(const int16_t *)samples frames:(size_t)frames;

// Convenience: provide sampleRate/channels explicitly but omit timestamp.
- (void)pushPCM:(const int16_t *)samples
         frames:(size_t)frames
     sampleRate:(int)sampleRate
       channels:(int)channels;

// Push a CMSampleBuffer containing linear PCM audio. Supports Float32 or
// Int16, interleaved or non-interleaved, any channel count. Downmixes to mono
// Int16 internally and uses the buffer's presentation timestamp when present.
- (void)pushCMSampleBuffer:(CMSampleBufferRef)sampleBuffer;

// Configure defaults for sample rate and channels used by the convenience
// push method. Defaults to 48000 Hz, mono.
- (void)setDefaultSampleRate:(int)sampleRate channels:(int)channels;

@end

NS_ASSUME_NONNULL_END
