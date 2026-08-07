#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#include <dlfcn.h>
#include <os/log.h>

/*
 * The private cursor registration signatures below are loaded dynamically.
 * Their behavior and signatures were researched by Joe Ranieri and Alex
 * Zielenski for Mousecape. See THIRD_PARTY_NOTICES.md for attribution and
 * license terms. This integration is altered and purpose-built for Magic Cursor.
 */
typedef int CGSConnectionID;
typedef CGSConnectionID (*CGSMainConnectionIDFunction)(void);
typedef char *(*CGSCursorNameFunction)(int cursorID);
typedef CGError (*CGSCopyRegisteredCursorImagesFunction)(CGSConnectionID, char *, CGSize *, CGPoint *, NSUInteger *, CGFloat *, CFArrayRef *);
typedef CGError (*CGSRegisterCursorWithImagesFunction)(CGSConnectionID, char *, bool, bool, CGSize, CGPoint, NSUInteger, CGFloat, CFArrayRef, int *);
typedef void (*CGSSetDockCursorOverrideFunction)(CGSConnectionID, bool);
typedef CGError (*CGSSetSystemDefinedCursorFunction)(CGSConnectionID, int);
typedef CGError (*CGSSetConnectionPropertyFunction)(CGSConnectionID, CGSConnectionID, CFStringRef, CFTypeRef);
typedef bool (*CGCursorIsVisibleFunction)(void);
typedef CGError (*CoreCursorCopyImagesFunction)(CGSConnectionID, int, CFArrayRef *, CGSize *, CGPoint *, NSUInteger *, CGFloat *);

@interface SystemCursorBackup : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSArray *images;
@property(nonatomic) CGSize size;
@property(nonatomic) CGPoint hotspot;
@property(nonatomic) NSUInteger frameCount;
@property(nonatomic) CGFloat frameDuration;
@end

@implementation SystemCursorBackup
@end

@interface SystemCursorController : NSObject
- (BOOL)replaceWithTransparentCursors;
- (BOOL)reapplyTransparentCursors;
- (void)refreshActiveCursor;
- (void)setBackgroundCursorHidingAllowed:(BOOL)allowed;
- (BOOL)cursorIsVisible;
- (void)ensureCursorHiddenInBackground;
- (void)restoreOriginalCursors;
@end

@implementation SystemCursorController {
    void *_skyLight;
    void *_hiServices;
    void *_coreGraphics;
    CGSMainConnectionIDFunction _mainConnectionID;
    CGSCursorNameFunction _cursorName;
    CGSCopyRegisteredCursorImagesFunction _copyRegisteredImages;
    CGSRegisterCursorWithImagesFunction _registerImages;
    CGSSetDockCursorOverrideFunction _setDockCursorOverride;
    CGSSetSystemDefinedCursorFunction _setSystemDefinedCursor;
    CGSSetConnectionPropertyFunction _setConnectionProperty;
    CGCursorIsVisibleFunction _cursorIsVisible;
    CoreCursorCopyImagesFunction _copyCoreCursorImages;
    NSArray<SystemCursorBackup *> *_backups;
    int _transparentArrowCursorID;
    BOOL _replaced;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    _hiServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL);
    _coreGraphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL);
    if (_skyLight) {
        _mainConnectionID = (CGSMainConnectionIDFunction)dlsym(_skyLight, "CGSMainConnectionID");
        _cursorName = (CGSCursorNameFunction)dlsym(_skyLight, "CGSCursorNameForSystemCursor");
        _copyRegisteredImages = (CGSCopyRegisteredCursorImagesFunction)dlsym(_skyLight, "CGSCopyRegisteredCursorImages");
        _registerImages = (CGSRegisterCursorWithImagesFunction)dlsym(_skyLight, "CGSRegisterCursorWithImages");
        _setDockCursorOverride = (CGSSetDockCursorOverrideFunction)dlsym(_skyLight, "CGSSetDockCursorOverride");
        _setSystemDefinedCursor = (CGSSetSystemDefinedCursorFunction)dlsym(_skyLight, "CGSSetSystemDefinedCursor");
        _setConnectionProperty = (CGSSetConnectionPropertyFunction)dlsym(_skyLight, "CGSSetConnectionProperty");
        _transparentArrowCursorID = 0;
        for (int cursorID = 0; cursorID < 128; cursorID++) {
            char *name = _cursorName ? _cursorName(cursorID) : NULL;
            if (name && [[NSString stringWithUTF8String:name] hasSuffix:@".ArrowS"]) {
                _transparentArrowCursorID = cursorID;
                break;
            }
        }
    }
    if (_hiServices) {
        _copyCoreCursorImages = (CoreCursorCopyImagesFunction)dlsym(_hiServices, "CoreCursorCopyImages");
    }
    if (_coreGraphics) {
        _cursorIsVisible = (CGCursorIsVisibleFunction)dlsym(_coreGraphics, "CGCursorIsVisible");
    }
    return self;
}

- (void)setBackgroundCursorHidingAllowed:(BOOL)allowed {
    if (!_setConnectionProperty || !_mainConnectionID) return;
    CGSConnectionID connection = _mainConnectionID();
    _setConnectionProperty(connection,
                           connection,
                           CFSTR("SetsCursorInBackground"),
                           allowed ? kCFBooleanTrue : kCFBooleanFalse);
}

- (BOOL)cursorIsVisible {
    return _cursorIsVisible ? _cursorIsVisible() : YES;
}

- (void)ensureCursorHiddenInBackground {
    [self setBackgroundCursorHidingAllowed:YES];
    if ([self cursorIsVisible]) {
        CGDisplayHideCursor(CGMainDisplayID());
    }
}

- (BOOL)isAvailable {
    return _mainConnectionID && _cursorName && _copyRegisteredImages &&
           _registerImages && _copyCoreCursorImages;
}

