/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCNativeNV12Buffer+Private.h"
#import "RTCNativeI420Buffer+Private.h"

#include <algorithm>
#include <cstring>

#include "api/video/nv12_buffer.h"

@implementation RTC_OBJC_TYPE(RTCNV12Buffer) {
  CVPixelBufferRef _pixelBuffer;
}

- (instancetype)initWithWidth:(int)width height:(int)height {
  self = [super init];
  if (self) {
    _nv12Buffer = webrtc::NV12Buffer::Create(width, height);
  }
  return self;
}

- (instancetype)initWithWidth:(int)width
                       height:(int)height
                      strideY:(int)strideY
                     strideUV:(int)strideUV {
  self = [super init];
  if (self) {
    _nv12Buffer =
        webrtc::NV12Buffer::Create(width, height, strideY, strideUV);
  }
  return self;
}

- (instancetype)initWithFrameBuffer:
    (webrtc::scoped_refptr<webrtc::NV12BufferInterface>)nv12Buffer {
  self = [super init];
  if (self) {
    _nv12Buffer = nv12Buffer;
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
  return _nv12Buffer->width();
}

- (int)height {
  return _nv12Buffer->height();
}

- (int)strideY {
  return _nv12Buffer->StrideY();
}

- (int)strideUV {
  return _nv12Buffer->StrideUV();
}

- (int)chromaWidth {
  return _nv12Buffer->ChromaWidth();
}

- (int)chromaHeight {
  return _nv12Buffer->ChromaHeight();
}

- (const uint8_t *)dataY {
  return _nv12Buffer->DataY();
}

- (const uint8_t *)dataUV {
  return _nv12Buffer->DataUV();
}

- (CVPixelBufferRef)pixelBuffer {
  // Cache generated pixel buffer to avoid repeated plane copies for same frame
  // buffer instance.
  if (_pixelBuffer || !_nv12Buffer) {
    return _pixelBuffer;
  }

  const int width = _nv12Buffer->width();
  const int height = _nv12Buffer->height();
  if (width <= 0 || height <= 0) {
    return nil;
  }

  NSDictionary *attributes =
      @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
  // Preserve NV12 format end-to-end to avoid unnecessary color space/layout
  // transformations.
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

  // Copy Y and UV planes row-by-row to honor source/destination stride
  // differences.
  const int dst_stride_y =
      static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(_pixelBuffer, 0));
  const int dst_stride_uv =
      static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(_pixelBuffer, 1));
  const int src_stride_y = _nv12Buffer->StrideY();
  const int src_stride_uv = _nv12Buffer->StrideUV();
  const int y_row_bytes = std::min(width, std::min(src_stride_y, dst_stride_y));
  const int uv_row_bytes = std::min(width + width % 2,
                                    std::min(src_stride_uv, dst_stride_uv));

  const uint8_t *src_y = _nv12Buffer->DataY();
  const uint8_t *src_uv = _nv12Buffer->DataUV();

  for (int row = 0; row < height; ++row) {
    memcpy(dst_y + row * dst_stride_y, src_y + row * src_stride_y, y_row_bytes);
  }

  const int uv_rows = (height + 1) / 2;
  for (int row = 0; row < uv_rows; ++row) {
    memcpy(dst_uv + row * dst_stride_uv,
           src_uv + row * src_stride_uv,
           uv_row_bytes);
  }

  CVPixelBufferUnlockBaseAddress(_pixelBuffer, 0);
  return _pixelBuffer;
}

- (id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)>)cropAndScaleWith:(int)offsetX
                                                   offsetY:(int)offsetY
                                                 cropWidth:(int)cropWidth
                                                 cropHeight:(int)cropHeight
                                                 scaleWidth:(int)scaleWidth
                                               scaleHeight:(int)scaleHeight {
  // Validate early so callers can use this API in hot render paths without
  // worrying about throwing/assert behavior.
  if (!_nv12Buffer || scaleWidth <= 0 || scaleHeight <= 0 || cropWidth <= 0 ||
      cropHeight <= 0) {
    return nil;
  }

  const int source_width = _nv12Buffer->width();
  const int source_height = _nv12Buffer->height();
  if (source_width <= 0 || source_height <= 0) {
    return nil;
  }

  // NV12 chroma is 2x2 subsampled; align crop offsets to even boundaries.
  const int max_offset_x = std::max(0, source_width - 1);
  const int max_offset_y = std::max(0, source_height - 1);
  const int adjusted_offset_x = std::max(0, std::min(offsetX, max_offset_x)) & ~1;
  const int adjusted_offset_y = std::max(0, std::min(offsetY, max_offset_y)) & ~1;

  const int max_crop_width = source_width - adjusted_offset_x;
  const int max_crop_height = source_height - adjusted_offset_y;
  const int adjusted_crop_width = std::max(1, std::min(cropWidth, max_crop_width));
  const int adjusted_crop_height =
      std::max(1, std::min(cropHeight, max_crop_height));

  webrtc::scoped_refptr<webrtc::NV12Buffer> scaled_buffer =
      webrtc::NV12Buffer::Create(scaleWidth, scaleHeight);
  if (!scaled_buffer) {
    return nil;
  }

  // Reuse WebRTC's native NV12 crop/scale implementation for consistency with
  // other renderers and codec paths.
  scaled_buffer->CropAndScaleFrom(*_nv12Buffer,
                                  adjusted_offset_x,
                                  adjusted_offset_y,
                                  adjusted_crop_width,
                                  adjusted_crop_height);

  RTC_OBJC_TYPE(RTCNV12Buffer) *result =
      [[RTC_OBJC_TYPE(RTCNV12Buffer) alloc] initWithFrameBuffer:scaled_buffer];
  return result;
}

- (id<RTC_OBJC_TYPE(RTCI420Buffer)>)toI420 {
  webrtc::scoped_refptr<webrtc::I420BufferInterface> buffer =
      _nv12Buffer->ToI420();
  RTC_OBJC_TYPE(RTCI420Buffer) *result =
      [[RTC_OBJC_TYPE(RTCI420Buffer) alloc] initWithFrameBuffer:buffer];
  return result;
}

#pragma mark - Private

- (webrtc::scoped_refptr<webrtc::NV12BufferInterface>)nativeNV12Buffer {
  return _nv12Buffer;
}

@end
