/*
 *  Copyright 2015 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <XCTest/XCTest.h>
#import "api/peerconnection/RTCPeerConnectionFactory+Native.h"
#import "api/peerconnection/RTCPeerConnectionFactoryBuilder+DefaultComponents.h"
#import "api/peerconnection/RTCPeerConnectionFactoryBuilder.h"

#include "api/audio/audio_device.h"
#include "api/audio/audio_processing.h"
#include "api/audio_codecs/builtin_audio_decoder_factory.h"
#include "api/audio_codecs/builtin_audio_encoder_factory.h"
#include "api/video_codecs/video_decoder_factory.h"
#include "api/video_codecs/video_encoder_factory.h"

#include <utility>

#include "rtc_base/gunit.h"

namespace {

id StubInitWithMediaAndDependencies(
    RTC_OBJC_TYPE(RTCPeerConnectionFactory) * factory,
    SEL selector,
    webrtc::PeerConnectionFactoryDependencies dependencies) {
  return factory;
}

RTC_OBJC_TYPE(RTCPeerConnectionFactory) *
    CreatePeerConnectionFactoryWithStubbedNativeInitializer(
        RTCPeerConnectionFactoryBuilder *builder) {
  Method initializer = class_getInstanceMethod(
      [RTC_OBJC_TYPE(RTCPeerConnectionFactory) class],
      @selector(initWithMediaAndDependencies:));
  IMP original_initializer =
      method_setImplementation(initializer,
                               reinterpret_cast<IMP>(
                                   &StubInitWithMediaAndDependencies));
  @try {
    return [builder createPeerConnectionFactory];
  } @finally {
    method_setImplementation(initializer, original_initializer);
  }
}

}  // namespace

@interface RTCPeerConnectionFactoryBuilderTests : XCTestCase
@end

@implementation RTCPeerConnectionFactoryBuilderTests

- (void)testBuilder {
  RTCPeerConnectionFactoryBuilder* builder =
      [[RTCPeerConnectionFactoryBuilder alloc] init];
  RTC_OBJC_TYPE(RTCPeerConnectionFactory)* peerConnectionFactory =
      CreatePeerConnectionFactoryWithStubbedNativeInitializer(builder);
  EXPECT_TRUE(peerConnectionFactory != nil);
}

- (void)testAudioDeviceModuleBuilder {
  RTCPeerConnectionFactoryBuilder* builder =
      [RTCPeerConnectionFactoryBuilder builder];
  __block int calledAdmBuilder = 0;
  [builder setAudioDeviceModuleBuilder:^(const webrtc::Environment& env) {
    calledAdmBuilder++;
    return webrtc::scoped_refptr<webrtc::AudioDeviceModule>(nullptr);
  }];
  RTC_OBJC_TYPE(RTCPeerConnectionFactory)* peerConnectionFactory =
      CreatePeerConnectionFactoryWithStubbedNativeInitializer(builder);
  EXPECT_TRUE(peerConnectionFactory != nil);
  EXPECT_EQ(calledAdmBuilder, 1);
}

- (void)testDefaultComponentsBuilder {
  RTCPeerConnectionFactoryBuilder* builder =
      [RTCPeerConnectionFactoryBuilder defaultBuilder];
  RTC_OBJC_TYPE(RTCPeerConnectionFactory)* peerConnectionFactory =
      CreatePeerConnectionFactoryWithStubbedNativeInitializer(builder);
  EXPECT_TRUE(peerConnectionFactory != nil);
}
@end
