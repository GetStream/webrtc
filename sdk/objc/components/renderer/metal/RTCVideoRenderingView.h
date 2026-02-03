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

#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#endif

#import "RTCVideoFrame.h"
#import "RTCVideoRenderer.h"
#import "sdk/objc/base/RTCMacros.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RTC_OBJC_TYPE(RTCVideoRenderingBackend)) {
  RTC_OBJC_TYPE(RTCVideoRenderingBackendDefault) = 0,
  // Shared Metal backend is currently iOS-only and is gated by
  // RTC_STREAM_RENDERING_BACKEND. On other platforms it falls back to default.
  RTC_OBJC_TYPE(RTCVideoRenderingBackendSharedMetal)
};

#if TARGET_OS_IPHONE
NS_CLASS_AVAILABLE_IOS(9)
#elif TARGET_OS_OSX
NS_AVAILABLE_MAC(10.11)
#endif

RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCVideoRenderingView) :
#if TARGET_OS_IPHONE
    UIView<RTC_OBJC_TYPE(RTCVideoRenderer)>
#elif TARGET_OS_OSX
    NSView<RTC_OBJC_TYPE(RTCVideoRenderer)>
#endif

@property(nonatomic, weak) id<RTC_OBJC_TYPE(RTCVideoViewDelegate)> delegate;

#if TARGET_OS_IPHONE
@property(nonatomic) UIViewContentMode videoContentMode;
#endif

@property(nonatomic, getter=isEnabled) BOOL enabled;
// Wraps an RTCVideoRotation value. Set to nil to use the frame's rotation.
// Swift example:
//   let rotation = RTCVideoRotation._90
//   view.rotationOverride = NSNumber(value: rotation.rawValue)
@property(nonatomic, nullable) NSValue *rotationOverride;
// Limits the number of GPU command buffers allowed in flight at once.
// Default is 0 (unlimited). Higher values allow more buffering at the cost
// of extra latency/memory; lower values reduce latency and can drop frames
// when the renderer is saturated. Ignored by backends that do not support it.
@property(nonatomic, assign) NSInteger maxInFlightFrames;

@property(nonatomic, assign) RTC_OBJC_TYPE(RTCVideoRenderingBackend) renderingBackend;

@end

NS_ASSUME_NONNULL_END
