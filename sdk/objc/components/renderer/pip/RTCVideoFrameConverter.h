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

#import "RTCVideoFrame.h"
#import "sdk/objc/base/RTCMacros.h"

NS_ASSUME_NONNULL_BEGIN

#if TARGET_OS_IPHONE && (!defined(TARGET_OS_VISION) || !TARGET_OS_VISION)
/**
 * Converts WebRTC `RTCVideoFrame` instances into AVFoundation-friendly media.
 *
 * This type is intentionally backend/policy agnostic.
 * Depending on renderer backend and frame-buffer policy, WebRTC can surface
 * frames as:
 * - native NV12 buffers,
 * - I420 buffers,
 * - custom buffers that expose `toI420`,
 * - buffers that can directly expose a `CVPixelBuffer`.
 *
 * PiP rendering via `AVSampleBufferDisplayLayer` needs `CMSampleBuffer`
 * objects. This converter centralizes the conversion contract so callers do
 * not branch on frame-buffer implementation details.
 *
 * Conversion goals:
 * 1. Preserve live-call rendering semantics (timestamps and frame order).
 * 2. Prefer zero/low-copy fast paths when a native pixel buffer exists.
 * 3. Fall back to deterministic I420 -> NV12 conversion when needed.
 * 4. Keep one stable public API regardless of active WebRTC internals.
 *
 * Threading:
 * - Callers typically use one converter from one serial render queue.
 * - Internally, pixel-buffer pool access is synchronized for safety.
 */
RTC_OBJC_EXPORT
@interface RTC_OBJC_TYPE(RTCVideoFrameConverter) : NSObject

/**
 * Returns a retained NV12 `CVPixelBuffer` for the input frame.
 *
 * Conversion strategy:
 * - Prefer direct `pixelBuffer` export from the source frame buffer.
 * - If unavailable, convert through `toI420`, then pack to NV12.
 *
 * Output format:
 * - `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (NV12, full range),
 *   chosen for AVFoundation compatibility and efficient iOS render paths.
 *
 * `targetSize` behavior:
 * - If zero/invalid, the source frame dimensions are used.
 * - If provided, the converter attempts full-frame scale using
 *   `cropAndScaleWith:...` when supported by the concrete buffer type.
 * - Size is normalized to at least `1x1`.
 *
 * Ownership:
 * - Returned buffer follows CoreFoundation ownership rules
 *   (`CF_RETURNS_RETAINED`): caller must release.
 */
- (nullable CVPixelBufferRef)
    copyPixelBufferFromFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
                  targetSize:(CGSize)targetSize CF_RETURNS_RETAINED;

/**
 * Returns a retained `CMSampleBuffer` for the input frame.
 *
 * Internally:
 * 1. Calls `copyPixelBufferFromFrame:targetSize:`.
 * 2. Builds a `CMVideoFormatDescription` from the image buffer.
 * 3. Wraps both into a `CMSampleBuffer`.
 * 4. Uses `frame.timeStampNs` as presentation timestamp.
 * 5. Marks attachment `kCMSampleAttachmentKey_DisplayImmediately` for
 *    low-latency live rendering.
 *
 * Ownership:
 * - Returned sample buffer is retained (`CF_RETURNS_RETAINED`): caller must
 *   release.
 */
- (nullable CMSampleBufferRef)
    copySampleBufferFromFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
                   targetSize:(CGSize)targetSize CF_RETURNS_RETAINED;

@end
#endif

NS_ASSUME_NONNULL_END
