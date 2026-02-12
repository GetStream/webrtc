/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCVideoFrameConverter.h"

#if TARGET_OS_IPHONE && (!defined(TARGET_OS_VISION) || !TARGET_OS_VISION)

#import <CoreMedia/CoreMedia.h>

#include <algorithm>

#import "base/RTCI420Buffer.h"
#import "base/RTCVideoFrame.h"
#import "base/RTCVideoFrameBuffer.h"
#include "third_party/libyuv/include/libyuv/convert.h"

namespace {

// Normalizes caller-provided target size:
// - If caller passes `.zero`, we preserve the frame's original resolution.
// - We clamp to at least 1x1 to avoid invalid scaling inputs.
static CGSize NormalizeTargetSize(CGSize targetSize, int width, int height) {
  if (targetSize.width <= 0 || targetSize.height <= 0) {
    return CGSizeMake(width, height);
  }
  int target_width = std::max(1, static_cast<int>(targetSize.width));
  int target_height = std::max(1, static_cast<int>(targetSize.height));
  return CGSizeMake(target_width, target_height);
}

}  // namespace

@interface RTC_OBJC_TYPE(RTCVideoFrameConverter) () {
  // Reused pool for NV12 output buffers. This avoids per-frame allocations
  // when the output size is stable, which is common during active PiP.
  CVPixelBufferPoolRef _pixelBufferPool;
  // Tracks current pool dimensions so we can rebuild only on size changes.
  int _poolWidth;
  int _poolHeight;
}

@end

@implementation RTC_OBJC_TYPE(RTCVideoFrameConverter)

- (void)dealloc {
  // Release CoreFoundation resources owned by this converter instance.
  if (_pixelBufferPool) {
    CVPixelBufferPoolRelease(_pixelBufferPool);
    _pixelBufferPool = nil;
  }
}

- (CVPixelBufferRef)copyPixelBufferFromFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
                                  targetSize:(CGSize)targetSize {
  // Defensive guard: converter never crashes on nil/invalid frame input.
  if (!frame || !frame.buffer) {
    return nil;
  }

  id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> buffer = frame.buffer;
  // Normalize requested output size once so all subsequent paths agree.
  CGSize normalized =
      NormalizeTargetSize(targetSize, frame.buffer.width, frame.buffer.height);
  // If the source buffer supports crop/scale, apply it before conversion.
  // This keeps conversion work proportional to final PiP output size.
  id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> workingBuffer =
      [self maybeScaleBuffer:buffer targetSize:normalized];

  // Fast path:
  // Some WebRTC buffers can expose a native CVPixelBuffer directly. If so,
  // use that and avoid YUV plane conversions.
  CVPixelBufferRef pixelBuffer =
      [self copyPixelBufferFromFrameBuffer:workingBuffer];
  if (pixelBuffer) {
    // Keep resize semantics consistent across all buffer families:
    // if caller requested a target size, only accept fast-path buffers that
    // already match that size. Otherwise fall back to I420 path where scaling
    // is guaranteed.
    const size_t pixelBufferWidth = CVPixelBufferGetWidth(pixelBuffer);
    const size_t pixelBufferHeight = CVPixelBufferGetHeight(pixelBuffer);
    if (pixelBufferWidth == static_cast<size_t>(normalized.width) &&
        pixelBufferHeight == static_cast<size_t>(normalized.height)) {
      return pixelBuffer;
    }

    CVBufferRelease(pixelBuffer);
  }

  // Fallback path:
  // Convert whatever we received to I420 (universal WebRTC software format).
  id<RTC_OBJC_TYPE(RTCI420Buffer)> i420Buffer = [workingBuffer toI420];
  if (!i420Buffer) {
    return nil;
  }
  // I420 buffers can also support crop/scale; apply it so final output matches
  // requested target dimensions.
  id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> scaledI420 =
      [self maybeScaleBuffer:(id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)>)i420Buffer
                  targetSize:normalized];
  // Convert final I420 into NV12 CVPixelBuffer for AVFoundation consumption.
  return [self copyPixelBufferFromI420Buffer:[scaledI420 toI420]];
}

