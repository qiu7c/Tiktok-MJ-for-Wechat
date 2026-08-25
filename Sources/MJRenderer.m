#import "MJRenderer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

NSString *const MJEnabledKey = @"com.qiu7c.tiktok-mj.enabled";

static void MJLog(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSLogv(format, arguments);
    va_end(arguments);
}

@interface NeoWCMatteVideoView : MTKView
- (instancetype)initWithFrame:(CGRect)frame URL:(NSURL *)URL completion:(dispatch_block_t)completion;
- (void)start;
- (void)stop;
@end

@interface NeoWCPassthroughOverlayView : UIView
@end

@implementation NeoWCPassthroughOverlayView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point;
    (void)event;
    return nil;
}

@end

@interface NeoWCPassthroughWindow : UIWindow
@end

@implementation NeoWCPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point;
    (void)event;
    return nil;
}

@end

@interface NeoWCMatteVideoView ()
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) CIContext *CIContext;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) NSArray<id<MTLTexture>> *texturePool;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *texturePoolBusy;
@property (nonatomic, strong) NSLock *texturePoolLock;
@property (nonatomic, copy) dispatch_block_t completion;
@property (nonatomic, strong) id endObserver;
@property (nonatomic, strong) id failureObserver;
@property (nonatomic, assign) BOOL completed;
@property (nonatomic, assign) BOOL renderedFirstFrame;
@property (nonatomic, assign) CVPixelBufferRef lastPixelBuffer;
@end

@implementation NeoWCMatteVideoView

- (instancetype)initWithFrame:(CGRect)frame URL:(NSURL *)URL completion:(dispatch_block_t)completion {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device || !URL) {
        MJLog(@"[MJ彩蛋] 无法创建 Metal 播放视图：device=%@ URL=%@", device ? @"YES" : @"NO", URL.path ?: @"-");
        return nil;
    }
    self = [super initWithFrame:frame device:device];
    if (!self) return nil;
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
    self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    self.framebufferOnly = NO;
    self.paused = YES;
    self.enableSetNeedsDisplay = NO;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.contentScaleFactor = UIScreen.mainScreen.scale;
    self.drawableSize = CGSizeMake(CGRectGetWidth(frame) * self.contentScaleFactor,
                                   CGRectGetHeight(frame) * self.contentScaleFactor);

    _completion = [completion copy];
    _CIContext = [CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace: NSNull.null}];
    _commandQueue = [device newCommandQueue];
    _texturePoolLock = [NSLock new];
    NSMutableArray<id<MTLTexture>> *textures = [NSMutableArray arrayWithCapacity:3];
    _texturePoolBusy = [NSMutableArray arrayWithCapacity:3];
    NSUInteger textureWidth = MAX((NSUInteger)1, (NSUInteger)ceil(self.drawableSize.width));
    NSUInteger textureHeight = MAX((NSUInteger)1, (NSUInteger)ceil(self.drawableSize.height));
    for (NSUInteger index = 0; index < 3; index++) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                                 width:textureWidth
                                                                                                height:textureHeight
                                                                                             mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture) {
            [textures addObject:texture];
            [_texturePoolBusy addObject:@NO];
        }
    }
    _texturePool = [textures copy];
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attributes];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:URL];
    [item addOutput:_videoOutput];
    _player = [AVPlayer playerWithPlayerItem:item];
    _player.muted = NO;
    __weak typeof(self) weakSelf = self;
    _endObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                    object:item
                                                                     queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(__unused NSNotification *note) {
        [weakSelf finish];
    }];
    _failureObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                                                                         object:item
                                                                          queue:NSOperationQueue.mainQueue
                                                                     usingBlock:^(__unused NSNotification *note) {
        NSError *error = weakSelf.player.currentItem.error;
        MJLog(@"[MJ彩蛋] 视频播放失败：%@", error.localizedDescription ?: @"未知错误");
        [weakSelf finish];
    }];
    return self;
}

- (void)start {
    if (self.completed) return;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
    if (@available(iOS 15.0, *)) {
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30.0, 30.0, 30.0);
    } else {
        self.displayLink.preferredFramesPerSecond = 30;
    }
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self.player play];
    MJLog(@"[MJ彩蛋] 开始播放：%@", self.player.currentItem.asset);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf && !weakSelf.completed && !weakSelf.renderedFirstFrame) {
            MJLog(@"[MJ彩蛋] 播放器已启动，但一秒内没有取得视频帧");
        }
    });
}

