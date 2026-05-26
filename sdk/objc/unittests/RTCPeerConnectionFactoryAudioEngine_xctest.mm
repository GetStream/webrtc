/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <XCTest/XCTest.h>

#include <vector>

#import "api/logging/RTCCallbackLogger.h"
#import "api/peerconnection/RTCConfiguration.h"
#import "api/peerconnection/RTCAudioDeviceModule.h"
#import "api/peerconnection/RTCMediaConstraints.h"
#import "api/peerconnection/RTCPeerConnection.h"
#import "api/peerconnection/RTCPeerConnectionFactory.h"
#import "api/peerconnection/RTCRtpTransceiver.h"
#import "api/peerconnection/RTCSessionDescription.h"
#import "components/audio/RTCAudioSession+Private.h"
#include "modules/audio_device/audio_engine_device.h"

@interface RTC_OBJC_TYPE(RTCAudioSession)
(UnitTesting)

@property(nonatomic, readonly) std::vector<
    __weak id<RTC_OBJC_TYPE(RTCAudioSessionDelegate)> > delegates;

@end

@interface RTCPeerConnectionFactoryAudioEngineTests : XCTestCase
@end

@implementation RTCPeerConnectionFactoryAudioEngineTests

#define RETURN_IF_SIMULATOR_AUDIO_TEST_DISABLED() \
  do {                                            \
    if (TARGET_OS_SIMULATOR) {                    \
      return;                                     \
    }                                             \
  } while (false)

- (void)testAudioEngineModuleRetainedAfterFactoryDeallocDoesNotKeepAudioSessionDelegate {
  RETURN_IF_SIMULATOR_AUDIO_TEST_DISABLED();
  RTC_OBJC_TYPE(RTCAudioSession) *session =
      [RTC_OBJC_TYPE(RTCAudioSession) sharedInstance];
  const size_t delegateCountBeforeFactory = session.delegates.size();

  __attribute__((objc_precise_lifetime))
  RTC_OBJC_TYPE(RTCAudioDeviceModule) *retainedAudioDeviceModule = nil;
  @autoreleasepool {
    RTC_OBJC_TYPE(RTCPeerConnectionFactory) *factory =
        [[RTC_OBJC_TYPE(RTCPeerConnectionFactory) alloc]
            initWithAudioDeviceModuleType:
                RTC_OBJC_TYPE(RTCAudioDeviceModuleTypeAudioEngine)
                      bypassVoiceProcessing:NO
                             encoderFactory:nil
                             decoderFactory:nil
                      audioProcessingModule:nil];
    retainedAudioDeviceModule = factory.audioDeviceModule;

    XCTAssertEqual(delegateCountBeforeFactory + 1, session.delegates.size());
  }

  const size_t delegateCountAfterFactory = session.delegates.size();
  XCTAssertNotNil(retainedAudioDeviceModule);
  XCTAssertEqual(
      delegateCountBeforeFactory,
      delegateCountAfterFactory,
      @"Retaining the audio device module after the factory is released must "
       @"not leave AudioEngineDevice registered with RTCAudioSession.");
  XCTAssertEqual(0u, retainedAudioDeviceModule.outputDevices.count);
  XCTAssertEqual(0u, retainedAudioDeviceModule.inputDevices.count);
  XCTAssertNil(retainedAudioDeviceModule.outputDevice);
  XCTAssertNil(retainedAudioDeviceModule.inputDevice);
  XCTAssertFalse(retainedAudioDeviceModule.playing);
  XCTAssertFalse(retainedAudioDeviceModule.recording);
  XCTAssertFalse(retainedAudioDeviceModule.isEngineRunning);
  XCTAssertFalse([retainedAudioDeviceModule trySetOutputDevice:nil]);
  XCTAssertEqual(-1, [retainedAudioDeviceModule reset]);
  XCTAssertEqual(-1, [retainedAudioDeviceModule startPlayout]);
  XCTAssertEqual(-1, [retainedAudioDeviceModule stopPlayout]);
  XCTAssertEqual(-1, [retainedAudioDeviceModule initRecording]);
  [retainedAudioDeviceModule refreshStereoPlayoutState];

  if (delegateCountAfterFactory == delegateCountBeforeFactory) {
    AVAudioSessionRouteDescription *previousRoute =
        [AVAudioSession sharedInstance].currentRoute;
    [session notifyDidChangeRouteWithReason:
                 AVAudioSessionRouteChangeReasonOldDeviceUnavailable
                          previousRoute:previousRoute];
  }

  retainedAudioDeviceModule = nil;
}

