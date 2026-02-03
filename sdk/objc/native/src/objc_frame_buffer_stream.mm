/*
 *  Copyright 2017 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

// Stream-specific alternate implementation that supports NV12 policies.
// This file is only compiled when stream_enable_rendering_backend is enabled.
// It keeps the default objc_frame_buffer.mm untouched and swaps at build time.

#include "sdk/objc/native/src/objc_frame_buffer.h"

// Ref-count helper for wrapping ObjC buffers into WebRTC interfaces.
#include "api/make_ref_counted.h"
// NV12 buffer type used when we choose to wrap or convert.
#include "api/video/nv12_buffer.h"
// Pool used by the pooled conversion policy to avoid per-frame allocs.
#include "common_video/include/video_frame_buffer_pool.h"
// Conversion helper for I420 -> NV12 when using the pooled path.
#include "third_party/libyuv/include/libyuv/convert.h"
#include <cstring>
#import <CoreVideo/CoreVideo.h>
#import "base/RTCVideoFrameBuffer.h"
#import "sdk/objc/api/video_frame_buffer/RTCNativeI420Buffer+Private.h"
#import "sdk/objc/api/video_frame_buffer/RTCNativeNV12Buffer+Private.h"
#import "sdk/objc/components/video_frame_buffer/RTCCVPixelBuffer.h"
#include "sdk/objc/native/src/objc_nv12_conversion.h"

namespace webrtc {

namespace {
// Avoid NV12 conversion for tiny frames where the overhead is not worth it.
constexpr int kMinNV12ConversionPixels = 64 * 64;

/** ObjCFrameBuffer that conforms to I420BufferInterface by wrapping
 * RTC_OBJC_TYPE(RTCI420Buffer) */
class ObjCI420FrameBuffer : public I420BufferInterface {
 public:
  // Stores the ObjC buffer and caches dimensions for quick access.
  explicit ObjCI420FrameBuffer(id<RTC_OBJC_TYPE(RTCI420Buffer)> frame_buffer)
      : frame_buffer_(frame_buffer),
        width_(frame_buffer.width),
        height_(frame_buffer.height) {}
  ~ObjCI420FrameBuffer() override {}

  // WebRTC expects dimensions without rotation.
  int width() const override { return width_; }

  int height() const override { return height_; }

  // Forward plane pointers and strides to the ObjC buffer.
  const uint8_t* DataY() const override { return frame_buffer_.dataY; }

  const uint8_t* DataU() const override { return frame_buffer_.dataU; }

  const uint8_t* DataV() const override { return frame_buffer_.dataV; }

  int StrideY() const override { return frame_buffer_.strideY; }

  int StrideU() const override { return frame_buffer_.strideU; }

  int StrideV() const override { return frame_buffer_.strideV; }

 private:
  id<RTC_OBJC_TYPE(RTCI420Buffer)> frame_buffer_;
  int width_;
  int height_;
};