- (void)displayLinkFired:(CADisplayLink *)displayLink {
    CFTimeInterval hostTime = displayLink.targetTimestamp > 0.0 ? displayLink.targetTimestamp : displayLink.timestamp;
    CMTime itemTime = [self.videoOutput itemTimeForHostTime:hostTime];
    if ([self.videoOutput hasNewPixelBufferForItemTime:itemTime]) {
        CVPixelBufferRef pixelBuffer = [self.videoOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:nil];
        if (pixelBuffer) {
            if (self.lastPixelBuffer) CVPixelBufferRelease(self.lastPixelBuffer);
            self.lastPixelBuffer = pixelBuffer;
        }
    }
    if (self.lastPixelBuffer) [self renderPixelBuffer:self.lastPixelBuffer];
}

- (void)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    id<CAMetalDrawable> drawable = self.currentDrawable;
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
    if (!drawable || !commandBuffer) return;

    CIImage *frame = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGRect extent = frame.extent;
    CGFloat halfWidth = floor(CGRectGetWidth(extent) * 0.5);
    if (halfWidth < 1.0 || CGRectGetHeight(extent) < 1.0) return;
    CGRect matteRect = CGRectMake(CGRectGetMinX(extent), CGRectGetMinY(extent),
                                  halfWidth, CGRectGetHeight(extent));
    CGRect colorRect = CGRectMake(CGRectGetMinX(extent) + halfWidth, CGRectGetMinY(extent),
                                  halfWidth, CGRectGetHeight(extent));
    CIImage *matte = [frame imageByCroppingToRect:matteRect];
    CIImage *color = [[frame imageByCroppingToRect:colorRect]
        imageByApplyingTransform:CGAffineTransformMakeTranslation(-halfWidth, 0.0)];
    CGRect drawableBounds = CGRectMake(0.0, 0.0, self.drawableSize.width, self.drawableSize.height);
    CGFloat scale = MIN(CGRectGetWidth(drawableBounds) / halfWidth,
                        CGRectGetHeight(drawableBounds) / CGRectGetHeight(extent));
    CGFloat renderedWidth = halfWidth * scale;
    CGFloat renderedHeight = CGRectGetHeight(extent) * scale;
    CGFloat offsetX = (CGRectGetWidth(drawableBounds) - renderedWidth) * 0.5;
    // Core Image uses a bottom-left origin, so this places the rendered top edge
    // at the drawable's top while retaining horizontal centering.
    CGFloat offsetY = CGRectGetHeight(drawableBounds) - renderedHeight;
    CGAffineTransform scaleTransform = CGAffineTransformMakeScale(scale, scale);
    matte = [[matte imageByApplyingTransform:scaleTransform]
        imageByCroppingToRect:CGRectMake(0.0, 0.0, renderedWidth, renderedHeight)];
    color = [[color imageByApplyingTransform:scaleTransform]
        imageByCroppingToRect:CGRectMake(0.0, 0.0, renderedWidth, renderedHeight)];
    CIColor *transparentColor = [CIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.0];
    CIImage *clear = [[CIImage imageWithColor:transparentColor]
        imageByCroppingToRect:CGRectMake(0.0, 0.0, renderedWidth, renderedHeight)];
    CIFilter *blend = [CIFilter filterWithName:@"CIBlendWithMask"];
    [blend setValue:color forKey:kCIInputImageKey];
    [blend setValue:clear forKey:kCIInputBackgroundImageKey];
    [blend setValue:matte forKey:kCIInputMaskImageKey];
    CIImage *composited = blend.outputImage;
    if (!composited) return;

    NSUInteger textureIndex = NSNotFound;
    [self.texturePoolLock lock];
    for (NSUInteger index = 0; index < self.texturePoolBusy.count; index++) {
        if (!self.texturePoolBusy[index].boolValue) {
            self.texturePoolBusy[index] = @YES;
            textureIndex = index;
            break;
        }
    }
    [self.texturePoolLock unlock];
    if (textureIndex == NSNotFound || textureIndex >= self.texturePool.count) return;
    id<MTLTexture> renderTexture = self.texturePool[textureIndex];

    composited = [composited imageByApplyingTransform:CGAffineTransformMakeTranslation(offsetX, offsetY)];
    CIImage *canvas = [[CIImage imageWithColor:transparentColor] imageByCroppingToRect:drawableBounds];
    composited = [composited imageByCompositingOverImage:canvas];

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [self.CIContext render:composited
                toMTLTexture:renderTexture
        commandBuffer:commandBuffer
               bounds:drawableBounds
           colorSpace:colorSpace];
    CGColorSpaceRelease(colorSpace);
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    if (!blit) {
        [self.texturePoolLock lock];
        self.texturePoolBusy[textureIndex] = @NO;
        [self.texturePoolLock unlock];
        return;
    }
    [blit copyFromTexture:renderTexture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(renderTexture.width, renderTexture.height, 1)
                toTexture:drawable.texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    __weak typeof(self) weakSelf = self;
    [commandBuffer addCompletedHandler:^(__unused id<MTLCommandBuffer> completedBuffer) {
        [weakSelf.texturePoolLock lock];
        if (textureIndex < weakSelf.texturePoolBusy.count) weakSelf.texturePoolBusy[textureIndex] = @NO;
        [weakSelf.texturePoolLock unlock];
    }];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
    if (!self.renderedFirstFrame) {
        self.renderedFirstFrame = YES;
        MJLog(@"[MJ彩蛋] 已取得并提交首帧");
    }
}