- (BOOL)replaceWithTransparentCursors {
    if (_replaced) return [self reapplyTransparentCursors];
    if (![self isAvailable]) {
        os_log_error(OS_LOG_DEFAULT, "MagicCursor: private cursor APIs unavailable");
        return NO;
    }

    CGSConnectionID connection = _mainConnectionID();
    NSMutableArray<SystemCursorBackup *> *backups = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *registeredNames = [NSMutableOrderedSet orderedSet];
    [registeredNames addObjectsFromArray:@[
        @"com.apple.coregraphics.Arrow",
        @"com.apple.coregraphics.ArrowCtx",
        @"com.apple.coregraphics.ArrowS",
        @"com.apple.coregraphics.IBeam",
        @"com.apple.coregraphics.IBeamXOR",
        @"com.apple.coregraphics.IBeamS",
        @"com.apple.coregraphics.Alias",
        @"com.apple.coregraphics.Copy",
        @"com.apple.coregraphics.Move",
        @"com.apple.coregraphics.Wait",
        @"com.apple.coregraphics.Empty"
    ]];

    // Discover renamed cursor identifiers, including Tahoe's ArrowS/IBeamS.
    for (int cursorID = 0; cursorID < 128; cursorID++) {
        char *name = _cursorName(cursorID);
        if (name) [registeredNames addObject:[NSString stringWithUTF8String:name]];
    }

    for (NSString *name in registeredNames) {
        SystemCursorBackup *backup = [self backupRegisteredCursor:name connection:connection];
        if (backup) [backups addObject:backup];
    }

    // Core cursors cover link hands, resize cursors, crosshairs, forbidden,
    // zoom and other pointer shapes that applications may select.
    for (int cursorID = 0; cursorID < 45; cursorID++) {
        SystemCursorBackup *backup = [self backupCoreCursor:cursorID connection:connection];
        if (backup) [backups addObject:backup];
    }

    os_log_info(OS_LOG_DEFAULT, "MagicCursor: backed up %{public}lu cursor registrations", (unsigned long)backups.count);
    if (backups.count == 0) return NO;
    _backups = [backups copy];

    _replaced = [self applyTransparentCursorRegistrations];
    os_log_info(OS_LOG_DEFAULT, "MagicCursor: initial cursor replacement %{public}s",
                _replaced ? "succeeded" : "failed");
    if (!_replaced) _backups = nil;
    return _replaced;
}

- (BOOL)reapplyTransparentCursors {
    if (!_replaced || _backups.count == 0) return NO;
    return [self applyTransparentCursorRegistrations];
}

- (void)refreshActiveCursor {
    if (!_replaced || !_setSystemDefinedCursor || !_mainConnectionID) return;
    CGSConnectionID connection = _mainConnectionID();
    CGImageRef transparentImage = [self createTransparentCursorImage];
    if (transparentImage) {
        NSArray *transparentImages = @[(__bridge id)transparentImage];
        for (SystemCursorBackup *backup in _backups) {
            // macOS 26 may continuously restore these two names after an app
            // loses focus. Refreshing only arrows is lightweight enough to do
            // during pointer tracking while the initial pass still covers all
            // other cursor shapes.
            if (![backup.name hasSuffix:@".Arrow"] &&
                ![backup.name hasSuffix:@".ArrowS"] &&
                ![backup.name hasSuffix:@".ArrowCtx"]) continue;
            int seed = 0;
            _registerImages(connection,
                            (char *)backup.name.UTF8String,
                            true,
                            true,
                            CGSizeMake(16, 16),
                            CGPointZero,
                            1,
                            0,
                            (__bridge CFArrayRef)transparentImages,
                            &seed);
        }
        CGImageRelease(transparentImage);
    }
    if (_setDockCursorOverride) _setDockCursorOverride(connection, false);
    _setSystemDefinedCursor(connection, _transparentArrowCursorID);
}

- (BOOL)applyTransparentCursorRegistrations {
    if (_backups.count == 0 || !_registerImages || !_mainConnectionID) return NO;

    CGImageRef transparentImage = [self createTransparentCursorImage];
    if (!transparentImage) {
        return NO;
    }
    NSArray *transparentImages = @[(__bridge id)transparentImage];
    CGSConnectionID connection = _mainConnectionID();

    NSUInteger successCount = 0;
    for (SystemCursorBackup *backup in _backups) {
        int seed = 0;
        CGError error = _registerImages(
            connection,
            (char *)backup.name.UTF8String,
            true,
            true,
            CGSizeMake(16, 16),
            CGPointZero,
            1,
            0,
            (__bridge CFArrayRef)transparentImages,
            &seed
        );
        if (error == kCGErrorSuccess) successCount++;
        else {
            os_log_error(OS_LOG_DEFAULT, "MagicCursor: cursor registration failed with %{public}d", error);
        }
    }
    CGImageRelease(transparentImage);

    if (_setDockCursorOverride) _setDockCursorOverride(connection, false);
    [self refreshActiveCursor];
    os_log_info(OS_LOG_DEFAULT, "MagicCursor: replaced %{public}lu of %{public}lu cursor registrations",
                (unsigned long)successCount, (unsigned long)_backups.count);
    return successCount > 0;
}

- (SystemCursorBackup *)backupRegisteredCursor:(NSString *)name connection:(CGSConnectionID)connection {
    CGSize size = CGSizeZero;
    CGPoint hotspot = CGPointZero;
    NSUInteger frameCount = 0;
    CGFloat frameDuration = 0;
    CFArrayRef images = NULL;
    CGError error = _copyRegisteredImages(
        connection,
        (char *)name.UTF8String,
        &size,
        &hotspot,
        &frameCount,
        &frameDuration,
        &images
    );
    return [self backupWithName:name
                          error:error
                         images:images
                           size:size
                        hotspot:hotspot
                     frameCount:frameCount
                  frameDuration:frameDuration];
}

- (SystemCursorBackup *)backupCoreCursor:(int)cursorID connection:(CGSConnectionID)connection {
    CGSize size = CGSizeZero;
    CGPoint hotspot = CGPointZero;
    NSUInteger frameCount = 0;
    CGFloat frameDuration = 0;
    CFArrayRef images = NULL;
    CGError error = _copyCoreCursorImages(
        connection,
        cursorID,
        &images,
        &size,
        &hotspot,
        &frameCount,
        &frameDuration
    );
    NSString *name = [NSString stringWithFormat:@"com.apple.cursor.%d", cursorID];
    return [self backupWithName:name
                          error:error
                         images:images
                           size:size
                        hotspot:hotspot
                     frameCount:frameCount
                  frameDuration:frameDuration];
}

- (SystemCursorBackup *)backupWithName:(NSString *)name
                                  error:(CGError)error
                                 images:(CFArrayRef)images
                                   size:(CGSize)size
                                hotspot:(CGPoint)hotspot
                             frameCount:(NSUInteger)frameCount
                          frameDuration:(CGFloat)frameDuration {
    if (error != kCGErrorSuccess || !images || CFArrayGetCount(images) == 0 || frameCount == 0) {
        if (images) CFRelease(images);
        return nil;
    }

    SystemCursorBackup *backup = [SystemCursorBackup new];
    backup.name = name;
    backup.images = CFBridgingRelease(images);
    backup.size = size;
    backup.hotspot = hotspot;
    backup.frameCount = frameCount;
    backup.frameDuration = frameDuration;
    return backup;
}

- (CGImageRef)createTransparentCursorImage CF_RETURNS_RETAINED {
    const size_t width = 16;
    const size_t height = 16;
    uint8_t pixels[16 * 16 * 4];
    memset(pixels, 0, sizeof(pixels));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixels, width, height, 8, width * 4, colorSpace,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(colorSpace);
    if (!context) return NULL;
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    return image;
}

