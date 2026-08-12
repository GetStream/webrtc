/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <OCMock/OCMock.h>
#import <XCTest/XCTest.h>

#include <memory>
#include <thread>
#include <vector>

#include "api/environment/environment_factory.h"
#import "api/logging/RTCCallbackLogger.h"
#import "api/peerconnection/RTCConfiguration.h"
#import "api/peerconnection/RTCAudioDeviceModule.h"
#import "api/peerconnection/RTCMediaConstraints.h"
#import "api/peerconnection/RTCPeerConnection.h"
#import "api/peerconnection/RTCPeerConnectionFactory.h"
#import "api/peerconnection/RTCRtpTransceiver.h"
#import "api/peerconnection/RTCSessionDescription.h"
#import "components/audio/RTCAudioSession+Private.h"
#include "modules/audio_device/audio_device_buffer.h"
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

- (void)testMediaServicesRecoveryReconfiguresAfterInterruptionEnd {
  RTC_OBJC_TYPE(RTCPeerConnectionFactory) *factory =
      [[RTC_OBJC_TYPE(RTCPeerConnectionFactory) alloc]
          initWithAudioDeviceModuleType:RTC_OBJC_TYPE(
                                            RTCAudioDeviceModuleTypeAudioEngine)
                  bypassVoiceProcessing:NO
                         encoderFactory:nil
                         decoderFactory:nil
                  audioProcessingModule:nil];
  XCTAssertNotNil(factory.audioDeviceModule);

  XCTestExpectation *reconfiguredTwice =
      [self expectationWithDescription:@"audio engine reconfigured twice"];
  reconfiguredTwice.expectedFulfillmentCount = 2;
  RTC_OBJC_TYPE(RTCCallbackLogger) *logger =
      [[RTC_OBJC_TYPE(RTCCallbackLogger) alloc] init];
  logger.severity = RTCLoggingSeverityInfo;
  [logger startWithMessageAndSeverityHandler:^(NSString *message,
                                               RTCLoggingSeverity severity) {
    if ([message containsString:@"AudioEngineDevice::ReconfigureEngine"]) {
      [reconfiguredTwice fulfill];
    }
  }];

  RTC_OBJC_TYPE(RTCAudioSession) *session =
      [RTC_OBJC_TYPE(RTCAudioSession) sharedInstance];
  [session notifyMediaServicesWereReset];
  [session notifyDidEndInterruptionWithShouldResumeSession:YES];

  [self waitForExpectations:@[ reconfiguredTwice ] timeout:1.0];
  [logger stop];
}

- (void)
    testMediaServicesRecoveryRemainsPendingWhenDeferredReconfigurationFails {
  RTC_OBJC_TYPE(RTCPeerConnectionFactory) *factory =
      [[RTC_OBJC_TYPE(RTCPeerConnectionFactory) alloc]
          initWithAudioDeviceModuleType:RTC_OBJC_TYPE(
                                            RTCAudioDeviceModuleTypeAudioEngine)
                  bypassVoiceProcessing:NO
                         encoderFactory:nil
                         decoderFactory:nil
                  audioProcessingModule:nil];
  RTC_OBJC_TYPE(RTCAudioDeviceModule) *audioDeviceModule =
      factory.audioDeviceModule;

  RTC_OBJC_TYPE(RTCMediaConstraints) *constraints =
      [[RTC_OBJC_TYPE(RTCMediaConstraints) alloc]
          initWithMandatoryConstraints:nil
                   optionalConstraints:nil];
  RTC_OBJC_TYPE(RTCPeerConnection) *peerConnection = [factory
      peerConnectionWithConfiguration:[[RTC_OBJC_TYPE(RTCConfiguration) alloc]
                                          init]
                          constraints:constraints
                             delegate:nil];
  XCTAssertNotNil(peerConnection);
  XCTAssertEqual(0, [audioDeviceModule initPlayout]);

  id observer =
      OCMProtocolMock(@protocol(RTC_OBJC_TYPE(RTCAudioDeviceModuleDelegate)));
  OCMStub([observer audioDeviceModule:[OCMArg any]
                    willReleaseEngine:[OCMArg any]])
      .andReturn(-1);
  audioDeviceModule.observer = observer;

  XCTestExpectation *initialFailures =
      [self expectationWithDescription:@"initial reconfiguration failures"];
  initialFailures.expectedFulfillmentCount = 2;
  XCTestExpectation *retryFailure =
      [self expectationWithDescription:@"retried reconfiguration failure"];
  __block NSUInteger failureCount = 0;
  RTC_OBJC_TYPE(RTCCallbackLogger) *logger =
      [[RTC_OBJC_TYPE(RTCCallbackLogger) alloc] init];
  logger.severity = RTCLoggingSeverityError;
  [logger startWithMessageAndSeverityHandler:^(NSString *message,
                                               RTCLoggingSeverity severity) {
    if ([message
            containsString:@"ReconfigureEngine: Failed to shutdown engine"]) {
      failureCount++;
      if (failureCount <= 2) {
        [initialFailures fulfill];
      } else if (failureCount == 3) {
        [retryFailure fulfill];
      }
    }
  }];

  RTC_OBJC_TYPE(RTCAudioSession) *session =
      [RTC_OBJC_TYPE(RTCAudioSession) sharedInstance];
  [session notifyMediaServicesWereReset];
  [session notifyDidEndInterruptionWithShouldResumeSession:YES];
  [self waitForExpectations:@[ initialFailures ] timeout:1.0];

  [session notifyDidEndInterruptionWithShouldResumeSession:YES];
  [self waitForExpectations:@[ retryFailure ] timeout:1.0];

  audioDeviceModule.observer = nil;
  XCTAssertEqual(0, [audioDeviceModule reset]);
  [peerConnection close];
  [logger stop];
}

