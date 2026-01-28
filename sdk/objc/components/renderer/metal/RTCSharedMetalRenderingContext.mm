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
#import <UIKit/UIKit.h>

#import "RTCSharedMetalRenderingContext+Private.h"
#import "RTCSharedMetalVideoView.h"
#import "base/RTCLogging.h"

// Minimal Metal shader source for YUV/BGRA sampling used by the shared backend.
static NSString *const kSharedMetalShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "\n"
     "struct VertexOut {\n"
     "  float4 position [[position]];\n"
     "  float2 texcoord;\n"
     "};\n"
     "\n"
     "vertex VertexOut streamVideoVertex(\n"
     "    uint vertexID [[vertex_id]],\n"
     "    const device float4 *vertices [[buffer(0)]]) {\n"
     "  float4 data = vertices[vertexID];\n"
     "  VertexOut out;\n"
     "  out.position = float4(data.xy, 0.0, 1.0);\n"
     "  out.texcoord = data.zw;\n"
     "  return out;\n"
     "}\n"
     "\n"
     "fragment float4 streamVideoNV12Fragment(\n"
     "    VertexOut in [[stage_in]],\n"
     "    texture2d<float, access::sample> yTexture [[texture(0)]],\n"
     "    texture2d<float, access::sample> uvTexture [[texture(1)]]) {\n"
     "  constexpr sampler samplerState(address::clamp_to_edge, filter::linear);\n"
     "  float y = yTexture.sample(samplerState, in.texcoord).r;\n"
     "  float2 uv = uvTexture.sample(samplerState, in.texcoord).rg - float2(0.5, 0.5);\n"
     "\n"
     "  float3 rgb;\n"
     "  rgb.r = y + 1.402 * uv.y;\n"
     "  rgb.g = y - 0.344136 * uv.x - 0.714136 * uv.y;\n"
     "  rgb.b = y + 1.772 * uv.x;\n"
     "\n"
     "  return float4(rgb, 1.0);\n"
     "}\n"
     "\n"
     "fragment float4 streamVideoI420Fragment(\n"
     "    VertexOut in [[stage_in]],\n"
     "    texture2d<float, access::sample> yTexture [[texture(0)]],\n"
     "    texture2d<float, access::sample> uTexture [[texture(1)]],\n"
     "    texture2d<float, access::sample> vTexture [[texture(2)]]) {\n"
     "  constexpr sampler samplerState(address::clamp_to_edge, filter::linear);\n"
     "  float y = yTexture.sample(samplerState, in.texcoord).r;\n"
     "  float u = uTexture.sample(samplerState, in.texcoord).r - 0.5;\n"
     "  float v = vTexture.sample(samplerState, in.texcoord).r - 0.5;\n"
     "\n"
     "  float3 rgb;\n"
     "  rgb.r = y + 1.402 * v;\n"
     "  rgb.g = y - 0.344136 * u - 0.714136 * v;\n"
     "  rgb.b = y + 1.772 * u;\n"
     "\n"
     "  return float4(rgb, 1.0);\n"
     "}\n"
     "\n"
     "fragment float4 streamVideoBGRAFragment(\n"
     "    VertexOut in [[stage_in]],\n"
     "    texture2d<float, access::sample> texture [[texture(0)]]) {\n"
     "  constexpr sampler samplerState(address::clamp_to_edge, filter::linear);\n"
     "  return texture.sample(samplerState, in.texcoord);\n"
     "}\n";

@implementation RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) {
  // Serial queue to guard the weak view set.
  dispatch_queue_t _viewsQueue;
  NSHashTable<RTC_OBJC_TYPE(RTCSharedMetalVideoView) *> *_views;
  CADisplayLink *_displayLink;
}