- (void)finish {
    if (self.completed) return;
    self.completed = YES;
    dispatch_block_t completion = self.completion;
    [self stop];
    if (completion) completion();
}

- (void)stop {
    [self.player pause];
    [self.displayLink invalidate];
    self.displayLink = nil;
    if (self.lastPixelBuffer) {
        CVPixelBufferRelease(self.lastPixelBuffer);
        self.lastPixelBuffer = NULL;
    }
    if (self.endObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:self.endObserver];
        self.endObserver = nil;
    }
    if (self.failureObserver) {
        [NSNotificationCenter.defaultCenter removeObserver:self.failureObserver];
        self.failureObserver = nil;
    }
}

- (void)dealloc {
    [self stop];
}

@end

static NSString *NeoWCMJEasterEggDataDirectory(void) {
    NSURL *applicationSupport = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                                     inDomains:NSUserDomainMask].firstObject;
    return applicationSupport ? [[applicationSupport URLByAppendingPathComponent:@"MJ" isDirectory:YES] path] : nil;
}

static NSArray<NSString *> *MJAlphaAssetNames(void) {
    return @[@"mj-drop-alpha.mov", @"mj-swing-alpha.mov"];
}

static NSArray<NSString *> *MJAlphaAssetShareURLs(void) {
    return @[
        @"https://qiuzhun.lanzouw.com/ibIGt44kdmva",
        @"https://qiuzhun.lanzouw.com/iaf1F44kdpli"
    ];
}

static BOOL MJFileLooksLikeMovie(NSString *path);

static NSData *MJHTTPData(NSURLRequest *request, NSInteger *statusCode) {
    if (!request) return nil;
    __block NSData *result = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 30.0;
    configuration.timeoutIntervalForResource = 60.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [response isKindOfClass:NSHTTPURLResponse.class]) {
            status = ((NSHTTPURLResponse *)response).statusCode;
            if (status >= 200 && status < 300) result = data;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [task resume];
    dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(65.0 * NSEC_PER_SEC)));
    [session finishTasksAndInvalidate];
    if (statusCode) *statusCode = status;
    return result;
}

static NSString *MJResolveLanzouShareURL(NSString *shareString) {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://ovoy.cc/lzy.php"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"url" value:shareString]];
    NSURL *apiURL = components.URL;
    if (!apiURL) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:apiURL];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    NSInteger status = 0;
    NSData *jsonData = MJHTTPData(request, &status);
    NSDictionary *payload = jsonData ? [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil] : nil;
    if (![payload isKindOfClass:NSDictionary.class] || [payload[@"code"] integerValue] != 200) return nil;
    NSString *downURL = [payload[@"downUrl"] isKindOfClass:NSString.class] ? payload[@"downUrl"] : nil;
    return downURL.length > 0 ? downURL : nil;
}