- (CMSampleBufferRef)copySampleBufferFromFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
                                    targetSize:(CGSize)targetSize {
  // Build on top of pixel-buffer conversion so format handling remains unified.
  CVPixelBufferRef pixelBuffer = [self copyPixelBufferFromFrame:frame
                                                      targetSize:targetSize];
  if (!pixelBuffer) {
    return nil;
  }

  // A format description is mandatory to wrap an image buffer in a sample
  // buffer that AVSampleBufferDisplayLayer can decode/render.
  CMFormatDescriptionRef formatDescription = nil;
  OSStatus formatStatus =
      CMVideoFormatDescriptionCreateForImageBuffer(
          kCFAllocatorDefault,
          pixelBuffer,
          &formatDescription);
  if (formatStatus != noErr || !formatDescription) {
    CVBufferRelease(pixelBuffer);
    return nil;
  }

  // Preserve frame timestamp so rendering order/timing stays consistent.
  // Duration/decode TS are unknown in this display-only path.
  CMSampleTimingInfo timingInfo = {
      .duration = kCMTimeInvalid,
      .presentationTimeStamp = CMTimeMake(frame.timeStampNs, 1000000000),
      .decodeTimeStamp = kCMTimeInvalid};

  CMSampleBufferRef sampleBuffer = nil;
  OSStatus sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
      kCFAllocatorDefault,
      pixelBuffer,
      formatDescription,
      &timingInfo,
      &sampleBuffer);

  CFRelease(formatDescription);
  CVBufferRelease(pixelBuffer);

  if (sampleStatus != noErr || !sampleBuffer) {
    return nil;
  }

  // Hint immediate display for live rendering scenarios (PiP/live call),
  // reducing display latency compared to decode scheduling semantics.
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, true);
  if (attachments && CFArrayGetCount(attachments) > 0) {
    CFMutableDictionaryRef dictionary = static_cast<CFMutableDictionaryRef>(
        const_cast<void*>(CFArrayGetValueAtIndex(attachments, 0)));
    CFDictionarySetValue(dictionary,
                         kCMSampleAttachmentKey_DisplayImmediately,
                         kCFBooleanTrue);
  }

  return sampleBuffer;
}

#pragma mark - Private

- (id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)>)maybeScaleBuffer:
            (id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)>)buffer
                                             targetSize:(CGSize)targetSize {
  // Scaling is opportunistic:
  // - If unsupported by this buffer type, return original buffer untouched.
  // - This keeps the converter compatible with arbitrary custom buffers.
  if (!buffer ||
      ![buffer respondsToSelector:@selector(cropAndScaleWith:offsetY:cropWidth:
                                              cropHeight:scaleWidth:scaleHeight:)]) {
    return buffer;
  }

  int sourceWidth = buffer.width;
  int sourceHeight = buffer.height;
  int targetWidth = std::max(1, static_cast<int>(targetSize.width));
  int targetHeight = std::max(1, static_cast<int>(targetSize.height));

  if (sourceWidth == targetWidth && sourceHeight == targetHeight) {
    return buffer;
  }

  // Scale full source frame to target output dimensions.
  // We don't crop content here; caller controls layout policy externally.
  id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> scaledBuffer =
      [buffer cropAndScaleWith:0
                       offsetY:0
                     cropWidth:sourceWidth
                    cropHeight:sourceHeight
                    scaleWidth:targetWidth
                   scaleHeight:targetHeight];
  return scaledBuffer ?: buffer;
}

- (CVPixelBufferRef)copyPixelBufferFromFrameBuffer:
    (id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)>)buffer {
  if (!buffer) {
    return nil;
  }

  // Unified API access:
  // `pixelBuffer` is optional on RTCVideoFrameBuffer; use it when available.
  // Retain before returning to make ownership explicit to the caller.
  if ([buffer respondsToSelector:@selector(pixelBuffer)]) {
    CVPixelBufferRef pixelBuffer = buffer.pixelBuffer;
    if (pixelBuffer) {
      CVBufferRetain(pixelBuffer);
      return pixelBuffer;
    }
  }

  return nil;
}