- (void)restoreOriginalCursors {
    if (!_replaced || _backups.count == 0 || !_registerImages || !_mainConnectionID) return;
    CGSConnectionID connection = _mainConnectionID();
    for (SystemCursorBackup *backup in _backups) {
        int seed = 0;
        _registerImages(
            connection,
            (char *)backup.name.UTF8String,
            true,
            true,
            backup.size,
            backup.hotspot,
            backup.frameCount,
            backup.frameDuration,
            (__bridge CFArrayRef)backup.images,
            &seed
        );
    }
    if (_setDockCursorOverride) _setDockCursorOverride(connection, true);
    _backups = nil;
    _replaced = NO;
}

- (void)dealloc {
    [self restoreOriginalCursors];
    if (_coreGraphics) dlclose(_coreGraphics);
    if (_hiServices) dlclose(_hiServices);
    if (_skyLight) dlclose(_skyLight);
}
@end

@class VirtualMouseController;
static CGEventRef VirtualMouseTapCallback(CGEventTapProxy proxy,
                                          CGEventType type,
                                          CGEventRef event,
                                          void *userInfo);

@interface VirtualMouseController : NSObject
@property(nonatomic, readonly) CGPoint position;
@property(nonatomic, copy) void (^positionChanged)(CGPoint position);
- (BOOL)start;
- (void)stop;
@end

@implementation VirtualMouseController {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
    CGPoint _position;
    CGPoint _physicalPosition;
    BOOL _active;
}

- (CGPoint)position { return _position; }

- (BOOL)start {
    if (_active) return YES;
    CGEventRef currentEvent = CGEventCreate(NULL);
    if (!currentEvent) return NO;
    _position = CGEventGetLocation(currentEvent);
    _physicalPosition = _position;
    CFRelease(currentEvent);

    CGEventMask mask = (CGEventMaskBit(kCGEventMouseMoved) |
                        CGEventMaskBit(kCGEventLeftMouseDown) |
                        CGEventMaskBit(kCGEventLeftMouseUp) |
                        CGEventMaskBit(kCGEventLeftMouseDragged) |
                        CGEventMaskBit(kCGEventRightMouseDown) |
                        CGEventMaskBit(kCGEventRightMouseUp) |
                        CGEventMaskBit(kCGEventRightMouseDragged) |
                        CGEventMaskBit(kCGEventOtherMouseDown) |
                        CGEventMaskBit(kCGEventOtherMouseUp) |
                        CGEventMaskBit(kCGEventOtherMouseDragged) |
                        CGEventMaskBit(kCGEventScrollWheel));
    _tap = CGEventTapCreate(kCGSessionEventTap,
                            kCGHeadInsertEventTap,
                            kCGEventTapOptionDefault,
                            mask,
                            VirtualMouseTapCallback,
                            (__bridge void *)self);
    if (!_tap) return NO;
    _source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);

    // Keep the hardware cursor in an unused desktop coordinate. The event tap
    // rewrites mouse events to _position, so the visible custom pointer stays
    // interactive even though the physical cursor is no longer following it.
    CGWarpMouseCursorPosition(CGPointMake(-2000, -2000));
    CGAssociateMouseAndMouseCursorPosition(false);
    _active = YES;
    if (self.positionChanged) self.positionChanged(_position);
    return YES;
}

- (void)stop {
    if (!_active) return;
    _active = NO;
    if (_tap) CGEventTapEnable(_tap, false);
    if (_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRelease(_source);
        _source = NULL;
    }
    if (_tap) {
        CFRelease(_tap);
        _tap = NULL;
    }
    CGAssociateMouseAndMouseCursorPosition(true);
    CGWarpMouseCursorPosition(_position);
}

- (CGEventRef)handleEventType:(CGEventType)type event:(CGEventRef)event {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (_tap) CGEventTapEnable(_tap, true);
        return event;
    }
    if (!_active) return event;

    BOOL movesPointer = (type == kCGEventMouseMoved ||
                         type == kCGEventLeftMouseDragged ||
                         type == kCGEventRightMouseDragged ||
                         type == kCGEventOtherMouseDragged);
    if (movesPointer) {
        _position.x += CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
        _position.y += CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
        if (self.positionChanged) self.positionChanged(_position);
    }
    CGEventSetLocation(event, _position);
    return event;
}

- (void)dealloc { [self stop]; }
@end

static CGEventRef VirtualMouseTapCallback(__unused CGEventTapProxy proxy,
                                          CGEventType type,
                                          CGEventRef event,
                                          void *userInfo) {
    VirtualMouseController *controller = (__bridge VirtualMouseController *)userInfo;
    return [controller handleEventType:type event:event];
}

static const CGFloat kSourceWidth = 714.0;
static const CGFloat kSourceHeight = 1652.0;
static const CGFloat kHotspotX = 104.0;
static const CGFloat kHotspotYFromTop = 16.0;
// The longest cursor can sweep ~36 pt sideways during the tap at the largest
// size. Leave more room than that so its artwork is never clipped.
static const CGFloat kTapOverflow = 64.0;

@interface PresentationShieldPanel : NSPanel
@property(nonatomic, copy) dispatch_block_t gestureHandler;
@end

@implementation PresentationShieldPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)scrollWheel:(NSEvent *)event { (void)event; if (self.gestureHandler) self.gestureHandler(); }
- (void)swipeWithEvent:(NSEvent *)event { (void)event; if (self.gestureHandler) self.gestureHandler(); }
- (void)magnifyWithEvent:(NSEvent *)event { (void)event; if (self.gestureHandler) self.gestureHandler(); }
- (void)rotateWithEvent:(NSEvent *)event { (void)event; if (self.gestureHandler) self.gestureHandler(); }
@end

@class PresentationEventFilter;
static CGEventRef PresentationEventTapCallback(CGEventTapProxy proxy,
                                               CGEventType type,
                                               CGEventRef event,
                                               void *userInfo);

@interface PresentationEventFilter : NSObject
@property(nonatomic, copy) void (^clickHandler)(CGPoint position);
- (BOOL)start;
- (void)stop;
@end

@implementation PresentationEventFilter {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _source;
    BOOL _spaceDown;
}

- (BOOL)start {
    if (_tap) return YES;
    CGEventMask mask = (CGEventMaskBit(kCGEventLeftMouseDown) |
                        CGEventMaskBit(kCGEventLeftMouseUp) |
                        CGEventMaskBit(kCGEventLeftMouseDragged) |
                        CGEventMaskBit(kCGEventRightMouseDown) |
                        CGEventMaskBit(kCGEventRightMouseUp) |
                        CGEventMaskBit(kCGEventRightMouseDragged) |
                        CGEventMaskBit(kCGEventOtherMouseDown) |
                        CGEventMaskBit(kCGEventOtherMouseUp) |
                        CGEventMaskBit(kCGEventOtherMouseDragged) |
                        CGEventMaskBit(kCGEventKeyDown) |
                        CGEventMaskBit(kCGEventKeyUp));
    _tap = CGEventTapCreate(kCGSessionEventTap,
                            kCGHeadInsertEventTap,
                            kCGEventTapOptionDefault,
                            mask,
                            PresentationEventTapCallback,
                            (__bridge void *)self);
    if (!_tap) return NO;
    _source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    return YES;
}