static BOOL MJFileLooksLikeMovie(NSString *path) {
    NSData *header = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (header.length < 8) return NO;
    const unsigned char *bytes = header.bytes;
    return bytes[4] == 'f' && bytes[5] == 't' && bytes[6] == 'y' && bytes[7] == 'p';
}

BOOL MJAlphaAssetsReady(void) {
    NSString *directory = NeoWCMJEasterEggDataDirectory();
    if (directory.length == 0) return NO;
    for (NSString *name in MJAlphaAssetNames()) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if ([attributes[NSFileSize] unsignedLongLongValue] < 1024 || !MJFileLooksLikeMovie(path)) return NO;
    }
    return YES;
}

void MJDeleteLocalAssets(void) {
    NSString *directory = NeoWCMJEasterEggDataDirectory();
    if (directory.length == 0) return;
    for (NSString *name in MJAlphaAssetNames()) {
        [[NSFileManager defaultManager] removeItemAtPath:[directory stringByAppendingPathComponent:name] error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".download"]] error:nil];
    }
    MJLog(@"[MJ彩蛋] 已删除本地透明素材");
}

void MJEnsureAssetsReady(void (^completion)(BOOL success, NSString *errorMessage)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *directory = NeoWCMJEasterEggDataDirectory();
        NSError *directoryError = nil;
        BOOL directoryReady = directory.length > 0 &&
            [NSFileManager.defaultManager createDirectoryAtPath:directory
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&directoryError];
        if (!directoryReady) {
            MJLog(@"[MJ彩蛋] 无法创建网络素材目录：%@", directoryError.localizedDescription ?: @"未知错误");
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO, directoryError.localizedDescription ?: @"无法创建本地素材目录"); });
            return;
        }
        if (MJAlphaAssetsReady()) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(YES, nil); });
            return;
        }

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 30.0;
        configuration.timeoutIntervalForResource = 180.0;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
        dispatch_group_t group = dispatch_group_create();
        __block BOOL success = YES;
        __block NSString *failureReason = nil;
        NSArray<NSString *> *names = MJAlphaAssetNames();
        NSArray<NSString *> *addresses = MJAlphaAssetShareURLs();
        for (NSUInteger index = 0; index < names.count; index++) {
            NSString *destination = [directory stringByAppendingPathComponent:names[index]];
            NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:destination error:nil];
            if ([attributes[NSFileSize] unsignedLongLongValue] >= 1024 && MJFileLooksLikeMovie(destination)) continue;
            NSString *resolvedURLString = MJResolveLanzouShareURL(addresses[index]);
            NSURL *URL = [NSURL URLWithString:resolvedURLString];
            if (!URL) {
                @synchronized (names) {
                    success = NO;
                    if (!failureReason) failureReason = [NSString stringWithFormat:@"%@：蓝奏云分享页解析失败", names[index]];
                }
                continue;
            }
            dispatch_group_enter(group);
            NSMutableURLRequest *downloadRequest = [NSMutableURLRequest requestWithURL:URL];
            [downloadRequest setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
            [downloadRequest setValue:addresses[index] forHTTPHeaderField:@"Referer"];
            NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:downloadRequest completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                BOOL fileOK = error == nil && [response isKindOfClass:NSHTTPURLResponse.class] &&
                    ((NSHTTPURLResponse *)response).statusCode >= 200 && ((NSHTTPURLResponse *)response).statusCode < 300;
                BOOL movedDownload = NO;
                BOOL validMovie = NO;
                if (fileOK && location) {
                    NSString *temporary = [destination stringByAppendingString:@".download"];
                    [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
                    movedDownload = [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:temporary] error:&error];
                    validMovie = movedDownload && MJFileLooksLikeMovie(temporary);
                    fileOK = movedDownload && validMovie;
                    if (fileOK) {
                        [[NSFileManager defaultManager] removeItemAtPath:destination error:nil];
                        fileOK = [[NSFileManager defaultManager] moveItemAtPath:temporary toPath:destination error:&error];
                    }
                }
                if (!fileOK) {
                    @synchronized (names) {
                        success = NO;
                        if (!failureReason) {
                            if (movedDownload && !validMovie) {
                                failureReason = [NSString stringWithFormat:@"%@：下载内容不是有效 MOV 文件", names[index]];
                            } else if (error.localizedDescription.length > 0) {
                                failureReason = [NSString stringWithFormat:@"%@：%@",
                                                  names[index], error.localizedDescription];
                            } else if ([response isKindOfClass:NSHTTPURLResponse.class]) {
                                failureReason = [NSString stringWithFormat:@"%@：服务器返回 HTTP %ld",
                                                  names[index], (long)((NSHTTPURLResponse *)response).statusCode];
                            } else {
                                failureReason = [NSString stringWithFormat:@"%@：下载失败", names[index]];
                            }
                        }
                    }
                    MJLog(@"[MJ彩蛋] 下载 %@ 失败：%@", names[index], error.localizedDescription ?: @"HTTP 错误");
                }
                dispatch_group_leave(group);
            }];
            [task resume];
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [session finishTasksAndInvalidate];
            BOOL ready = success && MJAlphaAssetsReady();
            if (completion) completion(ready, ready ? nil : (failureReason ?: @"素材下载完成但文件校验失败"));
        });
    });
}

