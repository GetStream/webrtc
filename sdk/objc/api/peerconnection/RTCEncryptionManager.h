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

#import <Foundation/Foundation.h>

#import "RTCMacros.h"

NS_ASSUME_NONNULL_BEGIN

@class RTC_OBJC_TYPE(RTCPeerConnectionFactory);
@class RTC_OBJC_TYPE(RTCRtpSender);
@class RTC_OBJC_TYPE(RTCRtpReceiver);
@class RTC_OBJC_TYPE(RTCEncryptionManager);
@class RTC_OBJC_TYPE(RTCE2eeEvent);
@class RTC_OBJC_TYPE(RTCEncryptionKeyState);
@class RTC_OBJC_TYPE(RTCEncryptionUserKey);
@class RTC_OBJC_TYPE(RTCEncryptionSharedKey);
@class RTC_OBJC_TYPE(RTCEncryptionTrackPerf);

/** AES-GCM key size. Default is AES-128. */
typedef NS_ENUM(NSInteger, RTC_OBJC_TYPE(RTCEncryptionAlgorithm)) {
  RTC_OBJC_TYPE(RTCEncryptionAlgorithmAes128Gcm) = 0,
  RTC_OBJC_TYPE(RTCEncryptionAlgorithmAes256Gcm) = 1,
};

/**
 * JS worker `trackType` (protobuf TrackType names). Optional on encrypt/
 * decrypt: omitted values default to audio vs video from the RTP sender
 * or receiver. Pass screenshare explicitly so replay stays per track.
 */
typedef NS_ENUM(NSInteger, RTC_OBJC_TYPE(RTCEncryptionTrackType)) {
  RTC_OBJC_TYPE(RTCEncryptionTrackTypeAudio) = 0,
  RTC_OBJC_TYPE(RTCEncryptionTrackTypeVideo) = 1,
  RTC_OBJC_TYPE(RTCEncryptionTrackTypeScreenshare) = 2,
  RTC_OBJC_TYPE(RTCEncryptionTrackTypeScreenshareAudio) = 3,
};

/** Event names such as `e2ee.missing_key`. */
typedef NS_ENUM(NSInteger, RTC_OBJC_TYPE(RTCE2eeEventType)) {
  RTC_OBJC_TYPE(RTCE2eeEventTypeDecryptionFailed) = 0,
  RTC_OBJC_TYPE(RTCE2eeEventTypeDecryptionResumed) = 1,
  RTC_OBJC_TYPE(RTCE2eeEventTypeDecryptionStalled) = 2,
  RTC_OBJC_TYPE(RTCE2eeEventTypeEncryptionFailed) = 3,
  RTC_OBJC_TYPE(RTCE2eeEventTypeMissingKey) = 4,
  RTC_OBJC_TYPE(RTCE2eeEventTypeUnencryptedFrame) = 5,
  RTC_OBJC_TYPE(RTCE2eeEventTypeUnsupportedVersion) = 6,
  RTC_OBJC_TYPE(RTCE2eeEventTypeKeyState) = 7,
  RTC_OBJC_TYPE(RTCE2eeEventTypePerfReport) = 8,
};

RTC_EXTERN NSErrorDomain const RTCEncryptionManagerErrorDomain;

typedef NS_ENUM(NSInteger, RTC_OBJC_TYPE(RTCEncryptionManagerErrorCode)) {
  RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeDisposed) = 1,
  RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeInvalidKeyIndex) = 2,
  RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeInvalidKeyLength) = 3,
  RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeFailed) = 4,
};

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE (RTCEncryptionUserKey) : NSObject
@property(nonatomic, readonly) NSString *userId;
@property(nonatomic, readonly) int keyIndex;
/** Hex of SHA-256(rawKey)[:8]. Never key material. */
@property(nonatomic, readonly) NSString *fingerprint;
@end

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE (RTCEncryptionSharedKey) : NSObject
@property(nonatomic, readonly) int keyIndex;
@property(nonatomic, readonly) NSString *fingerprint;
@property(nonatomic, readonly) BOOL isActive;
@end

/** JS `e2ee.key_state` payload. */
RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE (RTCEncryptionKeyState) : NSObject
@property(nonatomic, readonly)
    NSArray<RTC_OBJC_TYPE(RTCEncryptionUserKey) *> *perUserKeys;
@property(nonatomic, readonly)
    NSArray<RTC_OBJC_TYPE(RTCEncryptionSharedKey) *> *sharedKeys;
@end

/** One row of `e2ee.perf_report`. `codec` is set on encode samples only. */
RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE (RTCEncryptionTrackPerf) : NSObject
@property(nonatomic, readonly) NSString *userId;
@property(nonatomic, readonly) RTC_OBJC_TYPE(RTCEncryptionTrackType) trackType;
@property(nonatomic, readonly, nullable) NSString *codec;
@property(nonatomic, readonly) double fps;
@property(nonatomic, readonly) double maxCryptoMs;
@end

/** One `e2ee.*` event. Optional fields are nil when omitted. */
RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE (RTCE2eeEvent) : NSObject
@property(nonatomic, readonly) RTC_OBJC_TYPE(RTCE2eeEventType) type;
/** Event name, e.g. `e2ee.missing_key`. */
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *userId;
@property(nonatomic, readonly, nullable)
    NSNumber *trackType;  // RTCEncryptionTrackType
@property(nonatomic, readonly, nullable) NSNumber *keyIndex;
@property(nonatomic, readonly, nullable) NSNumber *version;
@property(nonatomic, readonly, nullable) NSString *reason;
@property(nonatomic, readonly, nullable)
    RTC_OBJC_TYPE(RTCEncryptionKeyState) * keyState;