- (void)stop {
    if (_source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), _source, kCFRunLoopCommonModes);
        CFRelease(_source);
        _source = NULL;
    }
    if (_tap) {
        CFRelease(_tap);
        _tap = NULL;
    }
    _spaceDown = NO;
}

- (CGEventRef)handleEventType:(CGEventType)type event:(CGEventRef)event {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (_tap) CGEventTapEnable(_tap, true);
        return event;
    }
    if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        if (CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode) == kVK_Space) {
            _spaceDown = (type == kCGEventKeyDown);
        }
        return event;
    }
    if ((type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown ||
         type == kCGEventOtherMouseDown) && self.clickHandler) {
        self.clickHandler(CGEventGetLocation(event));
    }
    return _spaceDown ? event : NULL;
}

- (void)dealloc { [self stop]; }
@end

static CGEventRef PresentationEventTapCallback(__unused CGEventTapProxy proxy,
                                               CGEventType type,
                                               CGEventRef event,
                                               void *userInfo) {
    PresentationEventFilter *filter = (__bridge PresentationEventFilter *)userInfo;
    return [filter handleEventType:type event:event];
}

@interface CursorOverlayController : NSObject
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, readonly, getter=isPresentationEnabled) BOOL presentationEnabled;
@property(nonatomic) CGFloat height;
@property(nonatomic, readonly) NSInteger cursorStyle;
@property(nonatomic, readonly, getter=isClickSoundEnabled) BOOL clickSoundEnabled;
@property(nonatomic, readonly) CGFloat clickSoundVolume;
- (void)toggle;
- (void)togglePresentation;
- (void)enable;
- (void)disable;
- (void)setCursorStyle:(NSInteger)style;
- (void)setClickSoundEnabled:(BOOL)enabled;
- (void)setClickSoundVolume:(CGFloat)volume;
@end

@implementation CursorOverlayController {
    NSWindow *_window;
    NSImageView *_imageView;
    NSTimer *_timer;
    BOOL _enabled;
    BOOL _quartzCursorHidden;
    BOOL _appKitCursorHidden;
    BOOL _wasMouseButtonDown;
    CFTimeInterval _clickAnimationStart;
    CGFloat _animationScale;
    CFTimeInterval _lastCursorRefresh;
    SystemCursorController *_systemCursorController;
    VirtualMouseController *_virtualMouse;
    BOOL _usesVirtualMouse;
    NSPoint _virtualMouseLocation;
    BOOL _presentationEnabled;
    NSMutableArray<PresentationShieldPanel *> *_presentationShields;
    NSUInteger _presentationGestureGeneration;
    PresentationEventFilter *_presentationFilter;
    NSInteger _cursorStyle;
    NSSize _cursorSourceSize;
    CGFloat _hotspotX;
    CGFloat _hotspotYFromTop;
    NSArray<AVAudioPlayer *> *_clickSounds;
    NSUInteger _nextClickSoundIndex;
    NSWindow *_clickEffectWindow;
    NSImageView *_clickEffectView;
    NSUInteger _clickEffectGeneration;
    NSPoint _clickEffectAnchor;
    CFTimeInterval _clickEffectVisibleUntil;
    CFTimeInterval _lastClickTime;
    BOOL _clickSoundEnabled;
    CGFloat _clickSoundVolume;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    double storedHeight = [[NSUserDefaults standardUserDefaults] doubleForKey:@"cursorHeight"];
    _height = storedHeight > 0 ? storedHeight : 480.0;
    _animationScale = 1.0;
    _cursorStyle = [[NSUserDefaults standardUserDefaults] integerForKey:@"cursorStyle"];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    _clickSoundEnabled = [defaults objectForKey:@"clickSoundEnabled"] ?
        [defaults boolForKey:@"clickSoundEnabled"] : YES;
    double storedVolume = [defaults doubleForKey:@"clickSoundVolume"];
    _clickSoundVolume = storedVolume > 0.0 ? MIN(MAX(storedVolume, 0.05), 1.0) : 0.25;
    _systemCursorController = [SystemCursorController new];
    _presentationShields = [NSMutableArray array];

    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1, 1)
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.opaque = NO;
    _window.backgroundColor = NSColor.clearColor;
    _window.hasShadow = NO;
    _window.ignoresMouseEvents = YES;
    // The custom pointer sits one public WindowServer level above the native
    // cursor. This also masks the native cursor on macOS versions that ignore
    // hide requests made by background/menu-bar applications.
    _window.level = (NSWindowLevel)CGWindowLevelForKey(kCGMaximumWindowLevelKey);
    _window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                 NSWindowCollectionBehaviorFullScreenAuxiliary |
                                 NSWindowCollectionBehaviorStationary;

    _imageView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 1, 1)];
    _imageView.imageScaling = NSImageScaleAxesIndependently;
    _imageView.imageAlignment = NSImageAlignCenter;
    _imageView.wantsLayer = YES;
    _window.contentView = _imageView;
    [self setCursorStyle:_cursorStyle];
    NSString *soundPath = [[NSBundle mainBundle] pathForResource:@"quiet-banging" ofType:@"mp3"];
    if (soundPath) {
        // A pool prevents a fast second click from cutting off the first one.
        NSMutableArray<AVAudioPlayer *> *sounds = [NSMutableArray array];
        for (NSUInteger index = 0; index < 5; index++) {
            NSError *error = nil;
            AVAudioPlayer *sound = [[AVAudioPlayer alloc]
                initWithContentsOfURL:[NSURL fileURLWithPath:soundPath] error:&error];
            if (sound) {
                sound.volume = _clickSoundVolume;
                [sound prepareToPlay];
                [sounds addObject:sound];
            }
        }
        _clickSounds = sounds;
    }
    NSString *effectPath = [[NSBundle mainBundle] pathForResource:@"Flash Burst" ofType:@"png"];
    if (effectPath) {
        _clickEffectWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 76, 76)
                                                          styleMask:NSWindowStyleMaskBorderless
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO];
        _clickEffectWindow.opaque = NO;
        _clickEffectWindow.backgroundColor = NSColor.clearColor;
        _clickEffectWindow.hasShadow = NO;
        _clickEffectWindow.ignoresMouseEvents = YES;
        _clickEffectWindow.level = (NSWindowLevel)CGWindowLevelForKey(kCGMaximumWindowLevelKey);
        _clickEffectWindow.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                                 NSWindowCollectionBehaviorFullScreenAuxiliary |
                                                 NSWindowCollectionBehaviorStationary;
        _clickEffectView = [[NSImageView alloc] initWithFrame:_clickEffectWindow.contentView.bounds];
        _clickEffectView.image = [[NSImage alloc] initWithContentsOfFile:effectPath];
        _clickEffectView.imageScaling = NSImageScaleProportionallyUpOrDown;
        _clickEffectView.imageAlignment = NSImageAlignCenter;
        _clickEffectView.wantsLayer = YES;
        _clickEffectWindow.contentView = _clickEffectView;
    }

    [self updateWindowSize];
    return self;
}

