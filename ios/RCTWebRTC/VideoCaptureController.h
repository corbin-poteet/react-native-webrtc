#if !TARGET_OS_TV

#import <Foundation/Foundation.h>
#import <WebRTC/RTCCameraVideoCapturer.h>

#import <React/RCTBridge.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>

#import "CaptureController.h"

@interface VideoCaptureController : CaptureController
@property(nonatomic, readonly, strong) RTCCameraVideoCapturer *capturer;
@property(nonatomic, readonly, strong) AVCaptureDeviceFormat *selectedFormat;
@property(nonatomic, readonly, assign) int frameRate;
@property(nonatomic, assign) BOOL enableMultitaskingCameraAccess;

- (instancetype)initWithCapturer:(RTCCameraVideoCapturer *)capturer andConstraints:(NSDictionary *)constraints;
- (void)startCapture;
- (void)stopCapture;
- (void)switchCamera;
- (void)applyConstraints:(NSDictionary *)constraints error:(NSError **)outError;
- (void)takePicture:(NSDictionary *)options
    successCallback:(RCTResponseSenderBlock)successCallback
      errorCallback:(RCTResponseSenderBlock)errorCallback;

@end
#endif