webrtc::scoped_refptr<webrtc::NV12BufferInterface> CreateNV12FromCVPixelBuffer(
    CVPixelBufferRef pixelBuffer,
    bool use_pool) {
  // Only NV12 CVPixelBuffers can be wrapped/copied into an NV12Buffer.
  if (!pixelBuffer) {
    return nullptr;
  }

  const OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
  if (format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
      format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
    return nullptr;
  }

  // Validate dimensions to avoid creating invalid buffers.
  const int width = static_cast<int>(CVPixelBufferGetWidth(pixelBuffer));
  const int height = static_cast<int>(CVPixelBufferGetHeight(pixelBuffer));
  if (width <= 0 || height <= 0) {
    return nullptr;
  }

  webrtc::scoped_refptr<webrtc::NV12Buffer> nv12;
  if (use_pool) {
    // Thread-local pool avoids per-frame allocations on the hot path.
    // The pool is intentionally leaked to avoid shutdown order issues.
    thread_local webrtc::VideoFrameBufferPool* nv12_pool =
        new webrtc::VideoFrameBufferPool();
    nv12 = nv12_pool->CreateNV12Buffer(width, height);
  } else {
    // Simple path: allocate a fresh NV12 buffer for this frame.
    nv12 = webrtc::NV12Buffer::Create(width, height);
  }

  if (!nv12) {
    return nullptr;
  }

  // Copy Y/UV planes into the new NV12 buffer.
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  const uint8_t* src_y = static_cast<const uint8_t*>(
      CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
  const uint8_t* src_uv = static_cast<const uint8_t*>(
      CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
  if (!src_y || !src_uv) {
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    return nullptr;
  }
  const size_t src_stride_y =
      CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
  const size_t src_stride_uv =
      CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

  uint8_t* dst_y = nv12->MutableDataY();
  uint8_t* dst_uv = nv12->MutableDataUV();
  const int dst_stride_y = nv12->StrideY();
  const int dst_stride_uv = nv12->StrideUV();

  // NV12 expects full-width Y and UV rows.
  const size_t y_row_bytes = static_cast<size_t>(width);
  const size_t uv_row_bytes = static_cast<size_t>(width);

  // Copy each plane row-by-row to honor differing strides.
  for (int row = 0; row < height; row++) {
    memcpy(dst_y + row * dst_stride_y,
           src_y + row * src_stride_y,
           y_row_bytes);
  }

  const int uv_rows = height / 2;
  for (int row = 0; row < uv_rows; row++) {
    memcpy(dst_uv + row * dst_stride_uv,
           src_uv + row * src_stride_uv,
           uv_row_bytes);
  }

  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  return nv12;
}

}  // namespace

// Wraps the ObjC buffer and snapshots its size.
ObjCFrameBuffer::ObjCFrameBuffer(
    id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> frame_buffer)
    : frame_buffer_(frame_buffer),
      width_(frame_buffer.width),
      height_(frame_buffer.height) {}

ObjCFrameBuffer::~ObjCFrameBuffer() {}

VideoFrameBuffer::Type ObjCFrameBuffer::type() const {
  // Native means we own an ObjC-backed buffer wrapper.
  return Type::kNative;
}

int ObjCFrameBuffer::width() const {
  return width_;
}

int ObjCFrameBuffer::height() const {
  return height_;
}

webrtc::scoped_refptr<I420BufferInterface> ObjCFrameBuffer::ToI420() {
  // Wrap the ObjC I420 buffer without copying.
  return webrtc::make_ref_counted<ObjCI420FrameBuffer>([frame_buffer_ toI420]);
}

webrtc::scoped_refptr<VideoFrameBuffer> ObjCFrameBuffer::CropAndScale(
    int offset_x,
    int offset_y,
    int crop_width,
    int crop_height,
    int scaled_width,
    int scaled_height) {
  // Prefer ObjC buffer's crop/scale if it implements it.
  if ([frame_buffer_
          respondsToSelector:@selector
          (cropAndScaleWith:
                    offsetY:cropWidth:cropHeight:scaleWidth:scaleHeight:)]) {
    return webrtc::make_ref_counted<ObjCFrameBuffer>([frame_buffer_
        cropAndScaleWith:offset_x
                 offsetY:offset_y
               cropWidth:crop_width
              cropHeight:crop_height
              scaleWidth:scaled_width
             scaleHeight:scaled_height]);
  }

  // Fall back to WebRTC's default crop/scale path.
  return VideoFrameBuffer::CropAndScale(
      offset_x, offset_y, crop_width, crop_height, scaled_width, scaled_height);
}

id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> ObjCFrameBuffer::wrapped_frame_buffer()
    const {
  // Expose the original ObjC buffer for native unwraps.
  return frame_buffer_;
}

id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> ToObjCVideoFrameBuffer(
    const webrtc::scoped_refptr<VideoFrameBuffer>& buffer) {
  // Preserve already-wrapped ObjC buffers to avoid extra bridging.
  if (buffer->type() == VideoFrameBuffer::Type::kNative) {
    id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> wrapped =
        static_cast<ObjCFrameBuffer*>(buffer.get())->wrapped_frame_buffer();
    const auto policy = webrtc::ObjCGetFrameBufferPolicy();
    // Only convert CVPixelBuffer when policy explicitly requests it.
    if ((policy == webrtc::ObjCFrameBufferPolicy::kCopyToNV12 ||
         policy == webrtc::ObjCFrameBufferPolicy::kConvertWithPoolToNV12) &&
        [wrapped isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
      RTC_OBJC_TYPE(RTCCVPixelBuffer) *cv_buffer =
          (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)wrapped;
      const bool use_pool =
          policy == webrtc::ObjCFrameBufferPolicy::kConvertWithPoolToNV12;
      webrtc::scoped_refptr<webrtc::NV12BufferInterface> nv12_buffer =
          CreateNV12FromCVPixelBuffer(cv_buffer.pixelBuffer, use_pool);
      if (nv12_buffer) {
        RTC_OBJC_TYPE(RTCNV12Buffer) *result =
            [[RTC_OBJC_TYPE(RTCNV12Buffer) alloc]
                initWithFrameBuffer:nv12_buffer];
        return result;
      }
    }
    return wrapped;
  } else if (buffer->type() == VideoFrameBuffer::Type::kNV12) {
    // NV12 frames can be wrapped directly unless policy forbids NV12.
    if (webrtc::ObjCGetFrameBufferPolicy() ==
        webrtc::ObjCFrameBufferPolicy::kNone) {
      // Explicitly force I420 when policy is "none".
      return [[RTC_OBJC_TYPE(RTCI420Buffer) alloc]
          initWithFrameBuffer:buffer->ToI420()];
    }
    // GetNV12 returns a const pointer; underlying buffer is ref-counted.
    webrtc::scoped_refptr<webrtc::NV12BufferInterface> nv12_buffer(
        const_cast<webrtc::NV12BufferInterface*>(buffer->GetNV12()));
    // Wrap NV12 without copying for GPU-friendly consumption.
    RTC_OBJC_TYPE(RTCNV12Buffer) *result =
        [[RTC_OBJC_TYPE(RTCNV12Buffer) alloc]
            initWithFrameBuffer:nv12_buffer];
    return result;
  } else {
    // Non-NV12 input; policy decides if we should convert to NV12 or keep I420.
    const auto policy = webrtc::ObjCGetFrameBufferPolicy();
    if (policy == webrtc::ObjCFrameBufferPolicy::kNone ||
        policy == webrtc::ObjCFrameBufferPolicy::kWrapOnlyExistingNV12) {
      // Either no NV12 allowed or we only wrap existing NV12 buffers.
      return [[RTC_OBJC_TYPE(RTCI420Buffer) alloc]
          initWithFrameBuffer:buffer->ToI420()];
    }
    // Convert to I420 first, then potentially to NV12.
    webrtc::scoped_refptr<webrtc::I420BufferInterface> i420_buffer =
        buffer->ToI420();
    if (!i420_buffer) {
      return nil;
    }

    const int width = i420_buffer->width();
    const int height = i420_buffer->height();
    // Avoid conversion for very small frames to save overhead.
    if (width * height < kMinNV12ConversionPixels) {
      return [[RTC_OBJC_TYPE(RTCI420Buffer) alloc]
          initWithFrameBuffer:i420_buffer];
    }

    webrtc::scoped_refptr<webrtc::NV12BufferInterface> nv12_buffer;
    if (policy == webrtc::ObjCFrameBufferPolicy::kCopyToNV12) {
      // Simple path: let WebRTC allocate and copy.
      nv12_buffer = webrtc::NV12Buffer::Copy(*i420_buffer);
    } else {
      // Pooled path: reuse NV12 buffers and convert via libyuv.
      thread_local webrtc::VideoFrameBufferPool* nv12_pool =
          new webrtc::VideoFrameBufferPool();
      webrtc::scoped_refptr<webrtc::NV12Buffer> pooled =
          nv12_pool->CreateNV12Buffer(width, height);
      if (pooled) {
        // Convert planar I420 to bi-planar NV12 in-place.
        libyuv::I420ToNV12(i420_buffer->DataY(), i420_buffer->StrideY(),
                           i420_buffer->DataU(), i420_buffer->StrideU(),
                           i420_buffer->DataV(), i420_buffer->StrideV(),
                           pooled->MutableDataY(), pooled->StrideY(),
                           pooled->MutableDataUV(), pooled->StrideUV(),
                           width, height);
        nv12_buffer = pooled;
      }
    }

    if (!nv12_buffer) {
      // If conversion failed, fall back to I420.
      return [[RTC_OBJC_TYPE(RTCI420Buffer) alloc]
          initWithFrameBuffer:i420_buffer];
    }
    // Wrap the converted NV12 buffer for ObjC consumption.
    RTC_OBJC_TYPE(RTCNV12Buffer) *result =
        [[RTC_OBJC_TYPE(RTCNV12Buffer) alloc]
            initWithFrameBuffer:nv12_buffer];
    return result;
  }
}

}  // namespace webrtc