- (BOOL)isEnabled { return _enabled; }
- (BOOL)isPresentationEnabled { return _presentationEnabled; }
- (NSInteger)cursorStyle { return _cursorStyle; }
- (BOOL)isClickSoundEnabled { return _clickSoundEnabled; }
- (CGFloat)clickSoundVolume { return _clickSoundVolume; }

- (void)setClickSoundEnabled:(BOOL)enabled {
    _clickSoundEnabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"clickSoundEnabled"];
}

- (void)setClickSoundVolume:(CGFloat)volume {
    _clickSoundVolume = MIN(MAX(volume, 0.05), 1.0);
    for (AVAudioPlayer *sound in _clickSounds) sound.volume = _clickSoundVolume;
    [[NSUserDefaults standardUserDefaults] setDouble:_clickSoundVolume forKey:@"clickSoundVolume"];
}

- (void)triggerClickAtPosition:(NSPoint)clickPosition {
    CFTimeInterval now = CACurrentMediaTime();
    _clickAnimationStart = now;
    // A presentation-mode event tap can arrive just before the regular frame
    // tracker sees the same physical press. Mark it handled to avoid a second
    // click (which would otherwise show the effect immediately).
    _wasMouseButtonDown = YES;
    if (_clickSoundEnabled && _clickSounds.count > 0) {
        AVAudioPlayer *sound = _clickSounds[_nextClickSoundIndex % _clickSounds.count];
        _nextClickSoundIndex++;
        sound.currentTime = 0.0;
        [sound play];
    }
    // A lone click stays quiet visually. The burst appears only from the
    // second click of a quick series, so repeated tapping gets feedback.
    if (_lastClickTime > 0 && now - _lastClickTime <= 0.40) {
        [self showClickEffectAtPosition:clickPosition];
    }
    _lastClickTime = now;
}

- (void)showClickEffectAtPosition:(NSPoint)clickPosition {
    if (!_clickEffectWindow) return;
    NSSize size = _clickEffectWindow.frame.size;
    _clickEffectAnchor = NSMakePoint(clickPosition.x - size.width / 2.0,
                                     clickPosition.y - size.height / 2.0);
    _clickEffectVisibleUntil = CACurrentMediaTime() + 0.33;
    CALayer *layer = _clickEffectView.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.opacity = 0.0;
    [CATransaction commit];
    [_clickEffectWindow setFrameOrigin:_clickEffectAnchor];
    [_clickEffectWindow orderFrontRegardless];
    [_window orderFrontRegardless]; // Keep the cursor above the burst.

    [layer removeAllAnimations];
    CAKeyframeAnimation *opacity = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    opacity.values = @[@0.0, @0.95, @0.0];
    opacity.keyTimes = @[@0.0, @0.24, @1.0];
    opacity.duration = 0.30;
    opacity.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:opacity forKey:@"magicCursorClickEffect"];
    NSUInteger generation = ++_clickEffectGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.33 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self && generation == self->_clickEffectGeneration) [self->_clickEffectWindow orderOut:nil];
    });
}

- (void)setCursorStyle:(NSInteger)style {
    if (style < 0 || style > 5) style = 0;
    NSArray<NSString *> *resources = @[@"finger-new", @"fuck-new", @"nail", @"paw-new", @"lego", @"fist"];
    NSArray<NSArray<NSNumber *> *> *hotspots = @[
        @[@42.0, @32.0], @[@30.0, @28.0], @[@35.0, @29.0],
        @[@43.0, @40.0], @[@35.0, @22.0], @[@40.0, @26.0]
    ];
    NSString *imagePath = [[NSBundle mainBundle] pathForResource:resources[(NSUInteger)style] ofType:@"png"];
    NSImage *image = imagePath ? [[NSImage alloc] initWithContentsOfFile:imagePath] : nil;
    if (!image) return;
    _cursorStyle = style;
    _cursorSourceSize = image.size;
    _hotspotX = hotspots[(NSUInteger)style][0].doubleValue;
    _hotspotYFromTop = hotspots[(NSUInteger)style][1].doubleValue;
    _imageView.image = image;
    [[NSUserDefaults standardUserDefaults] setInteger:style forKey:@"cursorStyle"];
    [self updateWindowSize];
}

- (void)setHeight:(CGFloat)height {
    _height = MIN(MAX(height, 72.0), 520.0);
    [[NSUserDefaults standardUserDefaults] setDouble:_height forKey:@"cursorHeight"];
    [self updateWindowSize];
}

- (void)toggle { self.enabled ? [self disable] : [self enable]; }

- (void)togglePresentation {
    if (_presentationEnabled) {
        _presentationEnabled = NO;
        [_presentationFilter stop];
        return;
    }
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Для режима презентации нужен «Универсальный доступ»";
        alert.informativeText = @"Включи Пикми в Системные настройки → Конфиденциальность и безопасность → Универсальный доступ, затем снова нажми ⌃⌥L.";
        [alert addButtonWithTitle:@"Понятно"];
        [alert runModal];
        return;
    }
    if (!_presentationFilter) _presentationFilter = [PresentationEventFilter new];
    __weak typeof(self) weakSelf = self;
    _presentationFilter.clickHandler = ^(CGPoint position) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self) [self triggerClickAtPosition:[self appKitPointFromCGPosition:position]];
    };
    if (![_presentationFilter start]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Не удалось включить фильтр кликов";
        alert.informativeText = @"Проверь разрешение «Универсальный доступ» для Пикми.";
        [alert runModal];
        return;
    }
    _presentationEnabled = YES;
}

- (void)enable {
    if (_enabled) return;
    _enabled = YES;
    _wasMouseButtonDown = [self isAnyMouseButtonDown];
    _lastClickTime = 0;
    _animationScale = 1.0;

    // Apple documents that CGDisplayHideCursor normally affects the cursor
    // only when its caller is the foreground application. Magic Cursor is a
    // menu-bar agent, so briefly activate it, hide the cursor, and immediately
    // return focus to the application the user was working in.
    NSRunningApplication *previousApplication = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (previousApplication.processIdentifier == NSRunningApplication.currentApplication.processIdentifier) {
        [self finishEnabling];
        return;
    }

    [NSApp activateIgnoringOtherApps:YES];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self && self->_enabled) [self finishEnabling];
        if (previousApplication && !previousApplication.terminated) {
            [previousApplication activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        }
        // Returning focus can make WindowServer or Dock immediately publish
        // the native cursor again. Re-register after that transition and a
        // few more times while the focus/cursor state settles.
        [self scheduleCursorReplacementAfterDelay:0.08];
        [self scheduleCursorReplacementAfterDelay:0.30];
        [self scheduleCursorReplacementAfterDelay:1.00];
    });
}