@property(nonatomic, readonly, nullable)
    NSArray<RTC_OBJC_TYPE(RTCEncryptionTrackPerf) *> *encode;
@property(nonatomic, readonly, nullable)
    NSArray<RTC_OBJC_TYPE(RTCEncryptionTrackPerf) *> *decode;
@end

RTC_OBJC_EXPORT
@protocol RTC_OBJC_TYPE
(RTCEncryptionManagerDelegate)<NSObject>
    - (void)encryptionManager
    : (RTC_OBJC_TYPE(RTCEncryptionManager) *)manager
          didReceiveEvent:(RTC_OBJC_TYPE(RTCE2eeEvent) *)event;
@end

/**
 * Attach encrypt/decrypt transforms. `RTCEncryptionManager` is the default
 * AES-GCM implementation; a custom class can conform for a different scheme.
 * `codec` and `trackType` may be nil (read codec from the frame; default
 * track kind from the RTP sender/receiver).
 */
RTC_OBJC_EXPORT
@protocol RTC_OBJC_TYPE
(RTCE2EEManager)<NSObject>
    - (BOOL)encrypt : (RTC_OBJC_TYPE(RTCRtpSender) *)sender codec
    : (nullable NSString *)codec trackType : (nullable NSNumber *)trackType
                                        error : (NSError **)error;
- (BOOL)decrypt:(RTC_OBJC_TYPE(RTCRtpReceiver) *)receiver
         userId:(NSString *)userId
      trackType:(nullable NSNumber *)trackType
          error:(NSError **)error;
@end

/**
 * JS `EncryptionManager`: one object holds keys and attaches encrypt/decrypt
 * transforms. LiveKit `RTCFrameCryptor` + `RTCFrameCryptorKeyProvider` is a
 * different API and is unchanged.
 */
RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE (RTCEncryptionManager)
    : NSObject<RTC_OBJC_TYPE(RTCE2EEManager)>

@property(nonatomic, readonly) NSString *userId;
@property(nonatomic, readonly) RTC_OBJC_TYPE(RTCEncryptionAlgorithm) algorithm;
@property(nonatomic, readonly, getter=isDisposed) BOOL disposed;
@property(nonatomic, weak, nullable)
    id<RTC_OBJC_TYPE(RTCEncryptionManagerDelegate)> delegate;

/** Native always supports encoded transforms (unlike browser Encoded Transform). */
+ (BOOL)isSupported;

+ (nullable instancetype)createWithUserId:(NSString *)userId
                                    error:(NSError **)error
    NS_SWIFT_NAME(create(userId:));

+ (nullable instancetype)createWithUserId:(NSString *)userId
                                algorithm:
                                    (RTC_OBJC_TYPE(RTCEncryptionAlgorithm))
                                        algorithm
                                    error:(NSError **)error
    NS_SWIFT_NAME(create(userId:algorithm:));

- (nullable instancetype)initWithUserId:(NSString *)userId;

- (nullable instancetype)initWithUserId:(NSString *)userId
                              algorithm:
                                  (RTC_OBJC_TYPE(RTCEncryptionAlgorithm))
                                      algorithm NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (BOOL)setKey:(NSString *)userId
      keyIndex:(int)keyIndex
        rawKey:(NSData *)rawKey
         error:(NSError **)error NS_SWIFT_NAME(setKey(_:keyIndex:rawKey:));

- (BOOL)setSharedKey:(int)keyIndex
              rawKey:(NSData *)rawKey
               error:(NSError **)error NS_SWIFT_NAME(setSharedKey(_:rawKey:));

- (BOOL)removeKey:(NSString *)userId
         keyIndex:(int)keyIndex
            error:(NSError **)error NS_SWIFT_NAME(removeKey(_:keyIndex:));

- (BOOL)removeAllKeys:(NSString *)userId
                error:(NSError **)error NS_SWIFT_NAME(removeAllKeys(_:));

- (BOOL)removeSharedKey:(int)keyIndex
                  error:(NSError **)error NS_SWIFT_NAME(removeSharedKey(_:));

- (BOOL)encrypt:(RTC_OBJC_TYPE(RTCRtpSender) *)sender
          error:(NSError **)error NS_SWIFT_NAME(encrypt(_:));

/** `codec` is an exact lowercase pin (`opus`/`vp8`/`vp9`/`h264`). Nil reads the frame. */
- (BOOL)encrypt:(RTC_OBJC_TYPE(RTCRtpSender) *)sender
          codec:(nullable NSString *)codec
      trackType:(nullable NSNumber *)trackType
          error:(NSError **)error NS_SWIFT_NAME(encrypt(_:codec:trackType:));

- (BOOL)decrypt:(RTC_OBJC_TYPE(RTCRtpReceiver) *)receiver
         userId:(NSString *)userId
          error:(NSError **)error NS_SWIFT_NAME(decrypt(_:userId:));

- (BOOL)decrypt:(RTC_OBJC_TYPE(RTCRtpReceiver) *)receiver
         userId:(NSString *)userId
      trackType:(nullable NSNumber *)trackType
          error:(NSError **)error NS_SWIFT_NAME(decrypt(_:userId:trackType:));

- (BOOL)enablePerformanceReporting:(BOOL)enabled
                             error:(NSError **)error
    NS_SWIFT_NAME(enablePerformanceReporting(_:));

- (BOOL)requestKeyState:(NSError **)error NS_SWIFT_NAME(requestKeyState());

- (void)dispose;

@end

NS_ASSUME_NONNULL_END
