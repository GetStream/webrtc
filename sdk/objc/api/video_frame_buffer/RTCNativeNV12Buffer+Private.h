/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCNativeNV12Buffer.h"

#include "api/video/video_frame_buffer.h"

NS_ASSUME_NONNULL_BEGIN

@interface RTC_OBJC_TYPE(RTCNV12Buffer) () {
 @protected
  webrtc::scoped_refptr<webrtc::NV12BufferInterface> _nv12Buffer;
}

/** Initialize an RTCNV12Buffer with its backing NV12BufferInterface. */
- (instancetype)initWithFrameBuffer:
    (webrtc::scoped_refptr<webrtc::NV12BufferInterface>)nv12Buffer;
- (webrtc::scoped_refptr<webrtc::NV12BufferInterface>)nativeNV12Buffer;

@end

NS_ASSUME_NONNULL_END
