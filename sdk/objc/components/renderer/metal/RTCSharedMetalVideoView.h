/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <UIKit/UIKit.h>

#import "RTCVideoRenderer.h"
#import "sdk/objc/base/RTCMacros.h"

NS_ASSUME_NONNULL_BEGIN

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCSharedMetalVideoView)
    : UIView<RTC_OBJC_TYPE(RTCVideoRenderer)>

@property(nonatomic, weak) id<RTC_OBJC_TYPE(RTCVideoViewDelegate)> delegate;
@property(nonatomic) UIViewContentMode videoContentMode;
@property(nonatomic, getter=isEnabled) BOOL enabled;
@property(nonatomic, nullable) NSValue *rotationOverride;
// Limits in-flight frames for the shared Metal pipeline.
@property(nonatomic, assign) NSInteger maxInFlightFrames;

- (void)drawIfNeeded;

@end

NS_ASSUME_NONNULL_END
