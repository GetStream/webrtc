/*
 *  Copyright 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCNativeI420Buffer+Private.h"

#include "api/video/i420_buffer.h"
#include "third_party/libyuv/include/libyuv/convert.h"

#if !defined(NDEBUG) && defined(WEBRTC_IOS)
#import <UIKit/UIKit.h>
#include "third_party/libyuv/include/libyuv.h"
#endif

@implementation RTC_OBJC_TYPE (RTCI420Buffer) {
  CVPixelBufferRef _pixelBuffer;
}

- (instancetype)initWithWidth:(int)width height:(int)height {
  self = [super init];
  if (self) {
    _i420Buffer = webrtc::I420Buffer::Create(width, height);
  }
  return self;
}

- (instancetype)initWithWidth:(int)width
                       height:(int)height
                        dataY:(const uint8_t *)dataY
                        dataU:(const uint8_t *)dataU
                        dataV:(const uint8_t *)dataV {
  self = [super init];
  if (self) {
    _i420Buffer = webrtc::I420Buffer::Copy(width,
                                           height,
                                           dataY,
                                           width,
                                           dataU,
                                           (width + 1) / 2,
                                           dataV,
                                           (width + 1) / 2);
  }
  return self;
}

- (instancetype)initWithWidth:(int)width
                       height:(int)height
                      strideY:(int)strideY
                      strideU:(int)strideU
                      strideV:(int)strideV {
  self = [super init];
  if (self) {
    _i420Buffer =
        webrtc::I420Buffer::Create(width, height, strideY, strideU, strideV);
  }
  return self;
}

- (instancetype)initWithFrameBuffer:
    (webrtc::scoped_refptr<webrtc::I420BufferInterface>)i420Buffer {
  self = [super init];
  if (self) {
    _i420Buffer = i420Buffer;
  }
  return self;
}

- (void)dealloc {
  if (_pixelBuffer) {
    CVBufferRelease(_pixelBuffer);
    _pixelBuffer = nil;
  }
}

- (int)width {
  return _i420Buffer->width();
}

- (int)height {
  return _i420Buffer->height();
}

- (int)strideY {
  return _i420Buffer->StrideY();
}

- (int)strideU {
  return _i420Buffer->StrideU();
}

- (int)strideV {
  return _i420Buffer->StrideV();
}

- (int)chromaWidth {
  return _i420Buffer->ChromaWidth();
}

- (int)chromaHeight {
  return _i420Buffer->ChromaHeight();
}

- (const uint8_t *)dataY {
  return _i420Buffer->DataY();
}

- (const uint8_t *)dataU {
  return _i420Buffer->DataU();
}

- (const uint8_t *)dataV {
  return _i420Buffer->DataV();
}

- (CVPixelBufferRef)pixelBuffer {
  // Cache conversion result because PiP/converter may request pixel buffer
  // repeatedly for consecutive frames with same backing buffer instance.
  if (_pixelBuffer || !_i420Buffer) {
    return _pixelBuffer;
  }

  const int width = _i420Buffer->width();
  const int height = _i420Buffer->height();
  if (width <= 0 || height <= 0) {
    return nil;
  }

  NSDictionary *attributes =
      @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
  // Export as NV12 because this is the common hardware-friendly format used by
  // AVFoundation rendering pipelines.
  CVReturn result = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      (__bridge CFDictionaryRef)attributes,
      &_pixelBuffer);
  if (result != kCVReturnSuccess || !_pixelBuffer) {
    return nil;
  }

  CVPixelBufferLockBaseAddress(_pixelBuffer, 0);
  uint8_t *dst_y = static_cast<uint8_t *>(
      CVPixelBufferGetBaseAddressOfPlane(_pixelBuffer, 0));
  uint8_t *dst_uv = static_cast<uint8_t *>(
      CVPixelBufferGetBaseAddressOfPlane(_pixelBuffer, 1));
  if (!dst_y || !dst_uv) {
    CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
    CVBufferRelease(_pixelBuffer);
    _pixelBuffer = nil;
    return nil;
  }

  const int dst_stride_y =
      static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(_pixelBuffer, 0));
  const int dst_stride_uv =
      static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(_pixelBuffer, 1));

  // Convert I420 planes to NV12 plane layout into the destination pixel buffer.
  const int conversion_result = libyuv::I420ToNV12(
      _i420Buffer->DataY(),
      _i420Buffer->StrideY(),
      _i420Buffer->DataU(),
      _i420Buffer->StrideU(),
      _i420Buffer->DataV(),
      _i420Buffer->StrideV(),
      dst_y,
      dst_stride_y,
      dst_uv,
      dst_stride_uv,
      width,
      height);

  CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);

  if (conversion_result != 0) {
    CVBufferRelease(_pixelBuffer);
    _pixelBuffer = nil;
    return nil;
  }

  return _pixelBuffer;
}

- (id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)>)cropAndScaleWith:(int)offsetX
                                                   offsetY:(int)offsetY
                                                 cropWidth:(int)cropWidth
                                                 cropHeight:(int)cropHeight
                                                 scaleWidth:(int)scaleWidth
                                               scaleHeight:(int)scaleHeight {
  // Keep behavior aligned with WebRTC frame buffer contract:
  // crop/scale returns another frame buffer representation of same family.
  webrtc::scoped_refptr<webrtc::VideoFrameBuffer> scaled_buffer =
      _i420Buffer->CropAndScale(
          offsetX, offsetY, cropWidth, cropHeight, scaleWidth, scaleHeight);
  RTC_DCHECK_EQ(scaled_buffer->type(), webrtc::VideoFrameBuffer::Type::kI420);
  // Calling ToI420() doesn't do any conversions.
  webrtc::scoped_refptr<webrtc::I420BufferInterface> buffer =
      scaled_buffer->ToI420();
  RTC_OBJC_TYPE(RTCI420Buffer) *result =
      [[RTC_OBJC_TYPE(RTCI420Buffer) alloc] initWithFrameBuffer:buffer];
  return result;
}

- (id<RTC_OBJC_TYPE(RTCI420Buffer)>)toI420 {
  return self;
}

#pragma mark - Private

- (webrtc::scoped_refptr<webrtc::I420BufferInterface>)nativeI420Buffer {
  return _i420Buffer;
}

#pragma mark - Debugging

#if !defined(NDEBUG) && defined(WEBRTC_IOS)
- (id)debugQuickLookObject {
  UIGraphicsBeginImageContext(
      CGSizeMake(_i420Buffer->width(), _i420Buffer->height()));
  CGContextRef c = UIGraphicsGetCurrentContext();
  uint8_t *ctxData = (uint8_t *)CGBitmapContextGetData(c);

  libyuv::I420ToARGB(_i420Buffer->DataY(),
                     _i420Buffer->StrideY(),
                     _i420Buffer->DataU(),
                     _i420Buffer->StrideU(),
                     _i420Buffer->DataV(),
                     _i420Buffer->StrideV(),
                     ctxData,
                     CGBitmapContextGetBytesPerRow(c),
                     CGBitmapContextGetWidth(c),
                     CGBitmapContextGetHeight(c));

  UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();

  return image;
}
#endif

@end
