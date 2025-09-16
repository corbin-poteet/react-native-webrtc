#if !TARGET_OS_TV

#import "VideoCaptureController.h"

#import <AVFoundation/AVFoundation.h>
#import <AssetsLibrary/ALAssetsLibrary.h>
#import <ImageIO/ImageIO.h>
#import <React/RCTLog.h>

@interface VideoCaptureController ()

@property(nonatomic, strong) RTCCameraVideoCapturer *capturer;
@property(nonatomic, strong) AVCaptureDeviceFormat *selectedFormat;
@property(nonatomic, strong) AVCaptureDevice *device;
@property(nonatomic, assign) BOOL running;
@property(nonatomic, assign) BOOL usingFrontCamera;
@property(nonatomic, assign) int width;
@property(nonatomic, assign) int height;
@property(nonatomic, assign) int frameRate;

@end

@implementation VideoCaptureController

typedef NS_ENUM(NSInteger, RCTCameraCaptureTarget) {
    RCT_CAMERA_CAPTURE_TARGET_MEMORY = 0,
    RCT_CAMERA_CAPTURE_TARGET_DISK = 1,
    RCT_CAMERA_CAPTURE_TARGET_CAMERA_ROLL = 2,
    RCT_CAMERA_CAPTURE_TARGET_TEMP = 3
};

// @TODO: use non-deprecated code. good luck.
AVCaptureStillImageOutput *stillImageOutput = nil;

- (void)takePicture:(NSDictionary *)options
    successCallback:(RCTResponseSenderBlock)successCallback
      errorCallback:(RCTResponseSenderBlock)errorCallback {
    NSInteger captureTarget = [[options valueForKey:@"captureTarget"] intValue];
    NSInteger maxSize = [[options valueForKey:@"maxSize"] intValue];
    CGFloat jpegQuality = [[options valueForKey:@"maxJpegQuality"] floatValue];

    // Clamp jpegQuality between 0 and 1
    if (jpegQuality < 0) {
        jpegQuality = 0;
    } else if (jpegQuality > 1) {
        jpegQuality = 1;
    }

    [stillImageOutput
        captureStillImageAsynchronouslyFromConnection:[stillImageOutput connectionWithMediaType:AVMediaTypeVideo]
                                    completionHandler:^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
                                        if (imageDataSampleBuffer) {
                                            NSData *imageData = [AVCaptureStillImageOutput
                                                jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
                                            CGImageSourceRef source =
                                                CGImageSourceCreateWithData((CFDataRef)imageData, NULL);
                                            NSMutableDictionary *imageMetadata = [(NSDictionary *)CFBridgingRelease(
                                                CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) mutableCopy];
                                            CGImageRef CGImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
                                            CGImage = [self resizeCGImage:CGImage maxSize:maxSize];
                                            CGImageRef rotatedCGImage;

                                            if ([[UIDevice currentDevice] orientation] ==
                                                UIInterfaceOrientationLandscapeLeft) {
                                                if (self->_usingFrontCamera) {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:0];
                                                } else {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:180];
                                                }
                                            } else if ([[UIDevice currentDevice] orientation] ==
                                                       UIInterfaceOrientationLandscapeRight) {
                                                if (self->_usingFrontCamera) {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:180];
                                                } else {
                                                    rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:0];
                                                }
                                            } else if ([[UIDevice currentDevice] orientation] ==
                                                       UIInterfaceOrientationPortraitUpsideDown) {
                                                rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:90];
                                            } else {
                                                // There's a secret 4th orientation when the device is flat on a table
                                                // We default to portrait for that
                                                rotatedCGImage = [self newCGImageRotatedByAngle:CGImage angle:270];
                                            }

                                            CGImageRelease(CGImage);

                                            // Remove orientation metadata
                                            [imageMetadata removeObjectForKey:(NSString *)kCGImagePropertyOrientation];

                                            // Remove TIFF metadata
                                            [imageMetadata
                                                removeObjectForKey:(NSString *)kCGImagePropertyTIFFDictionary];

                                            // Create destination thing
                                            NSMutableData *rotatedImageData = [NSMutableData data];
                                            CGImageDestinationRef destinationRef =
                                                CGImageDestinationCreateWithData((CFMutableDataRef)rotatedImageData,
                                                                                 CGImageSourceGetType(source),
                                                                                 1,
                                                                                 NULL);
                                            CFRelease(source);

                                            // Set compression
                                            NSDictionary *properties = @{
                                                (__bridge NSString *)
                                                kCGImageDestinationLossyCompressionQuality : @(jpegQuality)
                                            };
                                            CGImageDestinationSetProperties(destinationRef,
                                                                            (__bridge CFDictionaryRef)properties);

                                            // Add the image to the destination and add metadata
                                            CGImageDestinationAddImage(
                                                destinationRef, rotatedCGImage, (CFDictionaryRef)imageMetadata);

                                            // Write
                                            CGImageDestinationFinalize(destinationRef);
                                            CFRelease(destinationRef);
                                            [self saveImage:rotatedImageData
                                                         target:captureTarget
                                                       metadata:imageMetadata
                                                successCallback:successCallback
                                                  errorCallback:errorCallback];
                                        } else {
                                            errorCallback(@[ error.description ]);
                                        }
                                    }];
}

