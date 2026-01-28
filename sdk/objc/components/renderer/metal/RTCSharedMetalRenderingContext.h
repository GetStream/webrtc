/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <Foundation/Foundation.h>

#import "sdk/objc/base/RTCMacros.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@class RTC_OBJC_TYPE(RTCSharedMetalVideoView);

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) : NSObject

// Shared Metal context used by RTCSharedMetalVideoView. iOS-only.
+ (nullable instancetype)sharedContext;

- (void)registerView:(RTC_OBJC_TYPE(RTCSharedMetalVideoView) *)view;
- (void)unregisterView:(RTC_OBJC_TYPE(RTCSharedMetalVideoView) *)view;

@end

NS_ASSUME_NONNULL_END
