//
//  CameraPreviewTexture.m
//  camerawesome
//
//  Created by Dimitri Dessus on 28/03/2023.
//

#import "CameraPreviewTexture.h"
#import <CoreImage/CoreImage.h>

@interface CameraPreviewTexture ()
@property(nonatomic, strong) CIContext *ciContext;
@end

@implementation CameraPreviewTexture

- (instancetype)init {
  if (self = [super init]) {
    _previewRotationDegrees = 0;
  }
  return self;
}

- (void)updateBuffer:(CMSampleBufferRef)sampleBuffer {
  CVPixelBufferRef srcBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  CVPixelBufferRef newBuffer;
  if (self.previewRotationDegrees == 0) {
    newBuffer = srcBuffer;
    CFRetain(newBuffer);
  } else {
    newBuffer = [self rotateBuffer:srcBuffer degrees:self.previewRotationDegrees];
  }
  CVPixelBufferRef old = atomic_load(&_latestPixelBuffer);
  while (!atomic_compare_exchange_strong(&_latestPixelBuffer, &old, newBuffer)) {
    old = atomic_load(&_latestPixelBuffer);
  }
  if (old != nil) {
    CFRelease(old);
  }
}

- (CVPixelBufferRef)rotateBuffer:(CVPixelBufferRef)src degrees:(NSInteger)degrees {
  NSInteger norm = ((degrees % 360) + 360) % 360;
  if (norm == 0) {
    CFRetain(src);
    return src;
  }
  // CIImage/CGAffineTransform and EXIF orientation both diverge from the direct
  // byte rotation used by CopyUprightBGRA8888Bytes (CIImage's y-up/y-down flip
  // introduces a mirror), so no 90° CIImage transform ever matched the analysis
  // buffer orientation on device. Replicate the exact byte mapping of
  // CopyUprightBGRA8888Bytes case 90/180/270 here so preview and analysis share
  // an identical rotation (analysis is already portrait-up). Perf: naive per-pixel
  // copy; optimize with vImage later.
  CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
  size_t srcW = CVPixelBufferGetWidth(src);
  size_t srcH = CVPixelBufferGetHeight(src);
  size_t srcBytesPerRow = CVPixelBufferGetBytesPerRow(src);
  const uint8_t *srcBase = (const uint8_t *)CVPixelBufferGetBaseAddress(src);

  size_t dstW = (norm == 90 || norm == 270) ? srcH : srcW;
  size_t dstH = (norm == 90 || norm == 270) ? srcW : srcH;

  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  CVPixelBufferRef dst;
  CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH,
                      CVPixelBufferGetPixelFormatType(src),
                      (__bridge CFDictionaryRef)attrs, &dst);
  CVPixelBufferLockBaseAddress(dst, 0);
  uint8_t *dstBase = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
  size_t dstBytesPerRow = CVPixelBufferGetBytesPerRow(dst);

  for (size_t y = 0; y < srcH; y++) {
    for (size_t x = 0; x < srcW; x++) {
      const uint8_t *srcPixel = srcBase + y * srcBytesPerRow + x * 4;
      size_t dstX;
      size_t dstY;
      switch (norm) {
        case 90:
          dstX = srcH - 1 - y;
          dstY = x;
          break;
        case 180:
          dstX = srcW - 1 - x;
          dstY = srcH - 1 - y;
          break;
        case 270:
          dstX = y;
          dstY = srcW - 1 - x;
          break;
        default:
          dstX = x;
          dstY = y;
          break;
      }
      uint8_t *dstPixel = dstBase + dstY * dstBytesPerRow + dstX * 4;
      dstPixel[0] = srcPixel[0];
      dstPixel[1] = srcPixel[1];
      dstPixel[2] = srcPixel[2];
      dstPixel[3] = srcPixel[3];
    }
  }

  CVPixelBufferUnlockBaseAddress(dst, 0);
  CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
  return dst;
}

/// Used to copy pixels to in-memory buffer
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  CVPixelBufferRef pixelBuffer = atomic_load(&_latestPixelBuffer);
  while (!atomic_compare_exchange_strong(&_latestPixelBuffer, &pixelBuffer, nil)) {
    pixelBuffer = atomic_load(&_latestPixelBuffer);
  }

  return pixelBuffer;
}

- (void)dealloc {
  if (self.latestPixelBuffer) {
    CFRelease(self.latestPixelBuffer);
  }
}

@end
