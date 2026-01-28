/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCSharedMetalRenderingContext.h"

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) ()

@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, readonly) id<MTLCommandQueue> commandQueue;
@property(nonatomic, readonly) CVMetalTextureCacheRef textureCache;
@property(nonatomic, readonly) id<MTLRenderPipelineState> nv12PipelineState;
@property(nonatomic, readonly) id<MTLRenderPipelineState> i420PipelineState;
@property(nonatomic, readonly) id<MTLRenderPipelineState> bgraPipelineState;

@end

NS_ASSUME_NONNULL_END
