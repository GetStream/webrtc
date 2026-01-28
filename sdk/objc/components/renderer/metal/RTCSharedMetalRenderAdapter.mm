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
    self->_latestFrame = frame;
    self->_needsRedraw = frame != nil;
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

  [self updateVertexBufferWithSourceSize:[self sourceSizeForFrame:frame
                                                       rotation:rotation]
                              targetSize:targetSize
                                rotation:rotation
                             contentMode:_contentMode];

  MTLRenderPassDescriptor *renderPassDescriptor =
      [[MTLRenderPassDescriptor alloc] init];
  renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
  renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
  renderPassDescriptor.colorAttachments[0].clearColor =
      MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

  id<MTLRenderCommandEncoder> renderEncoder =
      [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
  if (!renderEncoder) {
    return NO;
  }

  [renderEncoder setVertexBuffer:_vertexBuffer offset:0 atIndex:0];

  NSMutableArray *textureRefsToRetain = [NSMutableArray array];

  // Supported formats: CVPixelBuffer (NV12/BGRA), NV12, and I420.
  id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> buffer = frame.buffer;
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
        [renderEncoder endEncoding];
        return NO;
      }
      id<MTLTexture> yTexture = CVMetalTextureGetTexture(yRef);
      id<MTLTexture> uvTexture = CVMetalTextureGetTexture(uvRef);
      if (!yTexture || !uvTexture) {
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
        [renderEncoder endEncoding];
        return NO;
      }
      id<MTLTexture> bgraTexture = CVMetalTextureGetTexture(bgraRef);
      if (!bgraTexture) {
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
      [renderEncoder endEncoding];
      return NO;
    }
  } else if ([buffer conformsToProtocol:@protocol(RTC_OBJC_TYPE(RTCNV12Buffer))]) {
    id<RTC_OBJC_TYPE(RTCNV12Buffer)> nv12Buffer =
        (id<RTC_OBJC_TYPE(RTCNV12Buffer)>)buffer;
    if (![self updateNV12TexturesFromNV12Buffer:nv12Buffer context:context]) {
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

- (CGSize)sourceSizeForFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
                    rotation:(RTC_OBJC_TYPE(RTCVideoRotation))rotation {
  CGSize size = CGSizeMake(frame.buffer.width, frame.buffer.height);
  if (rotation == RTC_OBJC_TYPE(RTCVideoRotation_90) ||
      rotation == RTC_OBJC_TYPE(RTCVideoRotation_270)) {
    return CGSizeMake(size.height, size.width);
  }
  return size;
}

- (void)updateVertexBufferWithSourceSize:(CGSize)sourceSize
                              targetSize:(CGSize)targetSize
                                rotation:(RTC_OBJC_TYPE(RTCVideoRotation))rotation
                             contentMode:(UIViewContentMode)contentMode {
  CGFloat targetAspect = targetSize.width / MAX(targetSize.height, 1);
  CGFloat sourceAspect = sourceSize.width / MAX(sourceSize.height, 1);

  CGFloat uMin = 0;
  CGFloat uMax = 1;
  CGFloat vMin = 0;
  CGFloat vMax = 1;
  CGFloat xScale = 1;
  CGFloat yScale = 1;

  if (contentMode == UIViewContentModeScaleAspectFit) {
    if (targetAspect > sourceAspect) {
      xScale = sourceAspect / targetAspect;
    } else {
      yScale = targetAspect / sourceAspect;
    }
  } else {
    if (targetAspect > sourceAspect) {
      CGFloat vCrop = sourceAspect / targetAspect;
      CGFloat vOffset = (1 - vCrop) / 2;
      vMin = vOffset;
      vMax = vOffset + vCrop;
    } else {
      CGFloat uCrop = targetAspect / sourceAspect;
      CGFloat uOffset = (1 - uCrop) / 2;
      uMin = uOffset;
      uMax = uOffset + uCrop;
    }
  }

  float vertices[16] = {
      -static_cast<float>(xScale), -static_cast<float>(yScale),
      static_cast<float>(uMin), static_cast<float>(vMax),
      static_cast<float>(xScale), -static_cast<float>(yScale),
      static_cast<float>(uMax), static_cast<float>(vMax),
      -static_cast<float>(xScale), static_cast<float>(yScale),
      static_cast<float>(uMin), static_cast<float>(vMin),
      static_cast<float>(xScale), static_cast<float>(yScale),
      static_cast<float>(uMax), static_cast<float>(vMin)
  };

  [self rotateTextureCoordinates:vertices rotation:rotation];
  memcpy(_vertexBuffer.contents, vertices, sizeof(vertices));
}

- (void)rotateTextureCoordinates:(float *)vertices
                        rotation:(RTC_OBJC_TYPE(RTCVideoRotation))rotation {
  int rotationTimes = 0;
  switch (rotation) {
    case RTC_OBJC_TYPE(RTCVideoRotation_90):
      rotationTimes = 1;
      break;
    case RTC_OBJC_TYPE(RTCVideoRotation_180):
      rotationTimes = 2;
      break;
    case RTC_OBJC_TYPE(RTCVideoRotation_270):
      rotationTimes = 3;
      break;
    default:
      rotationTimes = 0;
      break;
  }

  for (int pass = 0; pass < rotationTimes; pass++) {
    for (int i = 0; i < 16; i += 4) {
      float u = vertices[i + 2];
      float v = vertices[i + 3];
      vertices[i + 2] = 1.0f - v;
      vertices[i + 3] = u;
    }
  }
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