- (void)testAudioEngineDoesNotDropAudioTransportWhenPreparedBeforeOffer {
  RTC_OBJC_TYPE(RTCCallbackLogger) *logger =
      [[RTC_OBJC_TYPE(RTCCallbackLogger) alloc] init];
  logger.severity = RTCLoggingSeverityWarning;
  XCTestExpectation *transportFailure =
      [self expectationWithDescription:@"audio transport registration failure"];
  transportFailure.inverted = YES;
  [logger startWithMessageAndSeverityHandler:^(
              NSString *message, RTCLoggingSeverity severity) {
    if ([message containsString:
                     @"Failed to set audio transport since media was active"] ||
        [message containsString:@"Invalid audio transport"]) {
      [transportFailure fulfill];
    }
  }];

  RTC_OBJC_TYPE(RTCPeerConnectionFactory) *factory =
      [[RTC_OBJC_TYPE(RTCPeerConnectionFactory) alloc]
          initWithAudioDeviceModuleType:
              RTC_OBJC_TYPE(RTCAudioDeviceModuleTypeAudioEngine)
                    bypassVoiceProcessing:NO
                           encoderFactory:nil
                           decoderFactory:nil
                    audioProcessingModule:nil];
  RTC_OBJC_TYPE(RTCAudioDeviceModule) *audioDeviceModule =
      factory.audioDeviceModule;
  XCTAssertEqual(0, [audioDeviceModule setRecordingAlwaysPreparedMode:YES]);
  XCTAssertTrue(audioDeviceModule.recordingAlwaysPreparedMode);

  RTC_OBJC_TYPE(RTCConfiguration) *config =
      [[RTC_OBJC_TYPE(RTCConfiguration) alloc] init];
  config.sdpSemantics = RTCSdpSemanticsUnifiedPlan;
  RTC_OBJC_TYPE(RTCMediaConstraints) *constraints =
      [[RTC_OBJC_TYPE(RTCMediaConstraints) alloc]
          initWithMandatoryConstraints:@{
            RTC_CONSTANT_TYPE(RTCMediaConstraintsOfferToReceiveAudio) :
                RTC_CONSTANT_TYPE(RTCMediaConstraintsValueTrue)
          }
                   optionalConstraints:nil];
  RTC_OBJC_TYPE(RTCPeerConnection) *peerConnection =
      [factory peerConnectionWithConfiguration:config
                                   constraints:constraints
                                      delegate:nil];
  RTC_OBJC_TYPE(RTCRtpTransceiverInit) *transceiverInit =
      [[RTC_OBJC_TYPE(RTCRtpTransceiverInit) alloc] init];
  transceiverInit.direction = RTCRtpTransceiverDirectionRecvOnly;
  XCTAssertNotNil([peerConnection addTransceiverOfType:RTCRtpMediaTypeAudio
                                                  init:transceiverInit]);

  dispatch_semaphore_t offerSemaphore = dispatch_semaphore_create(0);
  __block RTC_OBJC_TYPE(RTCSessionDescription) *localOffer = nil;
  __block NSError *localOfferError = nil;
  [peerConnection
      offerForConstraints:constraints
        completionHandler:^(
            RTC_OBJC_TYPE(RTCSessionDescription) *_Nullable offer,
            NSError *_Nullable error) {
          localOffer = offer;
          localOfferError = error;
          dispatch_semaphore_signal(offerSemaphore);
        }];
  XCTAssertEqual(
      0,
      dispatch_semaphore_wait(
          offerSemaphore,
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC))));
  XCTAssertNil(localOfferError);
  XCTAssertNotNil(localOffer);

  [self waitForExpectations:@[ transportFailure ] timeout:1.0];

  [peerConnection close];
  XCTAssertEqual(0, [audioDeviceModule setRecordingAlwaysPreparedMode:NO]);
  [logger stop];
}

- (void)testAudioEngineInputRenderContextIgnoresLateCallbackAfterInvalidation {
  // This is a focused regression test for the crash where AURemoteIO invoked the AVAudioSinkNode
  // receiver block after AudioEngineDevice had already torn down its converter buffer during the
  // RegisterAudioCallback stop/restart path. The test intentionally does not require real audio
  // hardware: a late callback after invalidation must return cleanly before it touches resources
  // that graph teardown is allowed to clear.
  int16_t sample = 0;
  AudioBufferList inputData;
  inputData.mNumberBuffers = 1;
  inputData.mBuffers[0].mNumberChannels = 1;
  inputData.mBuffers[0].mDataByteSize = sizeof(sample);
  inputData.mBuffers[0].mData = &sample;

  AudioTimeStamp timestamp = {};
  timestamp.mHostTime = 1;

  XCTAssertEqual(noErr,
                 webrtc::AudioEngineDeviceRenderInvalidatedInputContextForTesting(
                     &timestamp, 1, &inputData));
}

@end

#undef RETURN_IF_SIMULATOR_AUDIO_TEST_DISABLED
