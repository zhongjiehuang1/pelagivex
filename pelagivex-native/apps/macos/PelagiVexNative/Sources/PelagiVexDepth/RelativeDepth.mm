#if defined(__APPLE__)
#import <CoreImage/CoreImage.h>
#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#include "PelagiVexDepth.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <mutex>

namespace {

std::mutex predictionLock;
MLModel *cachedModel;
NSString *cachedPath;

MLModel *loadModel(NSString *path) {
    if (cachedModel && [path isEqualToString:cachedPath]) return cachedModel;
    NSURL *url = [NSURL fileURLWithPath:path];
    if ([url.pathExtension isEqualToString:@"mlpackage"]) {
        url = [MLModel compileModelAtURL:url error:nil];
        if (!url) return nil;
    }
    MLModelConfiguration *config = [MLModelConfiguration new];
    config.computeUnits = MLComputeUnitsAll;
    MLModel *model = [MLModel modelWithContentsOfURL:url configuration:config error:nil];
    if (model) {
        cachedModel = model;
        cachedPath = [path copy];
    }
    return model;
}

bool readDepth(CVPixelBufferRef image, float x, float y, float width, float height,
               int columns, int rows, float *out) {
    const auto format = CVPixelBufferGetPixelFormatType(image);
    const size_t bytes = format == kCVPixelFormatType_OneComponent16Half ? 2 :
                         format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_32BGRA ? 4 : 1;
    if (format != kCVPixelFormatType_OneComponent8 && format != kCVPixelFormatType_OneComponent16Half &&
        format != kCVPixelFormatType_OneComponent32Float && format != kCVPixelFormatType_32BGRA) return false;
    const size_t w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image);
    const size_t stride = CVPixelBufferGetBytesPerRow(image);
    if (!w || !h || stride / bytes < w || CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly)) return false;
    const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(image));
    if (base) {
        for (int row = 0; row < rows; ++row) {
            const size_t iy = std::min(h - 1, size_t((y + (row + 0.5f) * height / rows) * h));
            for (int column = 0; column < columns; ++column) {
                const size_t ix = std::min(w - 1, size_t((x + (column + 0.5f) * width / columns) * w));
                const auto *pixel = base + iy * stride + ix * bytes;
                float value = pixel[0];
                if (format == kCVPixelFormatType_OneComponent32Float) std::memcpy(&value, pixel, 4);
                if (format == kCVPixelFormatType_OneComponent16Half) {
                    _Float16 half;
                    std::memcpy(&half, pixel, 2);
                    value = float(half);
                }
                out[row * columns + column] = value;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
    return base != nullptr;
}

} // namespace

int32_t PVPrepareProximity(const char *modelPath) {
    if (!modelPath) return 0;
    std::lock_guard<std::mutex> lock(predictionLock);
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:modelPath];
        return path && loadModel(path) ? 1 : 0;
    }
}

int32_t PVEstimateProximity(const char *modelPath, const void *pixelBuffer,
                           float x, float y, float width, float height,
                           int32_t columns, int32_t rows, float *output) {
    if (!modelPath || !pixelBuffer || !output || columns < 1 || columns > 128 || rows < 1 || rows > 128 ||
        !std::isfinite(x) || !std::isfinite(y) || !std::isfinite(width) || !std::isfinite(height) ||
        x < 0 || y < 0 || width <= 0 || height <= 0 || x + width > 1.0001f || y + height > 1.0001f) return 0;
    std::lock_guard<std::mutex> lock(predictionLock);
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:modelPath];
        if (!path) return 0;
        MLModel *model = loadModel(path);
        MLImageConstraint *constraint = model.modelDescription.inputDescriptionsByName[@"image"].imageConstraint;
        if (!constraint || constraint.pixelsWide < 1 || constraint.pixelsHigh < 1) return 0;
        CVPixelBufferRef resized = nullptr;
        const auto attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (CVPixelBufferCreate(kCFAllocatorDefault, constraint.pixelsWide, constraint.pixelsHigh,
                                kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &resized)) return 0;
        CIImage *source = [CIImage imageWithCVPixelBuffer:(CVPixelBufferRef)pixelBuffer];
        CIImage *scaled = [source imageByApplyingTransform:CGAffineTransformMakeScale(
            constraint.pixelsWide / source.extent.size.width, constraint.pixelsHigh / source.extent.size.height)];
        static CIContext *context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}];
        [context render:scaled toCVPixelBuffer:resized];
        MLFeatureValue *feature = [MLFeatureValue featureValueWithPixelBuffer:resized];
        MLDictionaryFeatureProvider *features = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"image": feature} error:nil];
        CVPixelBufferRelease(resized);
        if (!features) return 0;
        id<MLFeatureProvider> prediction = [model predictionFromFeatures:features error:nil];
        CVPixelBufferRef depth = [prediction featureValueForName:@"depth"].imageBufferValue;
        return depth && readDepth(depth, x, y, width, height, columns, rows, output) ? 1 : 0;
    }
}
#endif
