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

#import "api/peerconnection/RTCAudioDeviceModule.h"
#import "api/peerconnection/RTCPeerConnectionFactory.h"
#import "components/audio/RTCAudioSession+Private.h"

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

@end

#undef RETURN_IF_SIMULATOR_AUDIO_TEST_DISABLED
