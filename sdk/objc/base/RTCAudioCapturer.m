/*
 *  Copyright 2025 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <Foundation/Foundation.h>

#import "RTCAudioCapturer.h"

@interface RTC_OBJC_TYPE (RTCAudioCapturer) () {
  BOOL _running;
}
@end

@implementation RTC_OBJC_TYPE (RTCAudioCapturer)

@synthesize delegate = _delegate;
@synthesize running = _running;

- (instancetype)initWithDelegate:
    (id<RTC_OBJC_TYPE(RTCAudioCapturerDelegate)>)delegate {
  self = [super init];
  if (self) {
    _delegate = delegate;
    _running = NO;
  }
  return self;
}

- (void)start {
  _running = YES;
}

- (void)stop {
  _running = NO;
}

- (BOOL)isRunning {
  return _running;
}

@end