- (BOOL)startVirtualMouse {
    NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Нужен доступ «Универсальный доступ»";
        alert.informativeText = @"Включи Пикми в Системные настройки → Конфиденциальность и безопасность → Универсальный доступ, затем снова нажми ⌃⌥P.";
        [alert addButtonWithTitle:@"Понятно"];
        [alert runModal];
        return NO;
    }
    if (!_virtualMouse) _virtualMouse = [VirtualMouseController new];
    __weak typeof(self) weakSelf = self;
    _virtualMouse.positionChanged = ^(CGPoint position) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self->_virtualMouseLocation = [self appKitPointFromCGPosition:position];
        [self updatePosition];
    };
    if (![_virtualMouse start]) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Не удалось включить виртуальный курсор";
        alert.informativeText = @"Проверь, что Пикми включён в «Универсальный доступ», затем попробуй ещё раз.";
        [alert runModal];
        return NO;
    }
    _usesVirtualMouse = YES;
    _virtualMouseLocation = [self appKitPointFromCGPosition:_virtualMouse.position];
    return YES;
}

- (void)scheduleCursorReplacementAfterDelay:(NSTimeInterval)delay {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (self && self->_enabled) {
            [self->_systemCursorController reapplyTransparentCursors];
        }
    });
}

- (void)finishEnabling {
    [_systemCursorController replaceWithTransparentCursors];
    [self hideSystemCursor];
    [self updateFrame];
    [_window orderFrontRegardless];

    if (_timer) return;

    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:(1.0 / 120.0)
                                    repeats:YES
                                      block:^(__unused NSTimer *timer) {
        [weakSelf updateFrame];
    }];
    [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)disable {
    if (!_enabled) return;
    _enabled = NO;
    _lastClickTime = 0;
    [_timer invalidate];
    _timer = nil;
    _animationScale = 1.0;
    _imageView.alphaValue = 1.0;
    [_window orderOut:nil];
    [_clickEffectWindow orderOut:nil];
    _presentationEnabled = NO;
    [_presentationFilter stop];
    [_virtualMouse stop];
    _usesVirtualMouse = NO;
    [_systemCursorController restoreOriginalCursors];
    [self showSystemCursor];
}

- (void)showPresentationShields {
    [self hidePresentationShields];
    for (NSScreen *screen in NSScreen.screens) {
        PresentationShieldPanel *shield = [[PresentationShieldPanel alloc]
            initWithContentRect:screen.frame
                      styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        shield.opaque = NO;
        shield.backgroundColor = NSColor.clearColor;
        shield.hasShadow = NO;
        shield.ignoresMouseEvents = NO;
        shield.level = (NSWindowLevel)CGWindowLevelForKey(kCGMaximumWindowLevelKey);
        shield.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary |
                                   NSWindowCollectionBehaviorStationary;
        __weak typeof(self) weakSelf = self;
        shield.gestureHandler = ^{ [weakSelf allowPresentationGesture]; };
        shield.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0,
                                                                        screen.frame.size.width,
                                                                        screen.frame.size.height)];
        [shield orderFrontRegardless];
        [_presentationShields addObject:shield];
    }
    // Keep the visible wand above the transparent click shield.
    [_window orderFrontRegardless];
}

- (void)allowPresentationGesture {
    if (!_presentationEnabled) return;
    for (PresentationShieldPanel *shield in _presentationShields) shield.ignoresMouseEvents = YES;
    NSUInteger generation = ++_presentationGestureGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self->_presentationEnabled || generation != self->_presentationGestureGeneration) return;
        for (PresentationShieldPanel *shield in self->_presentationShields) shield.ignoresMouseEvents = NO;
    });
}

- (void)hidePresentationShields {
    for (PresentationShieldPanel *shield in _presentationShields) [shield orderOut:nil];
    [_presentationShields removeAllObjects];
    _presentationGestureGeneration++;
}

- (void)updateWindowSize {
    CGFloat displayHeight = _height;
    CGFloat sourceHeight = _cursorSourceSize.height > 0 ? _cursorSourceSize.height : kSourceHeight;
    CGFloat sourceWidth = _cursorSourceSize.width > 0 ? _cursorSourceSize.width : kSourceWidth;
    CGFloat scale = displayHeight / sourceHeight;
    NSSize artworkSize = NSMakeSize(sourceWidth * scale, displayHeight);
    NSSize size = NSMakeSize(artworkSize.width + (kTapOverflow * 2.0),
                             artworkSize.height + (kTapOverflow * 2.0));
    [_window setContentSize:size];
    _imageView.frame = NSMakeRect(kTapOverflow, kTapOverflow, artworkSize.width, artworkSize.height);
    // Transform around the cursor tip, so a click feels like a tap rather
    // than shrinking the whole drawing from its center.
    CGPoint anchor = CGPointMake(_hotspotX / sourceWidth,
                                 1.0 - (_hotspotYFromTop / sourceHeight));
    _imageView.layer.anchorPoint = anchor;
    _imageView.layer.position = CGPointMake(kTapOverflow + anchor.x * artworkSize.width,
                                            kTapOverflow + anchor.y * artworkSize.height);
    if (_enabled) [self updatePosition];
}

- (void)updateFrame {
    [_systemCursorController ensureCursorHiddenInBackground];
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastCursorRefresh >= (1.0 / 30.0)) {
        [_systemCursorController refreshActiveCursor];
        _lastCursorRefresh = now;
    }
    BOOL mouseButtonDown = [self isAnyMouseButtonDown];
    if (mouseButtonDown && !_wasMouseButtonDown) {
        [self triggerClickAtPosition:NSEvent.mouseLocation];
    }
    _wasMouseButtonDown = mouseButtonDown;

    [self updateClickAnimation];
    [self updatePosition];
}

- (BOOL)isAnyMouseButtonDown {
    return CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
           CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight) ||
           CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonCenter);
}

