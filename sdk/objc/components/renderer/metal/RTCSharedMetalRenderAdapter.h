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
#import <QuartzCore/CAMetalLayer.h>

#import "RTCVideoFrame.h"
#import "sdk/objc/base/RTCMacros.h"

#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

@class RTC_OBJC_TYPE(RTCSharedMetalRenderingContext);
@protocol MTLCommandBuffer;

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCSharedMetalRenderAdapter) : NSObject

- (instancetype)initWithContext:
    (RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) *)context
    NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)renderFrame:(nullable RTC_OBJC_TYPE(RTCVideoFrame) *)frame;
- (BOOL)consumeNeedsRedraw;
- (nullable RTC_OBJC_TYPE(RTCVideoFrame) *)consumeFrame;

- (void)setContentMode:(UIViewContentMode)contentMode;
- (void)setMaxInFlightFrames:(NSInteger)maxInFlightFrames;

- (BOOL)beginFrameIfPossible;
- (void)endFrame;

- (BOOL)encodeFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
           drawable:(id<CAMetalDrawable>)drawable
            context:(RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) *)context
      commandBuffer:(id<MTLCommandBuffer>)commandBuffer
   rotationOverride:(nullable NSValue *)rotationOverride;

@end

NS_ASSUME_NONNULL_END
