@import XCTest;

#import "sdk/objc/api/peerconnection/RTCExternalAudioTrack.h"
#import "sdk/objc/api/peerconnection/RTCPeerConnectionFactoryBuilder+DefaultComponents.h"
#import "sdk/objc/api/peerconnection/RTCPeerConnectionFactoryBuilder.h"
#import "sdk/objc/api/peerconnection/RTCPeerConnection.h"
#import "sdk/objc/api/peerconnection/RTCConfiguration.h"

@interface RTCExternalAudioTrackTests : XCTestCase
@end

@implementation RTCExternalAudioTrackTests

- (void)testAttachAndPushUsingDefaults {
  // Build factory with default components.
  RTC_OBJC_TYPE(RTCPeerConnectionFactoryBuilder) *builder =
      [RTC_OBJC_TYPE(RTCPeerConnectionFactoryBuilder) defaultBuilder];
  RTC_OBJC_TYPE(RTCPeerConnectionFactory) *factory = [builder createPeerConnectionFactory];
  XCTAssertNotNil(factory);

  // Create a peer connection.
  RTC_OBJC_TYPE(RTCPeerConnection) *pc =
      [factory peerConnectionWithConfiguration:[[RTC_OBJC_TYPE(RTCConfiguration) alloc] init]
                                   constraints:nil
                                      delegate:nil];
  XCTAssertNotNil(pc);

  // Create external audio track and add to PC.
  RTC_OBJC_TYPE(RTCExternalAudioTrack) *extTrack =
      [[RTC_OBJC_TYPE(RTCExternalAudioTrack) alloc] initWithFactory:factory trackId:@"ext-audio-test"];
  XCTAssertNotNil(extTrack);

  RTC_OBJC_TYPE(RTCRtpSender) *sender = [pc addTrack:extTrack streamIds:@[ @"s" ]];
  XCTAssertNotNil(sender);

  // Attach internal source and verify.
  BOOL attached = [extTrack attachToSender:sender];
  XCTAssertTrue(attached);

  // Set defaults and push 20 ms of silence using defaults.
  [extTrack setDefaultSampleRate:48000 channels:1];
  const int frames = 480 * 2;  // 20 ms
  int16_t buffer[frames];
  memset(buffer, 0, sizeof(buffer));
  [extTrack pushPCM:buffer frames:frames captureTimeNs:0];

  // If we reach here without crash, the test passes.
  [pc close];
}

@end

