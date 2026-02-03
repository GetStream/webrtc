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

#import "RTCVideoFrameBuffer.h"
#import "sdk/objc/base/RTCMacros.h"

NS_ASSUME_NONNULL_BEGIN

/** Protocol for RTCVideoFrameBuffers containing NV12 data. */
RTC_OBJC_EXPORT
@protocol RTC_OBJC_TYPE(RTCNV12Buffer)<RTC_OBJC_TYPE(RTCVideoFrameBuffer)>

@property(nonatomic, readonly) int chromaWidth;
@property(nonatomic, readonly) int chromaHeight;
@property(nonatomic, readonly) const uint8_t *dataY;
@property(nonatomic, readonly) const uint8_t *dataUV;
@property(nonatomic, readonly) int strideY;
@property(nonatomic, readonly) int strideUV;

@end

NS_ASSUME_NONNULL_END
