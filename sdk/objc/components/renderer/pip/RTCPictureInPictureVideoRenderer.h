/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import <AVFoundation/AVFoundation.h>

#import "RTCVideoRenderer.h"
#import "sdk/objc/base/RTCMacros.h"

NS_ASSUME_NONNULL_BEGIN

#if TARGET_OS_IPHONE && (!defined(TARGET_OS_VISION) || !TARGET_OS_VISION)
/**
 * Ready-to-use PiP renderer for WebRTC tracks.
 *
 * This view conforms to `RTCVideoRenderer` and can be attached directly to
 * `RTCVideoTrack`. Internally, it:
 * - converts incoming `RTCVideoFrame` to `CMSampleBuffer` using
 *   `RTCVideoFrameConverter`,
 * - enqueues frames into an `AVSampleBufferDisplayLayer`,
 * - stays agnostic to WebRTC frame policies/backends.
 */
RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCPictureInPictureVideoRenderer)
    : UIView<RTC_OBJC_TYPE(RTCVideoRenderer)>

/** Mirrors existing WebRTC renderer delegate semantics. */
@property(nonatomic, weak) id<RTC_OBJC_TYPE(RTCVideoViewDelegate)> delegate;
/** Turns rendering on/off without detaching the renderer from track. */
@property(nonatomic, getter=isEnabled) BOOL enabled;
/** Forwards directly to underlying AVSampleBufferDisplayLayer gravity. */
@property(nonatomic) AVLayerVideoGravity videoGravity;
/**
 * If enabled, incoming frames are resized to renderer bounds before enqueue.
 * If disabled, renderer uses track-reported size/frame size.
 */
@property(nonatomic) BOOL resizesFramesToRendererSize;

@end
#endif

NS_ASSUME_NONNULL_END
