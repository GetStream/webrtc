/*
 *  Copyright 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCSharedMetalRenderAdapter.h"

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#import "RTCSharedMetalRenderingContext+Private.h"
#import "base/RTCLogging.h"
#import "components/video_frame_buffer/RTCCVPixelBuffer.h"
#import "sdk/objc/base/RTCI420Buffer.h"
#import "sdk/objc/base/RTCNV12Buffer.h"

@implementation RTC_OBJC_TYPE(RTCSharedMetalRenderAdapter) {
  dispatch_queue_t _frameQueue;
  RTC_OBJC_TYPE(RTCVideoFrame) *_latestFrame;
  BOOL _needsRedraw;
  UIViewContentMode _contentMode;
  NSInteger _inFlightFrames;
  NSInteger _maxInFlightFrames;
  BOOL _didLogI420Fallback;
  BOOL _didLogI420FallbackFailure;

  id<MTLBuffer> _vertexBuffer;

  id<MTLTexture> _i420YTexture;
  id<MTLTexture> _i420UTexture;
  id<MTLTexture> _i420VTexture;
  CGSize _i420TextureSize;

  id<MTLTexture> _nv12YTexture;
  id<MTLTexture> _nv12UVTexture;
  CGSize _nv12TextureSize;
}

- (instancetype)initWithContext:
    (RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) *)context {
  self = [super init];
  if (self) {
    _frameQueue = dispatch_queue_create(
        "webrtc.sharedmetal.frames", DISPATCH_QUEUE_SERIAL);
    _contentMode = UIViewContentModeScaleAspectFill;
    _maxInFlightFrames = 0;

    _vertexBuffer =
        [context.device newBufferWithLength:16 * sizeof(float)
                                    options:MTLResourceCPUCacheModeWriteCombined];
    if (!_vertexBuffer) {
      RTCLogError(@"SharedMetal: Failed to create vertex buffer");
      return nil;
    }
  }
  return self;
}

- (void)renderFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  dispatch_sync(_frameQueue, ^{
    RTC_OBJC_TYPE(RTCVideoFrame) *frameToStore = frame;
    if (frameToStore &&
        [frameToStore.buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
      RTC_OBJC_TYPE(RTCCVPixelBuffer) *pixelBuffer =
          (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)frameToStore.buffer;
      const OSType pixelFormat =
          CVPixelBufferGetPixelFormatType(pixelBuffer.pixelBuffer);
      if (pixelFormat == kCVPixelFormatType_32BGRA ||
          pixelFormat == kCVPixelFormatType_32ARGB) {
        RTC_OBJC_TYPE(RTCVideoFrame) *i420Frame =
            [frameToStore newI420VideoFrame];
        if (i420Frame) {
          frameToStore = i420Frame;
          if (!self->_didLogI420Fallback) {
            self->_didLogI420Fallback = YES;
            RTCLogInfo(@"SharedMetal: Falling back to I420 for BGRA/ARGB frames.");
          }
        } else if (!self->_didLogI420FallbackFailure) {
          self->_didLogI420FallbackFailure = YES;
          RTCLogError(@"SharedMetal: Failed to convert BGRA/ARGB frame to I420.");
        }
      }
    }
    self->_latestFrame = frameToStore;
    self->_needsRedraw = frameToStore != nil;
  });
}

- (BOOL)consumeNeedsRedraw {
  __block BOOL needsRedraw = NO;
  dispatch_sync(_frameQueue, ^{
    if (self->_needsRedraw) {
      self->_needsRedraw = NO;
      needsRedraw = YES;
    }
  });
  return needsRedraw;
}

- (RTC_OBJC_TYPE(RTCVideoFrame) *)consumeFrame {
  __block RTC_OBJC_TYPE(RTCVideoFrame) *frame = nil;
  dispatch_sync(_frameQueue, ^{
    frame = self->_latestFrame;
  });
  return frame;
}

- (void)setContentMode:(UIViewContentMode)contentMode {
  dispatch_sync(_frameQueue, ^{
    self->_contentMode = contentMode;
  });
}

- (void)setMaxInFlightFrames:(NSInteger)maxInFlightFrames {
  dispatch_sync(_frameQueue, ^{
    self->_maxInFlightFrames = MAX(0, maxInFlightFrames);
  });
}

- (BOOL)beginFrameIfPossible {
  __block BOOL canBegin = NO;
  dispatch_sync(_frameQueue, ^{
    if (self->_maxInFlightFrames > 0 &&
        self->_inFlightFrames >= self->_maxInFlightFrames) {
      canBegin = NO;
      return;
    }
    self->_inFlightFrames += 1;
    canBegin = YES;
  });
  return canBegin;
}

- (void)endFrame {
  dispatch_sync(_frameQueue, ^{
    self->_inFlightFrames = MAX(0, self->_inFlightFrames - 1);
  });
}

- (BOOL)encodeFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
           drawable:(id<CAMetalDrawable>)drawable
            context:(RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) *)context
      commandBuffer:(id<MTLCommandBuffer>)commandBuffer
   rotationOverride:(nullable NSValue *)rotationOverride {
  CGSize targetSize = CGSizeMake(drawable.texture.width,
                                 drawable.texture.height);
  RTC_OBJC_TYPE(RTCVideoRotation) rotation = frame.rotation;
  if (rotationOverride) {
    if (@available(iOS 11.0, *)) {
      [rotationOverride getValue:&rotation size:sizeof(rotation)];
    } else {
      [rotationOverride getValue:&rotation];
    }
  }
#if TARGET_OS_SIMULATOR
  if (rotation != RTC_OBJC_TYPE(RTCVideoRotation_0) &&
      [frame.buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
    RTC_OBJC_TYPE(RTCCVPixelBuffer) *pixelBuffer =
        (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)frame.buffer;
    OSType pixelFormat =
        CVPixelBufferGetPixelFormatType(pixelBuffer.pixelBuffer);
    if (pixelFormat == kCVPixelFormatType_32BGRA ||
        pixelFormat == kCVPixelFormatType_32ARGB) {
      rotation = RTC_OBJC_TYPE(RTCVideoRotation_0);
    }
  }
#endif

  MTLRenderPassDescriptor *renderPassDescriptor =
      [[MTLRenderPassDescriptor alloc] init];
  renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
  renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
  renderPassDescriptor.colorAttachments[0].clearColor =
      MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

  id<MTLRenderCommandEncoder> renderEncoder =
      [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
  if (!renderEncoder) {
    RTCLogError(@"SharedMetal: Failed to create render encoder.");
    return NO;
  }

  [renderEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];

  NSMutableArray *textureRefsToRetain = [NSMutableArray array];

  // Supported formats: CVPixelBuffer (NV12/BGRA), NV12, and I420.
  id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> buffer = frame.buffer;
  // Match RTCMTLRenderer's texture mapping to avoid rotation/crop drift.
  [self updateVertexBufferForFrame:frame
                        targetSize:targetSize
                          rotation:rotation
                       contentMode:_contentMode];
  if ([buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
    RTC_OBJC_TYPE(RTCCVPixelBuffer) *pixelBuffer =
        (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)buffer;
    OSType pixelFormat =
        CVPixelBufferGetPixelFormatType(pixelBuffer.pixelBuffer);
    if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
      CVMetalTextureRef yRef = nil;
      CVMetalTextureRef uvRef = nil;
      if (![self updateNV12TexturesFromPixelBuffer:pixelBuffer.pixelBuffer
                                           context:context
                                              yRef:&yRef
                                             uvRef:&uvRef]) {
        RTCLogError(@"SharedMetal: Failed to update NV12 textures from pixel buffer.");
        [renderEncoder endEncoding];
        return NO;
      }
      id<MTLTexture> yTexture = CVMetalTextureGetTexture(yRef);
      id<MTLTexture> uvTexture = CVMetalTextureGetTexture(uvRef);
      if (!yTexture || !uvTexture) {
        RTCLogError(@"SharedMetal: NV12 textures are nil.");
        if (yRef) {
          CFRelease(yRef);
        }
        if (uvRef) {
          CFRelease(uvRef);
        }
        [renderEncoder endEncoding];
        return NO;
      }
      [textureRefsToRetain addObject:(__bridge_transfer id)yRef];
      [textureRefsToRetain addObject:(__bridge_transfer id)uvRef];
      [renderEncoder setRenderPipelineState:context.nv12PipelineState];
      [renderEncoder setFragmentTexture:yTexture atIndex:0];
      [renderEncoder setFragmentTexture:uvTexture atIndex:1];
    } else if (pixelFormat == kCVPixelFormatType_32BGRA) {
      CVMetalTextureRef bgraRef = nil;
      if (![self updateBGRATextureFromPixelBuffer:pixelBuffer.pixelBuffer
                                          context:context
                                             ref:&bgraRef]) {
        RTCLogError(@"SharedMetal: Failed to update BGRA texture from pixel buffer.");
        [renderEncoder endEncoding];
        return NO;
      }
      id<MTLTexture> bgraTexture = CVMetalTextureGetTexture(bgraRef);
      if (!bgraTexture) {
        RTCLogError(@"SharedMetal: BGRA texture is nil.");
        if (bgraRef) {
          CFRelease(bgraRef);
        }
        [renderEncoder endEncoding];
        return NO;
      }
      [textureRefsToRetain addObject:(__bridge_transfer id)bgraRef];
      [renderEncoder setRenderPipelineState:context.bgraPipelineState];
      [renderEncoder setFragmentTexture:bgraTexture atIndex:0];
    } else {
      RTCLogError(@"SharedMetal: Unsupported CVPixelBuffer pixel format: %u.",
                  (unsigned int)pixelFormat);
      [renderEncoder endEncoding];
      return NO;
    }
  } else if ([buffer conformsToProtocol:@protocol(RTC_OBJC_TYPE(RTCNV12Buffer))]) {
    id<RTC_OBJC_TYPE(RTCNV12Buffer)> nv12Buffer =
        (id<RTC_OBJC_TYPE(RTCNV12Buffer)>)buffer;
    if (![self updateNV12TexturesFromNV12Buffer:nv12Buffer context:context]) {
      RTCLogError(@"SharedMetal: Failed to update NV12 textures from NV12 buffer.");
      [renderEncoder endEncoding];
      return NO;
    }
    [renderEncoder setRenderPipelineState:context.nv12PipelineState];
    [renderEncoder setFragmentTexture:_nv12YTexture atIndex:0];
    [renderEncoder setFragmentTexture:_nv12UVTexture atIndex:1];
  } else if ([buffer conformsToProtocol:@protocol(RTC_OBJC_TYPE(RTCI420Buffer))]) {
    id<RTC_OBJC_TYPE(RTCI420Buffer)> i420Buffer =
        (id<RTC_OBJC_TYPE(RTCI420Buffer)>)buffer;
    if (![self updateI420TexturesFromI420Buffer:i420Buffer context:context]) {
      RTCLogError(@"SharedMetal: Failed to update I420 textures from I420 buffer.");
      [renderEncoder endEncoding];
      return NO;
    }
    [renderEncoder setRenderPipelineState:context.i420PipelineState];
    [renderEncoder setFragmentTexture:_i420YTexture atIndex:0];
    [renderEncoder setFragmentTexture:_i420UTexture atIndex:1];
    [renderEncoder setFragmentTexture:_i420VTexture atIndex:2];
  } else {
    id<RTC_OBJC_TYPE(RTCI420Buffer)> i420Buffer = [buffer toI420];
    if (!i420Buffer ||
        ![self updateI420TexturesFromI420Buffer:i420Buffer context:context]) {
      [renderEncoder endEncoding];
      return NO;
    }
    [renderEncoder setRenderPipelineState:context.i420PipelineState];
    [renderEncoder setFragmentTexture:_i420YTexture atIndex:0];
    [renderEncoder setFragmentTexture:_i420UTexture atIndex:1];
    [renderEncoder setFragmentTexture:_i420VTexture atIndex:2];
  }

  [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                    vertexStart:0
                    vertexCount:4
                  instanceCount:1];
  [renderEncoder endEncoding];

  if (textureRefsToRetain.count > 0) {
    [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> buffer) {
      (void)textureRefsToRetain;
    }];
  }

  return YES;
}

#pragma mark - Private

- (void)updateVertexBufferForFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
                        targetSize:(CGSize)targetSize
                          rotation:(RTC_OBJC_TYPE(RTCVideoRotation))rotation
                       contentMode:(UIViewContentMode)contentMode {
  // Default to the full buffer size for non-CVPixelBuffer inputs.
  int frameWidth = frame.buffer.width;
  int frameHeight = frame.buffer.height;
  int cropX = 0;
  int cropY = 0;
  int cropWidth = frameWidth;
  int cropHeight = frameHeight;

  // CVPixelBuffer carries a crop rect that must be respected, otherwise
  // the image will appear stretched or off-center.
  if ([frame.buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
    RTC_OBJC_TYPE(RTCCVPixelBuffer) *pixelBuffer =
        (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)frame.buffer;
    frameWidth = (int)CVPixelBufferGetWidth(pixelBuffer.pixelBuffer);
    frameHeight = (int)CVPixelBufferGetHeight(pixelBuffer.pixelBuffer);
    cropX = pixelBuffer.cropX;
    cropY = pixelBuffer.cropY;
    cropWidth = pixelBuffer.cropWidth;
    cropHeight = pixelBuffer.cropHeight;
  }

  // Guard against invalid buffers to avoid corrupting the vertex buffer.
  if (frameWidth <= 0 || frameHeight <= 0) {
    return;
  }

  // Treat empty crops as full-frame to keep texture coords in range.
  if (cropWidth <= 0 || cropHeight <= 0) {
    cropX = 0;
    cropY = 0;
    cropWidth = frameWidth;
    cropHeight = frameHeight;
  }

  CGFloat targetAspect = targetSize.width / MAX(targetSize.height, 1);
  // When rotated 90/270, the source aspect is effectively swapped.
  CGFloat sourceAspect =
      (rotation == RTC_OBJC_TYPE(RTCVideoRotation_90) ||
       rotation == RTC_OBJC_TYPE(RTCVideoRotation_270))
          ? (CGFloat)cropHeight / MAX(cropWidth, 1)
          : (CGFloat)cropWidth / MAX(cropHeight, 1);

  // Normalize crop rect to texture coordinates (0..1).
  CGFloat uMin = (CGFloat)cropX / frameWidth;
  CGFloat uMax = (CGFloat)(cropX + cropWidth) / frameWidth;
  CGFloat vMin = (CGFloat)cropY / frameHeight;
  CGFloat vMax = (CGFloat)(cropY + cropHeight) / frameHeight;
  CGFloat xScale = 1;
  CGFloat yScale = 1;

  if (contentMode == UIViewContentModeScaleAspectFit) {
    // Letterbox/pillarbox via view-space scaling.
    if (targetAspect > sourceAspect) {
      xScale = sourceAspect / targetAspect;
    } else {
      yScale = targetAspect / sourceAspect;
    }
  } else {
    // Center-crop by trimming texture coordinates.
    // Under rotation 90/270, V maps to screen-X and U to screen-Y, so the
    // displayed crop axis swaps relative to the unrotated case.
    auto cropU = [&](CGFloat shrink) {
      CGFloat span = uMax - uMin;
      CGFloat crop = span * shrink;
      uMin += (span - crop) / 2;
      uMax = uMin + crop;
    };
    auto cropV = [&](CGFloat shrink) {
      CGFloat span = vMax - vMin;
      CGFloat crop = span * shrink;
      vMin += (span - crop) / 2;
      vMax = vMin + crop;
    };
    BOOL rotated = (rotation == RTC_OBJC_TYPE(RTCVideoRotation_90) ||
                    rotation == RTC_OBJC_TYPE(RTCVideoRotation_270));
    if (targetAspect > sourceAspect) {
      // Crop the displayed vertical axis.
      rotated ? cropU(sourceAspect / targetAspect)
              : cropV(sourceAspect / targetAspect);
    } else {
      // Crop the displayed horizontal axis.
      rotated ? cropV(targetAspect / sourceAspect)
              : cropU(targetAspect / sourceAspect);
    }
  }

  // Use the same UV ordering as RTCMTLRenderer for each rotation.
  float vertices[16];
  switch (rotation) {
    case RTC_OBJC_TYPE(RTCVideoRotation_90): {
      float values[16] = {
          -static_cast<float>(xScale), -static_cast<float>(yScale),
          static_cast<float>(uMax), static_cast<float>(vMax),
          static_cast<float>(xScale), -static_cast<float>(yScale),
          static_cast<float>(uMax), static_cast<float>(vMin),
          -static_cast<float>(xScale), static_cast<float>(yScale),
          static_cast<float>(uMin), static_cast<float>(vMax),
          static_cast<float>(xScale), static_cast<float>(yScale),
          static_cast<float>(uMin), static_cast<float>(vMin)
      };
      memcpy(vertices, values, sizeof(values));
      break;
    }
    case RTC_OBJC_TYPE(RTCVideoRotation_180): {
      float values[16] = {
          -static_cast<float>(xScale), -static_cast<float>(yScale),
          static_cast<float>(uMax), static_cast<float>(vMin),
          static_cast<float>(xScale), -static_cast<float>(yScale),
          static_cast<float>(uMin), static_cast<float>(vMin),
          -static_cast<float>(xScale), static_cast<float>(yScale),
          static_cast<float>(uMax), static_cast<float>(vMax),
          static_cast<float>(xScale), static_cast<float>(yScale),
          static_cast<float>(uMin), static_cast<float>(vMax)
      };
      memcpy(vertices, values, sizeof(values));
      break;
    }
    case RTC_OBJC_TYPE(RTCVideoRotation_270): {
      float values[16] = {
          -static_cast<float>(xScale), -static_cast<float>(yScale),
          static_cast<float>(uMin), static_cast<float>(vMin),
          static_cast<float>(xScale), -static_cast<float>(yScale),
          static_cast<float>(uMin), static_cast<float>(vMax),
          -static_cast<float>(xScale), static_cast<float>(yScale),
          static_cast<float>(uMax), static_cast<float>(vMin),
          static_cast<float>(xScale), static_cast<float>(yScale),
          static_cast<float>(uMax), static_cast<float>(vMax)
      };
      memcpy(vertices, values, sizeof(values));
      break;
    }
    default: {
      float values[16] = {
          -static_cast<float>(xScale), -static_cast<float>(yScale),
          static_cast<float>(uMin), static_cast<float>(vMax),
          static_cast<float>(xScale), -static_cast<float>(yScale),
          static_cast<float>(uMax), static_cast<float>(vMax),
          -static_cast<float>(xScale), static_cast<float>(yScale),
          static_cast<float>(uMin), static_cast<float>(vMin),
          static_cast<float>(xScale), static_cast<float>(yScale),
          static_cast<float>(uMax), static_cast<float>(vMin)
      };
      memcpy(vertices, values, sizeof(values));
      break;
    }
  }

  memcpy(_vertexBuffer.contents, vertices, sizeof(vertices));
}

- (BOOL)updateNV12TexturesFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                  context:
                                      (RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) *)context
                                     yRef:(CVMetalTextureRef *)yRef
                                    uvRef:(CVMetalTextureRef *)uvRef {
  size_t width = CVPixelBufferGetWidth(pixelBuffer);
  size_t height = CVPixelBufferGetHeight(pixelBuffer);

  CVReturn yResult = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, context.textureCache, pixelBuffer, nil,
      MTLPixelFormatR8Unorm, width, height, 0, yRef);
  CVReturn uvResult = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, context.textureCache, pixelBuffer, nil,
      MTLPixelFormatRG8Unorm, width / 2, height / 2, 1, uvRef);

  return yResult == kCVReturnSuccess &&
         uvResult == kCVReturnSuccess && *yRef != nil && *uvRef != nil;
}

- (BOOL)updateBGRATextureFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                                 context:
                                     (RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) *)context
                                     ref:(CVMetalTextureRef *)ref {
  size_t width = CVPixelBufferGetWidth(pixelBuffer);
  size_t height = CVPixelBufferGetHeight(pixelBuffer);

  CVReturn result = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault, context.textureCache, pixelBuffer, nil,
      MTLPixelFormatBGRA8Unorm, width, height, 0, ref);
  if (result != kCVReturnSuccess || *ref == nil) {
    const OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    CFTypeRef metalCompat =
        CVBufferGetAttachment(pixelBuffer, kCVPixelBufferMetalCompatibilityKey, NULL);
    const BOOL isMetalCompatible = (metalCompat == kCFBooleanTrue);
    const BOOL hasIOSurface = CVPixelBufferGetIOSurface(pixelBuffer) != nil;
    RTCLogError(
        @"SharedMetal: BGRA texture creation failed (result=%d format=%u size=%zux%zu "
        @"metalCompat=%d iosurface=%d)",
        (int)result,
        (unsigned int)pixelFormat,
        width,
        height,
        isMetalCompatible,
        hasIOSurface);
  }

  return result == kCVReturnSuccess && *ref != nil;
}

- (BOOL)updateI420TexturesFromI420Buffer:
            (id<RTC_OBJC_TYPE(RTCI420Buffer)>)buffer
                                context:
                                    (RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) *)context {
  CGSize size = CGSizeMake(buffer.width, buffer.height);
  if (!CGSizeEqualToSize(size, _i420TextureSize) ||
      _i420YTexture == nil) {
    MTLTextureDescriptor *yDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:buffer.width
                                                          height:buffer.height
                                                       mipmapped:NO];
    yDescriptor.usage = MTLTextureUsageShaderRead;

    MTLTextureDescriptor *uvDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:buffer.width / 2
                                                          height:buffer.height / 2
                                                       mipmapped:NO];
    uvDescriptor.usage = MTLTextureUsageShaderRead;

    _i420YTexture = [context.device newTextureWithDescriptor:yDescriptor];
    _i420UTexture = [context.device newTextureWithDescriptor:uvDescriptor];
    _i420VTexture = [context.device newTextureWithDescriptor:uvDescriptor];
    _i420TextureSize = size;
  }

  if (!_i420YTexture || !_i420UTexture || !_i420VTexture) {
    return NO;
  }

  MTLRegion yRegion =
      MTLRegionMake2D(0, 0, _i420YTexture.width, _i420YTexture.height);
  [_i420YTexture replaceRegion:yRegion
                   mipmapLevel:0
                     withBytes:buffer.dataY
                   bytesPerRow:buffer.strideY];

  MTLRegion uRegion =
      MTLRegionMake2D(0, 0, _i420UTexture.width, _i420UTexture.height);
  [_i420UTexture replaceRegion:uRegion
                   mipmapLevel:0
                     withBytes:buffer.dataU
                   bytesPerRow:buffer.strideU];

  MTLRegion vRegion =
      MTLRegionMake2D(0, 0, _i420VTexture.width, _i420VTexture.height);
  [_i420VTexture replaceRegion:vRegion
                   mipmapLevel:0
                     withBytes:buffer.dataV
                   bytesPerRow:buffer.strideV];

  return YES;
}

- (BOOL)updateNV12TexturesFromNV12Buffer:
            (id<RTC_OBJC_TYPE(RTCNV12Buffer)>)buffer
                                context:
                                    (RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) *)context {
  CGSize size = CGSizeMake(buffer.width, buffer.height);
  if (!CGSizeEqualToSize(size, _nv12TextureSize) ||
      _nv12YTexture == nil) {
    MTLTextureDescriptor *yDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:buffer.width
                                                          height:buffer.height
                                                       mipmapped:NO];
    yDescriptor.usage = MTLTextureUsageShaderRead;

    MTLTextureDescriptor *uvDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm
                                                           width:buffer.width / 2
                                                          height:buffer.height / 2
                                                       mipmapped:NO];
    uvDescriptor.usage = MTLTextureUsageShaderRead;

    _nv12YTexture = [context.device newTextureWithDescriptor:yDescriptor];
    _nv12UVTexture = [context.device newTextureWithDescriptor:uvDescriptor];
    _nv12TextureSize = size;
  }

  if (!_nv12YTexture || !_nv12UVTexture) {
    return NO;
  }

  MTLRegion yRegion =
      MTLRegionMake2D(0, 0, _nv12YTexture.width, _nv12YTexture.height);
  [_nv12YTexture replaceRegion:yRegion
                   mipmapLevel:0
                     withBytes:buffer.dataY
                   bytesPerRow:buffer.strideY];

  MTLRegion uvRegion =
      MTLRegionMake2D(0, 0, _nv12UVTexture.width, _nv12UVTexture.height);
  [_nv12UVTexture replaceRegion:uvRegion
                    mipmapLevel:0
                      withBytes:buffer.dataUV
                    bytesPerRow:buffer.strideUV];

  return YES;
}

@end