- (void)testAudioEngineInputRenderContextIgnoresLateCallbackAfterInvalidation {
  auto audioDeviceBuffer = std::make_shared<webrtc::AudioDeviceBuffer>(
      webrtc::CreateEnvironment());
  audioDeviceBuffer->SetRecordingSampleRate(48000);
  audioDeviceBuffer->SetRecordingChannels(1);

  AVAudioFormat *engineFormat =
      [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                      sampleRate:48000
                                        channels:1
                                     interleaved:YES];
  AVAudioFormat *rtcFormat =
      [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                      sampleRate:48000
                                        channels:1
                                     interleaved:YES];
  auto subject = std::make_shared<webrtc::AudioEngineInputRenderContext>(
      engineFormat, rtcFormat, audioDeviceBuffer, 1.0);

  subject->Invalidate();

  XCTAssertEqual(noErr, subject->Render(nullptr, 0, nullptr));
}

- (void)testAudioEngineInputRenderContextDoesNotOwnAudioDeviceBuffer {
  const std::thread::id ownerThread = std::this_thread::get_id();
  std::thread::id deleterThread;
  auto audioDeviceBuffer = std::shared_ptr<webrtc::AudioDeviceBuffer>(
      new webrtc::AudioDeviceBuffer(webrtc::CreateEnvironment(),
                                    /*create_detached=*/true),
      [&deleterThread](webrtc::AudioDeviceBuffer *buffer) {
        deleterThread = std::this_thread::get_id();
        delete buffer;
      });

  AVAudioFormat *engineFormat =
      [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                      sampleRate:48000
                                        channels:1
                                     interleaved:YES];
  AVAudioFormat *rtcFormat =
      [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                      sampleRate:48000
                                        channels:1
                                     interleaved:YES];
  auto subject = std::make_shared<webrtc::AudioEngineInputRenderContext>(
      engineFormat, rtcFormat, audioDeviceBuffer, 1.0);

  subject->Invalidate();
  audioDeviceBuffer.reset();
  std::thread releaseThread(
      [subject = std::move(subject)]() mutable { subject.reset(); });
  releaseThread.join();

  XCTAssertEqual(ownerThread, deleterThread);
}

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

- (void)testEnablingRecordingWhilePlayoutIsRunningKeepsVoiceProcessingEnabled {
  RETURN_IF_SIMULATOR_AUDIO_TEST_DISABLED();

  AVAudioSession *session = [AVAudioSession sharedInstance];
  NSError *sessionError = nil;
  XCTAssertTrue([session setCategory:AVAudioSessionCategoryPlayAndRecord
                                mode:AVAudioSessionModeVoiceChat
                             options:0
                               error:&sessionError]);
  XCTAssertNil(sessionError);
  XCTAssertTrue([session setActive:YES error:&sessionError]);
  XCTAssertNil(sessionError);

  RTC_OBJC_TYPE(RTCPeerConnectionFactory) *factory =
      [[RTC_OBJC_TYPE(RTCPeerConnectionFactory) alloc]
          initWithAudioDeviceModuleType:RTC_OBJC_TYPE(
                                            RTCAudioDeviceModuleTypeAudioEngine)
                  bypassVoiceProcessing:NO
                         encoderFactory:nil
                         decoderFactory:nil
                  audioProcessingModule:nil];
  RTC_OBJC_TYPE(RTCAudioDeviceModule) *audioDeviceModule =
      factory.audioDeviceModule;

  XCTAssertEqual(0, [audioDeviceModule initPlayout]);
  XCTAssertEqual(0, [audioDeviceModule startPlayout]);

  for (NSUInteger iteration = 0; iteration < 5; iteration++) {
    XCTAssertEqual(0, [audioDeviceModule initAndStartRecording]);
    XCTAssertTrue(audioDeviceModule.isRecording);
    XCTAssertTrue(audioDeviceModule.isVoiceProcessingEnabled);
    XCTAssertEqual(0, [audioDeviceModule stopRecording]);
    XCTAssertTrue(audioDeviceModule.isPlaying);
  }

  XCTAssertEqual(0, [audioDeviceModule stopPlayout]);
  XCTAssertTrue([session
        setActive:NO
      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
            error:&sessionError]);
  XCTAssertNil(sessionError);
}

@end

#undef RETURN_IF_SIMULATOR_AUDIO_TEST_DISABLED
