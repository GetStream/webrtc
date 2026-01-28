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

#include "api/video/nv12_buffer.h"

@implementation RTC_OBJC_TYPE(RTCNV12Buffer)

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
