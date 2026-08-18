/*
 * Copyright 2026 Stream
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "RTCEncryptionManager.h"

#import "RTCPeerConnectionFactory+Private.h"
#import "RTCRtpReceiver+Private.h"
#import "RTCRtpSender+Private.h"

#import <os/lock.h>

#import "helpers/NSString+StdString.h"

#include <optional>
#include <string>

#include "api/array_view.h"
#include "api/crypto/default_encryption_manager.h"
#include "api/make_ref_counted.h"
#include "api/media_types.h"
#include "api/rtp_receiver_interface.h"
#include "api/rtp_sender_interface.h"
#include "api/scoped_refptr.h"

NSErrorDomain const RTCEncryptionManagerErrorDomain =
    @"org.webrtc.RTCEncryptionManager";

namespace {

RTC_OBJC_TYPE(RTCE2eeEventType)
ObjCType(webrtc::DefaultEncryptionManager::E2eeEventType type) {
  return static_cast<RTC_OBJC_TYPE(RTCE2eeEventType)>(type);
}

webrtc::DefaultEncryptionManager::Cipher NativeCipher(
    RTC_OBJC_TYPE(RTCEncryptionAlgorithm) algorithm) {
  return algorithm == RTC_OBJC_TYPE(RTCEncryptionAlgorithmAes256Gcm)
             ? webrtc::DefaultEncryptionManager::Cipher::kAes256Gcm
             : webrtc::DefaultEncryptionManager::Cipher::kAes128Gcm;
}

bool TrackTypeOk(RTC_OBJC_TYPE(RTCEncryptionTrackType) trackType) {
  return trackType >= RTC_OBJC_TYPE(RTCEncryptionTrackTypeAudio) &&
         trackType <= RTC_OBJC_TYPE(RTCEncryptionTrackTypeScreenshareAudio);
}

webrtc::FrameCryptorTransformer::TrackType NativeTrackType(
    RTC_OBJC_TYPE(RTCEncryptionTrackType) trackType) {
  return static_cast<webrtc::FrameCryptorTransformer::TrackType>(trackType);
}

webrtc::FrameCryptorTransformer::TrackType DefaultTrackType(
    webrtc::MediaType media) {
  return media == webrtc::MediaType::AUDIO
             ? webrtc::FrameCryptorTransformer::TrackType::kAudio
             : webrtc::FrameCryptorTransformer::TrackType::kVideo;
}

bool ResolveTrackType(NSNumber *trackType,
                      webrtc::MediaType media,
                      webrtc::FrameCryptorTransformer::TrackType *out) {
  // Omitted → audio vs video from the RTP sender/receiver. Screenshare must
  // still be passed in so its replay window is not mixed with camera video.
  if (trackType) {
    auto value = static_cast<RTC_OBJC_TYPE(RTCEncryptionTrackType)>(
        trackType.intValue);
    if (!TrackTypeOk(value)) {
      return false;
    }
    *out = NativeTrackType(value);
    return true;
  }
  *out = DefaultTrackType(media);
  return true;
}

std::optional<std::string> NativeCodec(NSString *codec) {
  // nil = no pin (read codec from the frame). Empty string is also no pin
  // once it reaches CreateEncryptor.
  if (!codec) {
    return std::nullopt;
  }
  return [codec stdString];
}

BOOL Fail(NSError **error,
          RTC_OBJC_TYPE(RTCEncryptionManagerErrorCode) code,
          NSString *message) {
  if (error) {
    *error = [NSError errorWithDomain:RTCEncryptionManagerErrorDomain
                                 code:code
                             userInfo:@{NSLocalizedDescriptionKey : message}];
  }
  return NO;
}

}  // namespace

@interface RTC_OBJC_TYPE (RTCEncryptionUserKey)
()
    - (instancetype)initWithUserId
    : (NSString *)userId keyIndex : (int)keyIndex fingerprint
    : (NSString *)fingerprint;
@end

@implementation RTC_OBJC_TYPE (RTCEncryptionUserKey)
@synthesize userId = _userId;
@synthesize keyIndex = _keyIndex;
@synthesize fingerprint = _fingerprint;

- (instancetype)initWithUserId:(NSString *)userId
                      keyIndex:(int)keyIndex
                   fingerprint:(NSString *)fingerprint {
  self = [super init];
  if (self) {
    _userId = [userId copy];
    _keyIndex = keyIndex;
    _fingerprint = [fingerprint copy];
  }
  return self;
}
@end

@interface RTC_OBJC_TYPE (RTCEncryptionSharedKey)
()
    - (instancetype)initWithKeyIndex
    : (int)keyIndex fingerprint : (NSString *)fingerprint isActive
    : (BOOL)isActive;
@end

@implementation RTC_OBJC_TYPE (RTCEncryptionSharedKey)
@synthesize keyIndex = _keyIndex;
@synthesize fingerprint = _fingerprint;
@synthesize isActive = _isActive;

- (instancetype)initWithKeyIndex:(int)keyIndex
                     fingerprint:(NSString *)fingerprint
                        isActive:(BOOL)isActive {
  self = [super init];
  if (self) {
    _keyIndex = keyIndex;
    _fingerprint = [fingerprint copy];
    _isActive = isActive;
  }
  return self;
}
@end

@interface RTC_OBJC_TYPE (RTCEncryptionKeyState)
()
    - (instancetype)initWithPerUserKeys
    : (NSArray *)perUserKeys sharedKeys : (NSArray *)sharedKeys;
@end

@implementation RTC_OBJC_TYPE (RTCEncryptionKeyState)
@synthesize perUserKeys = _perUserKeys;
@synthesize sharedKeys = _sharedKeys;

- (instancetype)initWithPerUserKeys:(NSArray *)perUserKeys
                         sharedKeys:(NSArray *)sharedKeys {
  self = [super init];
  if (self) {
    _perUserKeys = [perUserKeys copy];
    _sharedKeys = [sharedKeys copy];
  }
  return self;
}
@end

@interface RTC_OBJC_TYPE (RTCEncryptionTrackPerf)
()
    - (instancetype)initWithUserId
    : (NSString *)userId trackType
    : (RTC_OBJC_TYPE(RTCEncryptionTrackType))trackType codec
    : (nullable NSString *)codec fps : (double)fps maxCryptoMs
    : (double)maxCryptoMs;
@end

@implementation RTC_OBJC_TYPE (RTCEncryptionTrackPerf)
@synthesize userId = _userId;
@synthesize trackType = _trackType;
@synthesize codec = _codec;
@synthesize fps = _fps;
@synthesize maxCryptoMs = _maxCryptoMs;

- (instancetype)initWithUserId:(NSString *)userId
                     trackType:(RTC_OBJC_TYPE(RTCEncryptionTrackType))trackType
                         codec:(nullable NSString *)codec
                           fps:(double)fps
                   maxCryptoMs:(double)maxCryptoMs {
  self = [super init];
  if (self) {
    _userId = [userId copy];
    _trackType = trackType;
    _codec = [codec copy];
    _fps = fps;
    _maxCryptoMs = maxCryptoMs;
  }
  return self;
}
@end

@interface RTC_OBJC_TYPE (RTCE2eeEvent)
()
@end

@implementation RTC_OBJC_TYPE (RTCE2eeEvent)
@synthesize type = _type;
@synthesize name = _name;
@synthesize userId = _userId;
@synthesize trackType = _trackType;
@synthesize keyIndex = _keyIndex;
@synthesize version = _version;
@synthesize reason = _reason;
@synthesize keyState = _keyState;
@synthesize encode = _encode;
@synthesize decode = _decode;

- (instancetype)initWithNative:
    (const webrtc::DefaultEncryptionManager::E2eeEvent &)ev {
  self = [super init];
  if (self) {
    _type = ObjCType(ev.type);
    _name = [NSString stringWithUTF8String:ev.Name()];
    _userId = [NSString stringForStdString:ev.participant_id];
    if (ev.track_type) {
      _trackType = @(static_cast<int>(*ev.track_type));
    }
    if (ev.key_index) {
      _keyIndex = @(*ev.key_index);
    }
    if (ev.version) {
      _version = @(*ev.version);
    }
    if (!ev.reason.empty()) {
      _reason = [NSString stringForStdString:ev.reason];
    }
    if (ev.type ==
        webrtc::DefaultEncryptionManager::E2eeEventType::kKeyState) {
      NSMutableArray *perUser = [NSMutableArray array];
      NSMutableArray *shared = [NSMutableArray array];
      for (const auto &fp : ev.key_state) {
        NSString *hex = [NSString stringForStdString:fp.Hex()];
        if (fp.shared) {
          [shared addObject:[[RTC_OBJC_TYPE(RTCEncryptionSharedKey) alloc]
                                initWithKeyIndex:fp.key_index
                                     fingerprint:hex
                                        isActive:fp.active_shared]];
        } else {
          [perUser addObject:[[RTC_OBJC_TYPE(RTCEncryptionUserKey) alloc]
                                 initWithUserId:[NSString
                                                    stringForStdString:fp
                                                                   .participant_id]
                                       keyIndex:fp.key_index
                                    fingerprint:hex]];
        }
      }
      _keyState = [[RTC_OBJC_TYPE(RTCEncryptionKeyState) alloc]
          initWithPerUserKeys:perUser
                   sharedKeys:shared];
    }
    if (ev.type ==
        webrtc::DefaultEncryptionManager::E2eeEventType::kPerfReport) {
      NSMutableArray *encode = [NSMutableArray array];
      NSMutableArray *decode = [NSMutableArray array];
      for (const auto &p : ev.encode_perf) {
        [encode addObject:[[RTC_OBJC_TYPE(RTCEncryptionTrackPerf) alloc]
                              initWithUserId:[NSString
                                                 stringForStdString:p
                                                                .participant_id]
                                   trackType:
                                       static_cast<RTC_OBJC_TYPE(
                                           RTCEncryptionTrackType)>(p.track_type)
                                       codec:p.codec.empty()
                                                 ? nil
                                                 : [NSString
                                                       stringForStdString:p.codec]
                                         fps:p.fps
                                 maxCryptoMs:p.max_crypto_ms]];
      }
      for (const auto &p : ev.decode_perf) {
        [decode addObject:[[RTC_OBJC_TYPE(RTCEncryptionTrackPerf) alloc]
                              initWithUserId:[NSString
                                                 stringForStdString:p
                                                                .participant_id]
                                   trackType:
                                       static_cast<RTC_OBJC_TYPE(
                                           RTCEncryptionTrackType)>(p.track_type)
                                       codec:nil
                                         fps:p.fps
                                 maxCryptoMs:p.max_crypto_ms]];
      }
      _encode = encode;
      _decode = decode;
    }
  }
  return self;
}
@end

namespace webrtc {

class RTCEncryptionManagerObserver : public DefaultEncryptionManager::Observer {
 public:
  explicit RTCEncryptionManagerObserver(
      RTC_OBJC_TYPE(RTCEncryptionManager) * manager)
      : manager_(manager) {}

  void OnE2eeEvent(const DefaultEncryptionManager::E2eeEvent &event) override {
    @autoreleasepool {
      RTC_OBJC_TYPE(RTCEncryptionManager) *manager = manager_;
      id<RTC_OBJC_TYPE(RTCEncryptionManagerDelegate)> delegate =
          manager.delegate;
      if (!delegate) {
        return;
      }
      RTC_OBJC_TYPE(RTCE2eeEvent) *objc =
          [[RTC_OBJC_TYPE(RTCE2eeEvent) alloc] initWithNative:event];
      // Crypto runs off the main thread; UI delegates expect main-queue
      // callbacks. create() has no factory, so we cannot use signalingThread.
      dispatch_async(dispatch_get_main_queue(), ^{
        [delegate encryptionManager:manager didReceiveEvent:objc];
      });
    }
  }

 private:
  __weak RTC_OBJC_TYPE(RTCEncryptionManager) * manager_;
};

}  // namespace webrtc

@implementation RTC_OBJC_TYPE (RTCEncryptionManager) {
  webrtc::scoped_refptr<webrtc::DefaultEncryptionManager> _native;
  webrtc::scoped_refptr<webrtc::RTCEncryptionManagerObserver> _observer;
  os_unfair_lock _lock;
}

@synthesize userId = _userId;
@synthesize algorithm = _algorithm;
@synthesize delegate = _delegate;

+ (BOOL)isSupported {
  // Browsers gate on Encoded Transform + secure context. Native always has
  // the insertable-transform path, so this is always YES.
  return YES;
}

+ (nullable instancetype)createWithUserId:(NSString *)userId
                                    error:(NSError **)error {
  return [self createWithUserId:userId
                      algorithm:RTC_OBJC_TYPE(RTCEncryptionAlgorithmAes128Gcm)
                          error:error];
}

+ (nullable instancetype)createWithUserId:(NSString *)userId
                                algorithm:
                                    (RTC_OBJC_TYPE(RTCEncryptionAlgorithm))
                                        algorithm
                                    error:(NSError **)error {
  RTC_OBJC_TYPE(RTCEncryptionManager) *manager =
      [[self alloc] initWithUserId:userId algorithm:algorithm];
  if (!manager) {
    Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed),
         @"userId must be non-empty");
    return nil;
  }
  return manager;
}

- (nullable instancetype)initWithUserId:(NSString *)userId {
  return [self initWithUserId:userId
                    algorithm:RTC_OBJC_TYPE(RTCEncryptionAlgorithmAes128Gcm)];
}

- (nullable instancetype)initWithUserId:(NSString *)userId
                              algorithm:
                                  (RTC_OBJC_TYPE(RTCEncryptionAlgorithm))
                                      algorithm {
  self = [super init];
  if (self) {
    if (userId.length == 0) {
      return nil;
    }
    _lock = OS_UNFAIR_LOCK_INIT;
    _userId = [userId copy];
    _algorithm = algorithm;
    _native = webrtc::make_ref_counted<webrtc::DefaultEncryptionManager>(
        [userId stdString], NativeCipher(algorithm));
    _observer =
        webrtc::make_ref_counted<webrtc::RTCEncryptionManagerObserver>(self);
    _native->SetObserver(_observer);
  }
  return self;
}

- (void)dealloc {
  [self dispose];
}

- (BOOL)isDisposed {
  os_unfair_lock_lock(&_lock);
  BOOL disposed = _native == nullptr || _native->disposed();
  os_unfair_lock_unlock(&_lock);
  return disposed;
}

- (BOOL)setKey:(NSString *)userId
      keyIndex:(int)keyIndex
        rawKey:(NSData *)rawKey
         error:(NSError **)error {
  if (![self prepareKeyIndex:keyIndex rawKey:rawKey error:error]) {
    return NO;
  }
  os_unfair_lock_lock(&_lock);
  BOOL ok = _native != nullptr &&
            _native->SetKey([userId stdString], keyIndex,
                            webrtc::ArrayView<const uint8_t>(
                                static_cast<const uint8_t *>(rawKey.bytes),
                                rawKey.length));
  os_unfair_lock_unlock(&_lock);
  return ok ? YES
            : Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed),
                   @"setKey failed");
}

- (BOOL)setSharedKey:(int)keyIndex
              rawKey:(NSData *)rawKey
               error:(NSError **)error {
  if (![self prepareKeyIndex:keyIndex rawKey:rawKey error:error]) {
    return NO;
  }
  os_unfair_lock_lock(&_lock);
  BOOL ok = _native != nullptr &&
            _native->SetSharedKey(
                keyIndex, webrtc::ArrayView<const uint8_t>(
                              static_cast<const uint8_t *>(rawKey.bytes),
                              rawKey.length));
  os_unfair_lock_unlock(&_lock);
  return ok ? YES
            : Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed),
                   @"setSharedKey failed");
}

- (BOOL)removeKey:(NSString *)userId
         keyIndex:(int)keyIndex
            error:(NSError **)error {
  if (![self prepareKeyIndex:keyIndex rawKey:nil error:error]) {
    return NO;
  }
  os_unfair_lock_lock(&_lock);
  if (_native != nullptr) {
    _native->RemoveKey([userId stdString], keyIndex);
  }
  os_unfair_lock_unlock(&_lock);
  return YES;
}

- (BOOL)removeAllKeys:(NSString *)userId error:(NSError **)error {
  if (![self prepareUsable:error]) {
    return NO;
  }
  os_unfair_lock_lock(&_lock);
  if (_native != nullptr) {
    _native->RemoveAllKeys([userId stdString]);
  }
  os_unfair_lock_unlock(&_lock);
  return YES;
}

- (BOOL)removeSharedKey:(int)keyIndex error:(NSError **)error {
  if (![self prepareKeyIndex:keyIndex rawKey:nil error:error]) {
    return NO;
  }
  os_unfair_lock_lock(&_lock);
  if (_native != nullptr) {
    _native->RemoveSharedKey(keyIndex);
  }
  os_unfair_lock_unlock(&_lock);
  return YES;
}

- (BOOL)encrypt:(RTC_OBJC_TYPE(RTCRtpSender) *)sender
          error:(NSError **)error {
  return [self encrypt:sender codec:nil trackType:nil error:error];
}

- (BOOL)encrypt:(RTC_OBJC_TYPE(RTCRtpSender) *)sender
          codec:(nullable NSString *)codec
      trackType:(nullable NSNumber *)trackType
          error:(NSError **)error {
  if (![self prepareUsable:error]) {
    return NO;
  }
  if (sender.nativeRtpSender == nullptr || sender.factory == nil) {
    return Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed),
                @"encrypt requires a sender");
  }
  // Signaling thread comes from the sender's factory, not from create().
  // SetFrameTransformer is not thread-safe and must run there.
  webrtc::FrameCryptorTransformer::TrackType nativeTrack;
  if (!ResolveTrackType(trackType, sender.nativeRtpSender->media_type(),
                        &nativeTrack)) {
    return Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed),
                @"invalid trackType");
  }
  os_unfair_lock_lock(&_lock);
  webrtc::scoped_refptr<webrtc::DefaultEncryptionManager> native = _native;
  os_unfair_lock_unlock(&_lock);
  if (!native) {
    return Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeDisposed),
                @"EncryptionManager is disposed");
  }
  webrtc::scoped_refptr<webrtc::FrameCryptorTransformer> cryptor =
      native->CreateEncryptor(sender.factory.signalingThread, nativeTrack,
                              NativeCodec(codec));
  if (!cryptor) {
    return Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed),
                @"failed to attach encrypt transform");
  }
  webrtc::scoped_refptr<webrtc::RtpSenderInterface> nativeSender =
      sender.nativeRtpSender;
  // Must hop: RtpSenderInterface::SetFrameTransformer is signaling-thread only.
  sender.factory.signalingThread->BlockingCall(
      [nativeSender, cryptor] { nativeSender->SetFrameTransformer(cryptor); });
  return YES;
}

- (BOOL)decrypt:(RTC_OBJC_TYPE(RTCRtpReceiver) *)receiver
         userId:(NSString *)userId
          error:(NSError **)error {
  return [self decrypt:receiver userId:userId trackType:nil error:error];
}

- (BOOL)decrypt:(RTC_OBJC_TYPE(RTCRtpReceiver) *)receiver
         userId:(NSString *)userId
      trackType:(nullable NSNumber *)trackType
          error:(NSError **)error {
  if (![self prepareUsable:error]) {
    return NO;
  }
  if (userId.length == 0 || receiver.nativeRtpReceiver == nullptr ||
      receiver.factory == nil) {
    return Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed),
                @"decrypt requires a receiver and userId");
  }
  // Same as encrypt: factory (and its signaling thread) come from the receiver.
  webrtc::FrameCryptorTransformer::TrackType nativeTrack;
  if (!ResolveTrackType(trackType, receiver.nativeRtpReceiver->media_type(),
                        &nativeTrack)) {
    return Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed),
                @"invalid trackType");
  }
  os_unfair_lock_lock(&_lock);
  webrtc::scoped_refptr<webrtc::DefaultEncryptionManager> native = _native;
  os_unfair_lock_unlock(&_lock);
  if (!native) {
    return Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeDisposed),
                @"EncryptionManager is disposed");
  }
  webrtc::scoped_refptr<webrtc::FrameCryptorTransformer> cryptor =
      native->CreateDecryptor(receiver.factory.signalingThread,
                              [userId stdString], nativeTrack);
  if (!cryptor) {
    return Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed),
                @"failed to attach decrypt transform");
  }
  webrtc::scoped_refptr<webrtc::RtpReceiverInterface> nativeReceiver =
      receiver.nativeRtpReceiver;
  // Same hop as encrypt: SetFrameTransformer is signaling-thread only.
  receiver.factory.signalingThread->BlockingCall([nativeReceiver, cryptor] {
    nativeReceiver->SetFrameTransformer(cryptor);
  });
  return YES;
}

- (BOOL)enablePerformanceReporting:(BOOL)enabled error:(NSError **)error {
  if (![self prepareUsable:error]) {
    return NO;
  }
  os_unfair_lock_lock(&_lock);
  BOOL ok = _native != nullptr &&
            _native->EnablePerformanceReporting(enabled ? true : false);
  os_unfair_lock_unlock(&_lock);
  return ok ? YES
            : Fail(error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed),
                   @"enablePerformanceReporting failed");
}

- (BOOL)requestKeyState:(NSError **)error {
  if (![self prepareUsable:error]) {
    return NO;
  }
  os_unfair_lock_lock(&_lock);
  if (_native != nullptr) {
    _native->RequestKeyState();
  }
  os_unfair_lock_unlock(&_lock);
  return YES;
}

- (void)dispose {
  os_unfair_lock_lock(&_lock);
  if (_native != nullptr) {
    _native->SetObserver(nullptr);
    _native->Dispose();
    _native = nullptr;
  }
  _observer = nullptr;
  os_unfair_lock_unlock(&_lock);
}

- (BOOL)prepareUsable:(NSError **)error {
  os_unfair_lock_lock(&_lock);
  BOOL disposed = _native == nullptr || _native->disposed();
  os_unfair_lock_unlock(&_lock);
  if (disposed) {
    return Fail(error,
                RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeDisposed),
                @"EncryptionManager is disposed");
  }
  return YES;
}

- (BOOL)prepareKeyIndex:(int)keyIndex
                 rawKey:(nullable NSData *)rawKey
                  error:(NSError **)error {
  if (![self prepareUsable:error]) {
    return NO;
  }
  if (keyIndex < 0 || keyIndex > 255) {
    return Fail(
        error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeInvalidKeyIndex),
        [NSString stringWithFormat:
                      @"keyIndex must be an integer between 0 and 255, got %d",
                      keyIndex]);
  }
  if (rawKey) {
    NSUInteger expected =
        _algorithm == RTC_OBJC_TYPE(RTCEncryptionAlgorithmAes256Gcm) ? 32 : 16;
    if (rawKey.length != expected) {
      BOOL aes256 =
          _algorithm == RTC_OBJC_TYPE(RTCEncryptionAlgorithmAes256Gcm);
      return Fail(
          error, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeInvalidKeyLength),
          [NSString stringWithFormat:@"Key must be exactly %lu bytes (%@)",
                                     (unsigned long)expected,
                                     aes256 ? @"AES-256" : @"AES-128"]);
    }
  }
  return YES;
}

@end