static NSArray<NSURL *> *NeoWCMJEasterEggMaterializeResources(void) {
    NSString *directory = NeoWCMJEasterEggDataDirectory();
    if (directory.length == 0) {
        MJLog(@"[MJ彩蛋] 无法取得数据目录");
        return @[];
    }
    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&directoryError]) {
        MJLog(@"[MJ彩蛋] 无法创建数据目录：%@", directoryError.localizedDescription ?: @"未知错误");
        return @[];
    }

    if (MJAlphaAssetsReady()) {
        NSMutableArray<NSURL *> *downloaded = [NSMutableArray arrayWithCapacity:2];
        for (NSString *name in MJAlphaAssetNames()) {
            [downloaded addObject:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]]];
        }
        MJLog(@"[MJ彩蛋] 使用本地透明视频资源：%@", directory);
        return downloaded;
    }
    MJLog(@"[MJ彩蛋] 本地透明素材尚未就绪");
    return @[];
}

static UIWindow *NeoWCMJEasterEggWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *candidate in UIApplication.sharedApplication.connectedScenes) {
        if (![candidate isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *scene = (UIWindowScene *)candidate;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in scene.windows) {
            if (window.hidden || window.alpha <= 0.01 || window.windowLevel != UIWindowLevelNormal ||
                !window.rootViewController) continue;
            if (window.isKeyWindow) return window;
            if (!fallback) fallback = window;
        }
    }
    return fallback;
}

static id MJActiveSession;

@interface NeoWCAlphaVideoSession : NSObject
@property (nonatomic, strong) NeoWCPassthroughWindow *overlayWindow;
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) id endObserver;
@property (nonatomic, strong) id failureObserver;
@property (nonatomic, assign) BOOL stopping;
- (void)startWithURL:(NSURL *)URL;
- (void)stop;
@end

@implementation NeoWCAlphaVideoSession