+ (nullable instancetype)sharedContext {
  static RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) *sharedContext = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedContext = [[RTC_OBJC_TYPE(RTCSharedMetalRenderingContext) alloc] init];
  });
  return sharedContext;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _viewsQueue = dispatch_queue_create(
        "webrtc.sharedmetal.views", DISPATCH_QUEUE_SERIAL);
    _views = [NSHashTable weakObjectsHashTable];

    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
      RTCLogError(@"SharedMetal: Failed to create MTLDevice");
      return nil;
    }

    _commandQueue = [_device newCommandQueue];
    if (!_commandQueue) {
      RTCLogError(@"SharedMetal: Failed to create command queue");
      return nil;
    }

    CVMetalTextureCacheRef cache = nil;
    CVReturn cacheResult = CVMetalTextureCacheCreate(
        kCFAllocatorDefault, nil, _device, nil, &cache);
    if (cacheResult != kCVReturnSuccess || cache == nil) {
      RTCLogError(@"SharedMetal: Failed to create texture cache");
      return nil;
    }
    _textureCache = cache;

    id<MTLLibrary> library = [self makeLibraryWithDevice:_device];
    if (!library) {
      return nil;
    }

    _nv12PipelineState =
        [self makePipelineStateWithDevice:_device
                                  library:library
                              fragmentName:@"streamVideoNV12Fragment"];
    _i420PipelineState =
        [self makePipelineStateWithDevice:_device
                                  library:library
                              fragmentName:@"streamVideoI420Fragment"];
    _bgraPipelineState =
        [self makePipelineStateWithDevice:_device
                                  library:library
                              fragmentName:@"streamVideoBGRAFragment"];

    if (!_nv12PipelineState || !_i420PipelineState || !_bgraPipelineState) {
      RTCLogError(@"SharedMetal: Failed to create pipeline states");
      return nil;
    }
  }

  return self;
}

- (void)dealloc {
  if (_textureCache) {
    CFRelease(_textureCache);
    _textureCache = nil;
  }
  [self stopDisplayLinkIfNeeded];
}

- (void)registerView:(RTC_OBJC_TYPE(RTCSharedMetalVideoView) *)view {
  dispatch_sync(_viewsQueue, ^{
    [self->_views addObject:view];
  });
  [self startDisplayLinkIfNeeded];
}

- (void)unregisterView:(RTC_OBJC_TYPE(RTCSharedMetalVideoView) *)view {
  dispatch_sync(_viewsQueue, ^{
    [self->_views removeObject:view];
  });
  [self stopDisplayLinkIfNeeded];
}

#pragma mark - Private

- (void)startDisplayLinkIfNeeded {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_displayLink) {
      return;
    }
    self->_displayLink = [CADisplayLink displayLinkWithTarget:self
                                                     selector:@selector(displayLinkDidFire)];
    [self->_displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                             forMode:NSRunLoopCommonModes];
  });
}

- (void)stopDisplayLinkIfNeeded {
  dispatch_async(dispatch_get_main_queue(), ^{
    __block BOOL hasViews = NO;
    dispatch_sync(self->_viewsQueue, ^{
      hasViews = self->_views.count > 0;
    });
    if (!hasViews) {
      [self->_displayLink invalidate];
      self->_displayLink = nil;
    }
  });
}

- (void)displayLinkDidFire {
  __block NSArray<RTC_OBJC_TYPE(RTCSharedMetalVideoView) *> *viewsSnapshot = nil;
  dispatch_sync(_viewsQueue, ^{
    viewsSnapshot = self->_views.allObjects;
  });

  for (RTC_OBJC_TYPE(RTCSharedMetalVideoView) *view in viewsSnapshot) {
    [view drawIfNeeded];
  }
}

- (nullable id<MTLLibrary>)makeLibraryWithDevice:(id<MTLDevice>)device {
  if (@available(iOS 10.0, *)) {
    NSError *error = nil;
    id<MTLLibrary> library =
        [device newLibraryWithSource:kSharedMetalShaderSource
                             options:nil
                               error:&error];
    if (!library) {
      RTCLogError(@"SharedMetal: Failed to compile shaders: %@", error);
    }
    return library;
  }
  RTCLogError(@"SharedMetal: Metal shader compilation requires iOS 10+");
  return nil;
}

- (nullable id<MTLRenderPipelineState>)
    makePipelineStateWithDevice:(id<MTLDevice>)device
                         library:(id<MTLLibrary>)library
                     fragmentName:(NSString *)fragmentName {
  id<MTLFunction> vertexFunction =
      [library newFunctionWithName:@"streamVideoVertex"];
  id<MTLFunction> fragmentFunction =
      [library newFunctionWithName:fragmentName];
  if (!vertexFunction || !fragmentFunction) {
    RTCLogError(@"SharedMetal: Missing Metal functions for %@", fragmentName);
    return nil;
  }

  MTLRenderPipelineDescriptor *descriptor =
      [[MTLRenderPipelineDescriptor alloc] init];
  descriptor.vertexFunction = vertexFunction;
  descriptor.fragmentFunction = fragmentFunction;
  descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

  NSError *error = nil;
  id<MTLRenderPipelineState> pipelineState =
      [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  if (!pipelineState) {
    RTCLogError(@"SharedMetal: Failed to create pipeline state: %@", error);
  }
  return pipelineState;
}

@end