- (CGImageRef)newCGImageRotatedByAngle:(CGImageRef)imageRef angle:(CGFloat)angle {
    CGFloat angleInRadians = angle * (M_PI / 180);
    CGFloat width = CGImageGetWidth(imageRef);
    CGFloat height = CGImageGetHeight(imageRef);
    CGRect imageRect = CGRectMake(0, 0, width, height);
    CGAffineTransform transform = CGAffineTransformMakeRotation(angleInRadians);
    CGRect rotatedRect = CGRectApplyAffineTransform(imageRect, transform);

    // Normalize the rotated rect to positive values
    CGFloat rotatedWidth = fabs(rotatedRect.size.width);
    CGFloat rotatedHeight = fabs(rotatedRect.size.height);

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmapContext = CGBitmapContextCreate(
        NULL, rotatedWidth, rotatedHeight, 8, 0, colorSpace, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
    CGContextSetAllowsAntialiasing(bitmapContext, TRUE);
    CGContextSetInterpolationQuality(bitmapContext, kCGInterpolationHigh);
    CGColorSpaceRelease(colorSpace);

    // Move to center of context
    CGContextTranslateCTM(bitmapContext, rotatedWidth / 2, rotatedHeight / 2);
    // Apply rotation
    CGContextRotateCTM(bitmapContext, angleInRadians);
    // Draw image centered
    CGContextDrawImage(bitmapContext, CGRectMake(-width / 2, -height / 2, width, height), imageRef);

    CGImageRef rotatedImage = CGBitmapContextCreateImage(bitmapContext);
    CGContextRelease(bitmapContext);
    return rotatedImage;
}

- (CGImageRef)resizeCGImage:(CGImageRef)image maxSize:(int)maxSize {
    size_t originalWidth = CGImageGetWidth(image);
    size_t originalHeight = CGImageGetHeight(image);

    // Only resize if image larger than maxSize
    if (originalWidth <= maxSize && originalHeight <= maxSize) {
        return image;
    }

    size_t newWidth = originalWidth;
    size_t newHeight = originalHeight;

    // Width
    if (originalWidth > maxSize) {
        newWidth = maxSize;
        newHeight = (newWidth * originalHeight) / originalWidth;
    }

    // Height
    if (newHeight > maxSize) {
        newHeight = maxSize;
        newWidth = (newHeight * originalWidth) / originalHeight;
    }

    // Create new context
    CGColorSpaceRef colorSpace = CGImageGetColorSpace(image);
    CGContextRef context = CGBitmapContextCreate(NULL,
                                                 newWidth,
                                                 newHeight,
                                                 CGImageGetBitsPerComponent(image),
                                                 CGImageGetBytesPerRow(image),
                                                 colorSpace,
                                                 CGImageGetAlphaInfo(image));
    CGColorSpaceRelease(colorSpace);

    if (context == NULL) {
        return image;
    }

    // Draw image to context
    CGContextDrawImage(context, CGRectMake(0, 0, newWidth, newHeight), image);

    // Extract resulting image from context
    CGImageRef imageRef = CGBitmapContextCreateImage(context);
    CGContextRelease(context);

    return imageRef;
};

- (void)saveImage:(NSData *)imageData
             target:(NSInteger)target
           metadata:(NSDictionary *)metadata
    successCallback:(RCTResponseSenderBlock)successCallback
      errorCallback:(RCTResponseSenderBlock)errorCallback {
    if (target == RCT_CAMERA_CAPTURE_TARGET_MEMORY) {
        NSString *base64EncodedImage = [imageData base64EncodedDataWithOptions:0];
        successCallback(@[ base64EncodedImage ]);
        return;
    }

    if (target == RCT_CAMERA_CAPTURE_TARGET_DISK) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *documentsDirectory = [paths firstObject];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *fullPath = [[documentsDirectory stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]
            stringByAppendingPathExtension:@"jpg"];
        [fileManager createFileAtPath:fullPath contents:imageData attributes:nil];
        successCallback(@[ fullPath ]);
        return;
    }

    if (target == RCT_CAMERA_CAPTURE_TARGET_CAMERA_ROLL) {
        [[[ALAssetsLibrary alloc] init] writeImageDataToSavedPhotosAlbum:imageData
                                                                metadata:metadata
                                                         completionBlock:^(NSURL *url, NSError *error) {
                                                             if (error) {
                                                                 errorCallback(@[ error.description ]);
                                                                 return;
                                                             }

                                                             successCallback(@[ [url absoluteString] ]);
                                                             return;
                                                         }];
        return;
    }

    if (target == RCT_CAMERA_CAPTURE_TARGET_TEMP) {
        NSString *fileName = [[NSProcessInfo processInfo] globallyUniqueString];
        NSString *fullPath = [NSString stringWithFormat:@"%@%@.jpg", NSTemporaryDirectory(), fileName];

        // @TODO: check if image successfully stored
        [imageData writeToFile:fullPath atomically:YES];
        successCallback(@[ fullPath ]);
        return;
    }
};