- (void)startWithURL:(NSURL *)URL {
    UIWindow *hostWindow = NeoWCMJEasterEggWindow();
    UIWindowScene *scene = hostWindow.windowScene;
    if (!hostWindow || !scene || !URL) {
        MJLog(@"[MJ彩蛋] 无法开始透明视频：window=%@ URL=%@", hostWindow ? @"YES" : @"NO", URL.path ?: @"-");
        return;
    }
    self.overlayWindow = [[NeoWCPassthroughWindow alloc] initWithWindowScene:scene];
    self.overlayWindow.frame = scene.screen.bounds;
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 1.0;
    self.overlayWindow.backgroundColor = UIColor.clearColor;
    self.overlayWindow.opaque = NO;
    self.overlayWindow.userInteractionEnabled = NO;
    UIViewController *rootController = [UIViewController new];
    rootController.view.backgroundColor = UIColor.clearColor;
    self.overlayWindow.rootViewController = rootController;
    self.overlayWindow.hidden = NO;
    self.overlay = [[NeoWCPassthroughOverlayView alloc] initWithFrame:self.overlayWindow.bounds];
    self.overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.overlay.backgroundColor = UIColor.clearColor;
    self.overlay.userInteractionEnabled = NO;
    self.overlay.alpha = 0.0;
    [self.overlayWindow addSubview:self.overlay];

    self.player = [AVPlayer playerWithURL:URL];
    self.player.muted = NO;
    self.player.automaticallyWaitsToMinimizeStalling = NO;
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.playerLayer.frame = self.overlay.bounds;
    self.playerLayer.opacity = 0.0;
    [self.overlay.layer addSublayer:self.playerLayer];
    __weak typeof(self) weakSelf = self;
    self.endObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                                         object:self.player.currentItem
                                                                          queue:NSOperationQueue.mainQueue
                                                                     usingBlock:^(__unused NSNotification *note) {
        [weakSelf stop];
    }];
    self.failureObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification
                                                                            object:self.player.currentItem
                                                                             queue:NSOperationQueue.mainQueue
                                                                        usingBlock:^(__unused NSNotification *note) {
        MJLog(@"[MJ彩蛋] 透明视频播放失败：%@", weakSelf.player.currentItem.error.localizedDescription ?: @"未知错误");
        [weakSelf stop];
    }];
    self.overlay.alpha = 1.0;
    self.playerLayer.opacity = 1.0;
    [self.player playImmediatelyAtRate:1.0];
}

- (void)stop {
    if (self.stopping) return;
    self.stopping = YES;
    [self.player pause];
    if (self.endObserver) [NSNotificationCenter.defaultCenter removeObserver:self.endObserver];
    if (self.failureObserver) [NSNotificationCenter.defaultCenter removeObserver:self.failureObserver];
    self.endObserver = nil;
    self.failureObserver = nil;
    [self.playerLayer removeFromSuperlayer];
    [self.overlay removeFromSuperview];
    self.overlayWindow.hidden = YES;
    self.overlayWindow.rootViewController = nil;
    self.playerLayer = nil;
    self.player = nil;
    self.overlay = nil;
    self.overlayWindow = nil;
    if (MJActiveSession == self) MJActiveSession = nil;
}

@end

@interface NeoWCMJEasterEggSession : NSObject
@property (nonatomic, strong) NeoWCPassthroughWindow *overlayWindow;
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) NSMutableArray<NeoWCMatteVideoView *> *videoViews;
@property (nonatomic, copy) NSArray<NSURL *> *URLs;
@property (nonatomic, assign) NSUInteger finishedCount;
@property (nonatomic, assign) BOOL stopping;
- (void)start;
- (void)playAll;
- (void)videoDidFinish:(NeoWCMatteVideoView *)videoView;
- (void)stop;
@end

static NSUInteger MJNextClipIndex;

@implementation NeoWCMJEasterEggSession

- (void)start {
    UIWindow *hostWindow = NeoWCMJEasterEggWindow();
    if (!hostWindow || self.URLs.count == 0) {
        MJLog(@"[MJ彩蛋] 无法开始：window=%@ clips=%lu", hostWindow ? @"YES" : @"NO", (unsigned long)self.URLs.count);
        return;
    }
    UIWindowScene *scene = hostWindow.windowScene;
    if (!scene) {
        MJLog(@"[MJ彩蛋] 微信窗口没有可用的 UIWindowScene");
        return;
    }
    self.overlayWindow = [[NeoWCPassthroughWindow alloc] initWithWindowScene:scene];
    self.overlayWindow.frame = scene.screen.bounds;
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 1.0;
    self.overlayWindow.backgroundColor = UIColor.clearColor;
    self.overlayWindow.opaque = NO;
    self.overlayWindow.userInteractionEnabled = NO;
    UIViewController *rootController = [UIViewController new];
    rootController.view.backgroundColor = UIColor.clearColor;
    self.overlayWindow.rootViewController = rootController;
    self.overlayWindow.hidden = NO;
    MJLog(@"[MJ彩蛋] 创建独立动画窗口：%@ frame=%@ level=%.0f", NSStringFromClass(self.overlayWindow.class),
          NSStringFromCGRect(self.overlayWindow.bounds), self.overlayWindow.windowLevel);
    self.overlay = [[NeoWCPassthroughOverlayView alloc] initWithFrame:self.overlayWindow.bounds];
    self.overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.overlay.backgroundColor = UIColor.clearColor;
    self.overlay.userInteractionEnabled = NO;
    self.overlay.alpha = 0.0;
    self.videoViews = [NSMutableArray arrayWithCapacity:self.URLs.count];
    [self.overlayWindow addSubview:self.overlay];
    [UIView animateWithDuration:0.12 animations:^{ self.overlay.alpha = 1.0; }];
    [self playAll];
}