- (CVPixelBufferRef)copyPixelBufferFromI420Buffer:
    (id<RTC_OBJC_TYPE(RTCI420Buffer)>)i420Buffer {
  if (!i420Buffer) {
    return nil;
  }

  // Some I420 implementations may already expose a cached/derived CVPixelBuffer.
  // Prefer that to avoid redundant conversion work.
  id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> frameBuffer =
      (id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)>)i420Buffer;
  if ([frameBuffer respondsToSelector:@selector(pixelBuffer)]) {
    CVPixelBufferRef nativePixelBuffer = frameBuffer.pixelBuffer;
    if (nativePixelBuffer) {
      CVBufferRetain(nativePixelBuffer);
      return nativePixelBuffer;
    }
  }

  int width = i420Buffer.width;
  int height = i420Buffer.height;
  // Get a destination NV12 pixel buffer (pool-backed when possible).
  CVPixelBufferRef pixelBuffer =
      [self copyOrCreatePixelBufferWithWidth:width height:height];
  if (!pixelBuffer) {
    return nil;
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, 0);

  uint8_t* dstY =
      static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
  uint8_t* dstUV =
      static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
  if (!dstY || !dstUV) {
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CVBufferRelease(pixelBuffer);
    return nil;
  }

  int dstStrideY =
      static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0));
  int dstStrideUV =
      static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1));

  // Conversion target is NV12 because:
  // - It's supported by AVSampleBufferDisplayLayer.
  // - It maps efficiently to iOS video render/decode paths.
  int result = libyuv::I420ToNV12(
      i420Buffer.dataY,
      i420Buffer.strideY,
      i420Buffer.dataU,
      i420Buffer.strideU,
      i420Buffer.dataV,
      i420Buffer.strideV,
      dstY,
      dstStrideY,
      dstUV,
      dstStrideUV,
      width,
      height);

  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

  if (result != 0) {
    CVBufferRelease(pixelBuffer);
    return nil;
  }

  return pixelBuffer;
}

- (CVPixelBufferRef)copyOrCreatePixelBufferWithWidth:(int)width
                                               height:(int)height {
  if (width <= 0 || height <= 0) {
    return nil;
  }

  CVPixelBufferRef pixelBuffer = nil;

  @synchronized(self) {
    // Keep pool in sync with output dimensions.
    // Reusing pool improves throughput and reduces allocation jitter.
    [self ensurePoolWithWidth:width height:height];
    if (_pixelBufferPool) {
      CVReturn result = CVPixelBufferPoolCreatePixelBuffer(
          kCFAllocatorDefault,
          _pixelBufferPool,
          &pixelBuffer);
      if (result == kCVReturnSuccess && pixelBuffer) {
        return pixelBuffer;
      }
    }
  }

  NSDictionary* attributes =
      @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
  // If pool allocation fails (pressure/creation failure), fallback to direct
  // one-off allocation so rendering can continue.
  CVReturn createResult = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      (__bridge CFDictionaryRef)attributes,
      &pixelBuffer);
  if (createResult != kCVReturnSuccess) {
    return nil;
  }

  return pixelBuffer;
}

- (void)ensurePoolWithWidth:(int)width height:(int)height {
  // Fast no-op when the existing pool already matches target dimensions.
  if (_pixelBufferPool && _poolWidth == width && _poolHeight == height) {
    return;
  }

  // Replace pool when size changes. Old pool is released after outstanding
  // buffers are returned by CF ownership semantics.
  if (_pixelBufferPool) {
    CVPixelBufferPoolRelease(_pixelBufferPool);
    _pixelBufferPool = nil;
  }

  _poolWidth = width;
  _poolHeight = height;

  // Keep a small prewarmed pool. PiP renderer is single-stream, so 2 is enough
  // to reduce churn while avoiding unnecessary memory retention.
  NSDictionary* poolAttributes =
      @{(id)kCVPixelBufferPoolMinimumBufferCountKey : @2};
  NSDictionary* pixelBufferAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };

  CVPixelBufferPoolCreate(kCFAllocatorDefault,
                          (__bridge CFDictionaryRef)poolAttributes,
                          (__bridge CFDictionaryRef)pixelBufferAttributes,
                          &_pixelBufferPool);
}

@end

#endif