- (void)updateClickAnimation {
    static const CFTimeInterval duration = 0.34;
    CFTimeInterval elapsed = CACurrentMediaTime() - _clickAnimationStart;
    if (_clickAnimationStart <= 0 || elapsed >= duration) {
        _animationScale = 1.0;
        _imageView.alphaValue = 1.0;
        _imageView.layer.affineTransform = CGAffineTransformIdentity;
        return;
    }

    CGFloat progress = elapsed / duration;
    CGFloat thrust;
    if (progress < 0.16) {
        thrust = [self smoothStepFrom:0.0 to:1.0 progress:(progress / 0.16)];
    } else if (progress < 0.42) {
        thrust = [self smoothStepFrom:1.0 to:-0.22 progress:((progress - 0.16) / 0.26)];
    } else {
        thrust = [self smoothStepFrom:-0.22 to:0.0 progress:((progress - 0.42) / 0.58)];
    }
    // A small forward stroke and rotation, pivoted at the cursor tip.
    // No global scaling: the artwork keeps its size throughout the click.
    CGFloat sideways = -2.0 * thrust;
    CGFloat forward = 12.0 * thrust;
    CGAffineTransform tap = CGAffineTransformMakeTranslation(sideways, forward);
    tap = CGAffineTransformRotate(tap, -0.025 * thrust);
    _imageView.layer.affineTransform = tap;
    _animationScale = 1.0;
    _imageView.alphaValue = 1.0;
}

- (CGFloat)smoothStepFrom:(CGFloat)from to:(CGFloat)to progress:(CGFloat)progress {
    CGFloat clamped = MIN(MAX(progress, 0.0), 1.0);
    CGFloat eased = clamped * clamped * (3.0 - 2.0 * clamped);
    return from + (to - from) * eased;
}

- (void)updatePosition {
    NSPoint mouse = _usesVirtualMouse ? _virtualMouseLocation : NSEvent.mouseLocation;
    CGFloat sourceHeight = _cursorSourceSize.height > 0 ? _cursorSourceSize.height : kSourceHeight;
    CGFloat scale = _height / sourceHeight;
    NSPoint hotspot = NSMakePoint(_hotspotX * scale, _hotspotYFromTop * scale);
    NSPoint origin = NSMakePoint(mouse.x - (kTapOverflow + hotspot.x),
                                mouse.y - (_window.frame.size.height - kTapOverflow - hotspot.y));
    [_window setFrameOrigin:origin];
}

- (NSPoint)appKitPointFromCGPosition:(CGPoint)position {
    NSScreen *screen = NSScreen.mainScreen;
    return NSMakePoint(position.x, NSMaxY(screen.frame) - position.y);
}

- (void)hideSystemCursor {
    [_systemCursorController setBackgroundCursorHidingAllowed:YES];
    if (!_quartzCursorHidden && [_systemCursorController cursorIsVisible] &&
        CGDisplayHideCursor(CGMainDisplayID()) == kCGErrorSuccess) {
        _quartzCursorHidden = YES;
    }
    if (!_appKitCursorHidden) {
        [NSCursor hide];
        _appKitCursorHidden = YES;
    }
}

- (void)showSystemCursor {
    [_systemCursorController setBackgroundCursorHidingAllowed:NO];
    if (_appKitCursorHidden) {
        [NSCursor unhide];
        _appKitCursorHidden = NO;
    }
    if (_quartzCursorHidden) {
        // The tracker may have hidden the cursor more than once after the
        // WindowServer re-shows it during motion. Balance only until it is
        // visible again, so we do not interfere with other clients.
        for (NSUInteger attempt = 0;
             attempt < 8 && ![_systemCursorController cursorIsVisible];
             attempt++) {
            CGDisplayShowCursor(CGMainDisplayID());
        }
        _quartzCursorHidden = NO;
    }
}

- (void)dealloc {
    [_timer invalidate];
    [_systemCursorController restoreOriginalCursors];
    [self showSystemCursor];
}
@end

@class HotKeyManager;

static OSStatus MagicCursorHotKeyCallback(EventHandlerCallRef nextHandler,
                                           EventRef event,
                                           void *userData);

@interface HotKeyManager : NSObject
@property(nonatomic, copy) dispatch_block_t action;
@property(nonatomic, copy) dispatch_block_t presentationAction;
- (instancetype)initWithAction:(dispatch_block_t)action
             presentationAction:(dispatch_block_t)presentationAction;
@end

@implementation HotKeyManager {
    EventHotKeyRef _hotKey;
    EventHotKeyRef _presentationHotKey;
    EventHandlerRef _handler;
}

- (instancetype)initWithAction:(dispatch_block_t)action
             presentationAction:(dispatch_block_t)presentationAction {
    self = [super init];
    if (!self) return nil;
    _action = [action copy];
    _presentationAction = [presentationAction copy];

    EventTypeSpec eventType = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallEventHandler(GetApplicationEventTarget(),
                        MagicCursorHotKeyCallback,
                        1,
                        &eventType,
                        (__bridge void *)self,
                        &_handler);

    EventHotKeyID identifier = {'MCUR', 1};
    RegisterEventHotKey(kVK_ANSI_P,
                        controlKey | optionKey,
                        identifier,
                        GetApplicationEventTarget(),
                        0,
                        &_hotKey);
    EventHotKeyID presentationIdentifier = {'MCUR', 2};
    RegisterEventHotKey(kVK_ANSI_L,
                        controlKey | optionKey,
                        presentationIdentifier,
                        GetApplicationEventTarget(),
                        0,
                        &_presentationHotKey);
    return self;
}

- (void)dealloc {
    if (_hotKey) UnregisterEventHotKey(_hotKey);
    if (_presentationHotKey) UnregisterEventHotKey(_presentationHotKey);
    if (_handler) RemoveEventHandler(_handler);
}
@end

static OSStatus MagicCursorHotKeyCallback(__unused EventHandlerCallRef nextHandler,
                                           EventRef event,
                                           void *userData) {
    EventHotKeyID identifier = {0};
    OSStatus status = GetEventParameter(event,
                                        kEventParamDirectObject,
                                        typeEventHotKeyID,
                                        NULL,
                                        sizeof(identifier),
                                        NULL,
                                        &identifier);
    if (status != noErr) return eventNotHandledErr;
    HotKeyManager *manager = (__bridge HotKeyManager *)userData;
    if (identifier.id == 1 && manager.action) manager.action();
    else if (identifier.id == 2 && manager.presentationAction) manager.presentationAction();
    else return eventNotHandledErr;
    return noErr;
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    CursorOverlayController *_overlay;
    NSStatusItem *_statusItem;
    NSMenuItem *_toggleMenuItem;
    NSMenuItem *_presentationMenuItem;
    NSMutableArray<NSMenuItem *> *_sizeItems;
    NSMutableArray<NSMenuItem *> *_cursorStyleItems;
    NSMenuItem *_clickSoundMenuItem;
    NSMutableArray<NSMenuItem *> *_soundVolumeItems;
    HotKeyManager *_hotKeyManager;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _overlay = [CursorOverlayController new];
    _sizeItems = [NSMutableArray array];
    _cursorStyleItems = [NSMutableArray array];
    _soundVolumeItems = [NSMutableArray array];
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self configureStatusItem];
    __weak typeof(self) weakSelf = self;
    _hotKeyManager = [[HotKeyManager alloc] initWithAction:^{ [weakSelf toggleCursor]; }
                                          presentationAction:^{ [weakSelf togglePresentation]; }];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--presentation"]) {
        [_overlay togglePresentation];
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--enable"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf toggleCursor]; });
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [_overlay disable];
}