- (void)playAll {
    if (self.stopping) return;
    for (NSURL *URL in self.URLs) {
        __weak typeof(self) weakSelf = self;
        __block __weak NeoWCMatteVideoView *weakView = nil;
        NeoWCMatteVideoView *view = [[NeoWCMatteVideoView alloc] initWithFrame:self.overlay.bounds
                                                                           URL:URL
                                                                    completion:^{
            [weakSelf videoDidFinish:weakView];
        }];
        weakView = view;
        if (!view) {
            self.finishedCount += 1;
            continue;
        }
        [self.videoViews addObject:view];
        [self.overlay addSubview:view];
    }
    if (self.videoViews.count == 0 || self.finishedCount >= self.URLs.count) {
        [self stop];
        return;
    }
    // Add all views before starting any player so both clips begin in the same run-loop turn.
    for (NeoWCMatteVideoView *view in self.videoViews) [view start];
}

- (void)videoDidFinish:(NeoWCMatteVideoView *)videoView {
    if (self.stopping || !videoView) return;
    if ([self.videoViews containsObject:videoView]) {
        [self.videoViews removeObject:videoView];
        [videoView removeFromSuperview];
        self.finishedCount += 1;
    }
    if (self.finishedCount < self.URLs.count) return;
    self.stopping = YES;
    [UIView animateWithDuration:0.18 animations:^{ self.overlay.alpha = 0.0; } completion:^(__unused BOOL finished) {
        [self stop];
    }];
}

- (void)stop {
    self.stopping = YES;
    for (NeoWCMatteVideoView *view in self.videoViews) {
        [view stop];
        [view removeFromSuperview];
    }
    [self.videoViews removeAllObjects];
    [self.overlay removeFromSuperview];
    self.overlay = nil;
    self.overlayWindow.hidden = YES;
    self.overlayWindow.rootViewController = nil;
    self.overlayWindow = nil;
    if (MJActiveSession == self) MJActiveSession = nil;
}

@end

void MJPlayEasterEgg(void) {
    void (^playBlock)(void) = ^{
        if (![NSUserDefaults.standardUserDefaults boolForKey:MJEnabledKey]) {
            MJLog(@"[MJ彩蛋] 独立开关已关闭，忽略触发");
            return;
        }
        if (MJActiveSession && ![MJActiveSession stopping]) {
            MJLog(@"[MJ彩蛋] 已有动画播放中，忽略重复触发");
            return;
        }
        [MJActiveSession stop];
        NSArray<NSURL *> *URLs = NeoWCMJEasterEggMaterializeResources();
        if (URLs.count == 0) return;
        NSURL *selectedURL = URLs[MJNextClipIndex % URLs.count];
        MJNextClipIndex = (MJNextClipIndex + 1) % URLs.count;
        MJLog(@"[MJ彩蛋] 本次播放第 %lu 段：%@",
              (unsigned long)((MJNextClipIndex + URLs.count - 1) % URLs.count + 1),
              selectedURL.lastPathComponent);
        if (MJAlphaAssetsReady() && [selectedURL.pathExtension.lowercaseString isEqualToString:@"mov"]) {
            NeoWCAlphaVideoSession *alphaSession = [NeoWCAlphaVideoSession new];
            MJActiveSession = alphaSession;
            [alphaSession startWithURL:selectedURL];
            return;
        }
        NeoWCMJEasterEggSession *session = [NeoWCMJEasterEggSession new];
        session.URLs = @[selectedURL];
        MJActiveSession = session;
        [session start];
    };
    if ([NSThread isMainThread]) playBlock();
    else dispatch_async(dispatch_get_main_queue(), playBlock);
}
