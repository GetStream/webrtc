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
#import <XCTest/XCTest.h>

#import "api/peerconnection/RTCEncryptionManager.h"

@interface RTCEncryptionManagerTestDelegate : NSObject <RTC_OBJC_TYPE(RTCEncryptionManagerDelegate)>
@property(nonatomic) NSMutableArray<RTC_OBJC_TYPE(RTCE2eeEvent) *> *events;
@property(nonatomic, nullable) XCTestExpectation *nextEvent;
@end

@implementation RTCEncryptionManagerTestDelegate
- (instancetype)init {
  self = [super init];
  if (self) {
    _events = [NSMutableArray array];
  }
  return self;
}
- (void)encryptionManager:(RTC_OBJC_TYPE(RTCEncryptionManager) *)manager
          didReceiveEvent:(RTC_OBJC_TYPE(RTCE2eeEvent) *)event {
  [self.events addObject:event];
  [self.nextEvent fulfill];
}
@end

@interface RTCEncryptionManagerTest : XCTestCase
@end

@implementation RTCEncryptionManagerTest

- (NSData *)aes128Key {
  uint8_t bytes[16] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15};
  return [NSData dataWithBytes:bytes length:16];
}

- (void)testHostApiMatchesJs {
  XCTAssertTrue([RTC_OBJC_TYPE(RTCEncryptionManager) isSupported]);

  NSError *error = nil;
  RTC_OBJC_TYPE(RTCEncryptionManager) *manager =
      [RTC_OBJC_TYPE(RTCEncryptionManager) createWithUserId:@"local"
                                                      error:&error];
  XCTAssertNotNil(manager);
  XCTAssertNil(error);
  XCTAssertEqualObjects(manager.userId, @"local");
  XCTAssertEqual(manager.algorithm,
                 RTC_OBJC_TYPE(RTCEncryptionAlgorithmAes128Gcm));

  XCTAssertFalse([manager setKey:@"local"
                        keyIndex:0
                          rawKey:[NSData dataWithBytes:"short" length:5]
                           error:&error]);
  XCTAssertEqual(error.code,
                 RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeInvalidKeyLength));

  error = nil;
  XCTAssertTrue([manager setKey:@"local"
                       keyIndex:0
                         rawKey:[self aes128Key]
                          error:&error]);
  XCTAssertNil(error);

  RTCEncryptionManagerTestDelegate *delegate =
      [[RTCEncryptionManagerTestDelegate alloc] init];
  delegate.nextEvent = [self expectationWithDescription:@"e2ee.key_state"];
  manager.delegate = delegate;

  XCTAssertTrue([manager requestKeyState:&error]);
  [self waitForExpectations:@[ delegate.nextEvent ] timeout:2];
  XCTAssertEqual(delegate.events.count, 1u);
  RTC_OBJC_TYPE(RTCE2eeEvent) *event = delegate.events.firstObject;
  XCTAssertEqual(event.type, RTC_OBJC_TYPE(RTCE2eeEventTypeKeyState));
  XCTAssertEqualObjects(event.name, @"e2ee.key_state");
  XCTAssertEqual(event.keyState.perUserKeys.count, 1u);
  XCTAssertEqualObjects(event.keyState.perUserKeys.firstObject.userId, @"local");
  XCTAssertEqual(event.keyState.perUserKeys.firstObject.keyIndex, 0);
  XCTAssertEqual(event.keyState.perUserKeys.firstObject.fingerprint.length, 16u);

  [manager dispose];
  XCTAssertTrue(manager.isDisposed);
  error = nil;
  XCTAssertFalse([manager setKey:@"local"
                        keyIndex:0
                          rawKey:[self aes128Key]
                           error:&error]);
  XCTAssertEqual(error.code,
                 RTC_OBJC_TYPE(RTCEncryptionManagerErrorCodeDisposed));
}

@end