- (void)configureStatusItem {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:28.0];
    NSStatusBarButton *button = _statusItem.button;
    NSString *menuIconPath = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Finger.png"];
    NSImage *menuIcon = [[NSImage alloc] initWithContentsOfFile:menuIconPath];
    menuIcon.size = NSMakeSize(24, 24);
    menuIcon.template = YES;
    button.title = @"";
    button.imagePosition = NSImageOnly;
    button.image = menuIcon;
    button.toolTip = @"Пикми — ⌃⌥P; презентация — ⌃⌥L";
    button.appearsDisabled = YES;

    NSMenu *menu = [NSMenu new];
    _toggleMenuItem = [[NSMenuItem alloc] initWithTitle:@"Включить курсор"
                                                action:@selector(toggleCursor)
                                         keyEquivalent:@"p"];
    _toggleMenuItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    _toggleMenuItem.target = self;
    [menu addItem:_toggleMenuItem];

    _presentationMenuItem = [[NSMenuItem alloc] initWithTitle:@"Режим презентации"
                                                        action:@selector(togglePresentation)
                                                 keyEquivalent:@"l"];
    _presentationMenuItem.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption;
    _presentationMenuItem.target = self;
    [menu addItem:_presentationMenuItem];

    NSMenu *cursorStyleMenu = [NSMenu new];
    NSArray<NSString *> *cursorStyles = @[@"Пальчик", @"Фак", @"Ноготочек", @"Лапка", @"Лего", @"Кулачок"];
    for (NSUInteger index = 0; index < cursorStyles.count; index++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:cursorStyles[index]
                                                       action:@selector(changeCursorStyle:)
                                                keyEquivalent:@""];
        item.target = self;
        item.tag = (NSInteger)index;
        [_cursorStyleItems addObject:item];
        [cursorStyleMenu addItem:item];
    }
    NSMenuItem *cursorStyleRoot = [[NSMenuItem alloc] initWithTitle:@"Вид курсора" action:nil keyEquivalent:@""];
    cursorStyleRoot.submenu = cursorStyleMenu;
    [menu addItem:cursorStyleRoot];
    [self updateCursorStyleChecks];

    NSMenu *soundMenu = [NSMenu new];
    _clickSoundMenuItem = [[NSMenuItem alloc] initWithTitle:@"Включить звук"
                                                     action:@selector(toggleClickSound:)
                                              keyEquivalent:@""];
    _clickSoundMenuItem.target = self;
    [soundMenu addItem:_clickSoundMenuItem];
    [soundMenu addItem:NSMenuItem.separatorItem];
    NSArray<NSArray *> *volumes = @[@[@"Громкость: 25%", @0.25],
                                    @[@"Громкость: 50%", @0.50],
                                    @[@"Громкость: 75%", @0.75],
                                    @[@"Громкость: 100%", @1.0]];
    for (NSArray *entry in volumes) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0]
                                                       action:@selector(changeClickSoundVolume:)
                                                keyEquivalent:@""];
        item.target = self;
        item.representedObject = entry[1];
        [_soundVolumeItems addObject:item];
        [soundMenu addItem:item];
    }
    NSMenuItem *soundRoot = [[NSMenuItem alloc] initWithTitle:@"Звук клика" action:nil keyEquivalent:@""];
    soundRoot.submenu = soundMenu;
    [menu addItem:soundRoot];
    [self updateClickSoundChecks];

    NSMenu *sizeMenu = [NSMenu new];
    NSArray<NSArray *> *sizes = @[@[@"Огромный", @240.0],
                                  @[@"Гигантский", @320.0],
                                  @[@"Максимальный", @480.0]];
    for (NSArray *entry in sizes) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[0]
                                                     action:@selector(changeSize:)
                                              keyEquivalent:@""];
        item.target = self;
        item.representedObject = entry[1];
        [_sizeItems addObject:item];
        [sizeMenu addItem:item];
    }
    NSMenuItem *sizeRoot = [[NSMenuItem alloc] initWithTitle:@"Размер" action:nil keyEquivalent:@""];
    sizeRoot.submenu = sizeMenu;
    [menu addItem:sizeRoot];
    [self updateSizeChecks];

    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Завершить Пикми"
                                                  action:@selector(quitApplication:)
                                           keyEquivalent:@""];
    quit.keyEquivalentModifierMask = 0;
    quit.image = nil;
    quit.target = self;
    [menu addItem:quit];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *author = [[NSMenuItem alloc] initWithTitle:@"Автор @serezhaivlev"
                                                    action:nil
                                             keyEquivalent:@""];
    author.enabled = NO;
    [menu addItem:author];
    _statusItem.menu = menu;
}

- (void)toggleCursor {
    [_overlay toggle];
    _toggleMenuItem.title = _overlay.enabled ? @"Выключить курсор" : @"Включить курсор";
    _statusItem.button.appearsDisabled = !_overlay.enabled;
}

- (void)togglePresentation {
    [_overlay togglePresentation];
    _presentationMenuItem.state = _overlay.presentationEnabled ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)changeSize:(NSMenuItem *)sender {
    _overlay.height = [sender.representedObject doubleValue];
    [self updateSizeChecks];
}

- (void)quitApplication:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)changeCursorStyle:(NSMenuItem *)sender {
    [_overlay setCursorStyle:sender.tag];
    [self updateCursorStyleChecks];
}

- (void)toggleClickSound:(NSMenuItem *)sender {
    (void)sender;
    [_overlay setClickSoundEnabled:!_overlay.clickSoundEnabled];
    [self updateClickSoundChecks];
}

- (void)changeClickSoundVolume:(NSMenuItem *)sender {
    [_overlay setClickSoundVolume:[sender.representedObject doubleValue]];
    [self updateClickSoundChecks];
}

- (void)updateSizeChecks {
    for (NSMenuItem *item in _sizeItems) {
        item.state = fabs([item.representedObject doubleValue] - _overlay.height) < 1.0
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)updateCursorStyleChecks {
    for (NSMenuItem *item in _cursorStyleItems) {
        item.state = item.tag == _overlay.cursorStyle ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)updateClickSoundChecks {
    _clickSoundMenuItem.state = _overlay.clickSoundEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    for (NSMenuItem *item in _soundVolumeItems) {
        item.state = fabs([item.representedObject doubleValue] - _overlay.clickSoundVolume) < 0.01
            ? NSControlStateValueOn : NSControlStateValueOff;
    }
}
@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