- (instancetype)initWithCapturer:(RTCCameraVideoCapturer *)capturer andConstraints:(NSDictionary *)constraints {
    self = [super init];
    if (self) {
        self.capturer = capturer;
        self.running = NO;
        [self applyConstraints:constraints error:nil];
    }

    return self;
}

- (void)dealloc {
    self.device = NULL;
}

- (void)startCapture {
    if (self.deviceId) {
        self.device = [AVCaptureDevice deviceWithUniqueID:self.deviceId];
    }
    if (!self.device) {
        AVCaptureDevicePosition position =
            self.usingFrontCamera ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        self.device = [self findDeviceForPosition:position];
        self.deviceId = self.device.uniqueID;
    }

    if (!self.device) {
        RCTLogWarn(@"[VideoCaptureController] No capture devices found!");

        return;
    }

    AVCaptureDeviceFormat *format = [self selectFormatForDevice:self.device
                                                withTargetWidth:self.width
                                               withTargetHeight:self.height];
    if (!format) {
        RCTLogWarn(@"[VideoCaptureController] No valid formats for device %@", self.device);

        return;
    }

    self.selectedFormat = format;

    AVCaptureSession *session = self.capturer.captureSession;
    if (@available(iOS 16.0, *)) {
        BOOL enable = self.enableMultitaskingCameraAccess;
        BOOL shouldChange = session.multitaskingCameraAccessEnabled != enable;
        BOOL canChange = !enable || (enable && session.isMultitaskingCameraAccessSupported);

        if (shouldChange && canChange) {
            [session beginConfiguration];
            [session setMultitaskingCameraAccessEnabled:enable];
            [session commitConfiguration];
        }
    }

    RCTLog(@"[VideoCaptureController] Capture will start");

    // Starting the capture happens on another thread. Wait for it.
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __weak VideoCaptureController *weakSelf = self;
    [self.capturer
        startCaptureWithDevice:self.device
                        format:format
                           fps:self.frameRate
             completionHandler:^(NSError *err) {
                 if (err) {
                     RCTLogError(@"[VideoCaptureController] Error starting capture: %@", err);
                 } else {
                     AVCaptureSession *capSession = _capturer.captureSession;
                     if (stillImageOutput != nil) {
                         [capSession removeOutput:stillImageOutput];
                         stillImageOutput = nil;
                     }

                     stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
                     [stillImageOutput setHighResolutionStillImageOutputEnabled:true];
                     NSDictionary *outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
                     [stillImageOutput setOutputSettings:outputSettings];

                     if ([capSession canAddOutput:stillImageOutput]) {
                         [capSession addOutput:stillImageOutput];
                     } else {
                         NSLog(@"[VideoCaptureController] Failed to add stillImageOutput, snapshot is not working");
                     }

                     RCTLog(@"[VideoCaptureController] Capture started");
                     weakSelf.running = YES;
                 }
                 dispatch_semaphore_signal(semaphore);
             }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

- (void)stopCapture {
    if (!self.running)
        return;

    RCTLog(@"[VideoCaptureController] Capture will stop");
    // Stopping the capture happens on another thread. Wait for it.
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    __weak VideoCaptureController *weakSelf = self;
    [self.capturer stopCaptureWithCompletionHandler:^{
        if (stillImageOutput != nil) {
            stillImageOutput = nil;
        }

        RCTLog(@"[VideoCaptureController] Capture stopped");
        weakSelf.running = NO;
        weakSelf.device = nil;

        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
}

- (void)applyConstraints:(NSDictionary *)constraints error:(NSError **)outError {
    // Clear device to prepare for starting camera with new constraints.
    self.device = nil;

    BOOL hasChanged = NO;

    NSString *deviceId = constraints[@"deviceId"];
    int width = [constraints[@"width"] intValue];
    int height = [constraints[@"height"] intValue];
    int frameRate = [constraints[@"frameRate"] intValue];

    if (self.width != width) {
        hasChanged = YES;
        self.width = width;
    }

    if (self.height != height) {
        hasChanged = YES;
        self.height = height;
    }

    if (self.frameRate != frameRate) {
        hasChanged = YES;
        self.frameRate = frameRate;
    }

    id facingMode = constraints[@"facingMode"];

    if (!facingMode && !deviceId) {
        // Default to front camera.
        facingMode = @"user";
    }

    if (facingMode && [facingMode isKindOfClass:[NSString class]]) {
        AVCaptureDevicePosition position;
        if ([facingMode isEqualToString:@"environment"]) {
            position = AVCaptureDevicePositionBack;
        } else if ([facingMode isEqualToString:@"user"]) {
            position = AVCaptureDevicePositionFront;
        } else {
            // If the specified facingMode value is not supported, fall back
            // to the front camera.
            position = AVCaptureDevicePositionFront;
        }

        BOOL usingFrontCamera = position == AVCaptureDevicePositionFront;
        if (self.usingFrontCamera != usingFrontCamera) {
            hasChanged = YES;
            self.usingFrontCamera = usingFrontCamera;
        }
    }

    if (!deviceId) {
        AVCaptureDevicePosition position =
            self.usingFrontCamera ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
        deviceId = [self findDeviceForPosition:position].uniqueID;
    }

    if (self.deviceId != deviceId && ![self.deviceId isEqualToString:deviceId]) {
        hasChanged = YES;
        self.deviceId = deviceId;
    }

    if (self.running && hasChanged) {
        [self startCapture];
    }
}

- (NSDictionary *)getSettings {
    AVCaptureDeviceFormat *format = self.selectedFormat;
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    NSMutableDictionary *settings = [[NSMutableDictionary alloc] initWithDictionary:@{
        @"groupId" : @"",
        @"height" : @(dimensions.height),
        @"width" : @(dimensions.width),
        @"frameRate" : @(30),
        @"facingMode" : self.usingFrontCamera ? @"user" : @"environment"
    }];

    if (self.deviceId) {
        settings[@"deviceId"] = self.deviceId;
    }
    return settings;
}
#pragma mark NSKeyValueObserving

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context {
    if (@available(iOS 11.1, *)) {
        if ([object isKindOfClass:[AVCaptureDevice class]] && [keyPath isEqualToString:@"systemPressureState"]) {
            AVCaptureDevice *device = (AVCaptureDevice *)object;
            AVCaptureSystemPressureLevel pressureLevel =
                ((AVCaptureSystemPressureState *)change[NSKeyValueChangeNewKey]).level;
            if (pressureLevel == AVCaptureSystemPressureLevelSerious ||
                pressureLevel == AVCaptureSystemPressureLevelCritical) {
                RCTLogWarn(
                    @"[VideoCaptureController] Reached elevated system pressure level: %@. Throttling frame rate.",
                    pressureLevel);
                [self throttleFrameRateForDevice:device];
            } else if (pressureLevel == AVCaptureSystemPressureLevelNominal) {
                RCTLogWarn(@"[VideoCaptureController] Restored normal system pressure level. Resetting frame rate to "
                           @"default.");
                [self resetFrameRateForDevice:device];
            }
        }
    }
}

- (void)registerSystemPressureStateObserverForDevice:(AVCaptureDevice *)device {
    if (@available(iOS 11.1, *)) {
        [device addObserver:self forKeyPath:@"systemPressureState" options:NSKeyValueObservingOptionNew context:nil];
    }
}

- (void)removeObserverForDevice:(AVCaptureDevice *)device {
    if (@available(iOS 11.1, *)) {
        [device removeObserver:self forKeyPath:@"systemPressureState"];
    }
}

#pragma mark Private

- (void)setDevice:(AVCaptureDevice *)device {
    if (_device) {
        [self removeObserverForDevice:_device];
    }
    if (device) {
        [self registerSystemPressureStateObserverForDevice:device];
    }

    _device = device;
}

- (AVCaptureDevice *)findDeviceForPosition:(AVCaptureDevicePosition)position {
    NSArray<AVCaptureDevice *> *captureDevices = [RTCCameraVideoCapturer captureDevices];
    for (AVCaptureDevice *device in captureDevices) {
        if (device.position == position) {
            return device;
        }
    }

    return [captureDevices firstObject];
}

- (AVCaptureDeviceFormat *)selectFormatForDevice:(AVCaptureDevice *)device
                                 withTargetWidth:(int)targetWidth
                                withTargetHeight:(int)targetHeight {
    NSArray<AVCaptureDeviceFormat *> *formats = [RTCCameraVideoCapturer supportedFormatsForDevice:device];
    AVCaptureDeviceFormat *selectedFormat = nil;
    int currentDiff = INT_MAX;

    for (AVCaptureDeviceFormat *format in formats) {
        CMVideoDimensions dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
        FourCharCode pixelFormat = CMFormatDescriptionGetMediaSubType(format.formatDescription);
        int diff = abs(targetWidth - dimension.width) + abs(targetHeight - dimension.height);
        if (diff < currentDiff) {
            selectedFormat = format;
            currentDiff = diff;
        } else if (diff == currentDiff && pixelFormat == [_capturer preferredOutputPixelFormat]) {
            selectedFormat = format;
        }
    }

    return selectedFormat;
}

- (void)throttleFrameRateForDevice:(AVCaptureDevice *)device {
    NSError *error = nil;

    [device lockForConfiguration:&error];
    if (error) {
        RCTLog(@"[VideoCaptureController] Could not lock device for configuration: %@", error);
        return;
    }

    device.activeVideoMinFrameDuration = CMTimeMake(1, 20);
    device.activeVideoMaxFrameDuration = CMTimeMake(1, 15);

    [device unlockForConfiguration];
}

- (void)resetFrameRateForDevice:(AVCaptureDevice *)device {
    NSError *error = nil;

    [device lockForConfiguration:&error];
    if (error) {
        RCTLog(@"[VideoCaptureController] Could not lock device for configuration: %@", error);
        return;
    }

    device.activeVideoMinFrameDuration = kCMTimeInvalid;
    device.activeVideoMaxFrameDuration = kCMTimeInvalid;

    [device unlockForConfiguration];
}

@end

#endif
