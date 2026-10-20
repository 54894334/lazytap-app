//
//  LTHID.m  —  触摸注入调度层（v1.1）
//
//  v1.0.1 的问题：只走 IOHID 一条路，而 IOHID 派发要宿主进程主二进制带
//  com.apple.private.hid.client.event-dispatch。TrollStore / ESign 注入 App Store
//  应用时宿主没有这条权限，事件被内核静默丢弃 —— 表现就是「计数在涨、点了没反应」。
//
//  v1.1 改成双通道：
//    · 默认走进程内触摸合成（LTUITouch.m），不需要任何 entitlement，一定生效
//    · HID 保留为可选通道，宿主带权限时能用（面板里可切）
//
//  另外修正了 IOHIDEventCreateDigitizerFingerEventWithQuality 的参数顺序：
//  真实签名是 x,y,z,tipPressure,twist,quality,density,irregularity 八个浮点，
//  然后才是 range,touch,options。
//
#import "LT.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <stdlib.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;

typedef IOHIDEventSystemClientRef (*FN_ClientCreate)(CFAllocatorRef);
typedef IOHIDEventSystemClientRef (*FN_ClientCreateWithType)(CFAllocatorRef, int, CFDictionaryRef);
typedef void (*FN_Dispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*FN_Finger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                   IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                   IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                   Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*FN_Digitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
                                      uint32_t, uint32_t,
                                      IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                      Boolean, Boolean, uint32_t);
typedef void (*FN_SetInt)(IOHIDEventRef, uint32_t, int64_t);
typedef void (*FN_Append)(IOHIDEventRef, IOHIDEventRef);

// IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) = 11 << 16
#define kLTFieldIsDisplayIntegrated 0xb0019
#define kLTTransducerHand 3

static void *gIOKit;
static IOHIDEventSystemClientRef gClient;
static FN_ClientCreate pClientCreate;
static FN_ClientCreateWithType pClientCreateWithType;
static FN_Dispatch pDispatch;
static FN_Finger pFinger;
static FN_Digitizer pDigitizer;
static FN_SetInt pSetInt;
static FN_Append pAppend;

static uint32_t gIdentity;
static CGSize gScreenPts;
static double gCoordScale = 0;
static NSInteger gChannelCache = -1;

static void *lt_sym(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    if (gIOKit) {
        p = dlsym(gIOKit, name);
        if (p) return p;
    }
    return NULL;
}

#pragma mark - 坐标空间

static void lt_refresh_screen(void) {
    if (![NSThread isMainThread]) return;
    CGSize s = CGSizeZero;
    UIScreen *sc = [UIScreen mainScreen];
    if (sc) s = sc.bounds.size;
    if (s.width < 1.0 || s.height < 1.0) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.bounds.size.width > 1.0) { s = w.bounds.size; break; }
        }
    }
    if (s.width > 1.0 && s.height > 1.0) gScreenPts = s;
}

static CGSize lt_screen_points(void) {
    if (gScreenPts.width > 1.0 && gScreenPts.height > 1.0) return gScreenPts;
    if ([NSThread isMainThread]) {
        lt_refresh_screen();
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{ lt_refresh_screen(); });
    }
    return gScreenPts;
}

static double lt_coord_scale(void) {
    if (gCoordScale > 0) return gCoordScale;
    gCoordScale = 1.0;
    const char *env = getenv("LT_COORD_SCALE");
    if (env && *env) {
        double v = atof(env);
        if (v > 0.1 && v < 10.0) { gCoordScale = v; return gCoordScale; }
    }
    double cfg = [[LTConfig shared] coordScale];
    if (cfg > 0.1 && cfg < 10.0) gCoordScale = cfg;
    return gCoordScale;
}

// 归一化 → 屏幕点（进程内合成用）
static CGPoint lt_pts(CGPoint norm) {
    norm.x = MAX(0.0, MIN(1.0, norm.x));
    norm.y = MAX(0.0, MIN(1.0, norm.y));
    CGSize s = lt_screen_points();
    if (s.width < 1.0 || s.height < 1.0) {
        s = [UIScreen mainScreen].bounds.size;
    }
    return CGPointMake(norm.x * s.width, norm.y * s.height);
}

#pragma mark - 初始化

static void lt_load(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_GLOBAL);
        if (!gIOKit) {
            gIOKit = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit",
                            RTLD_LAZY | RTLD_GLOBAL);
        }

        pClientCreate         = (FN_ClientCreate)lt_sym("IOHIDEventSystemClientCreate");
        pClientCreateWithType = (FN_ClientCreateWithType)lt_sym("IOHIDEventSystemClientCreateWithType");
        pDispatch             = (FN_Dispatch)lt_sym("IOHIDEventSystemClientDispatchEvent");
        pFinger               = (FN_Finger)lt_sym("IOHIDEventCreateDigitizerFingerEventWithQuality");
        pDigitizer            = (FN_Digitizer)lt_sym("IOHIDEventCreateDigitizerEvent");
        pSetInt               = (FN_SetInt)lt_sym("IOHIDEventSetIntegerValue");
        pAppend               = (FN_Append)lt_sym("IOHIDEventAppendEvent");

        if (pClientCreate) gClient = pClientCreate(kCFAllocatorDefault);
        if (!gClient && pClientCreateWithType) {
            gClient = pClientCreateWithType(kCFAllocatorDefault, 1 /* Monitor */, NULL);
        }

        lt_refresh_screen();
        NSLog(@"[LazyTap] HID create=%p dispatch=%p finger=%p client=%p screen=%.0fx%.0f",
              pClientCreate, pDispatch, pFinger, gClient, gScreenPts.width, gScreenPts.height);
    });
}

BOOL LTHIDAvailable(void) {
    lt_load();
    return gClient != NULL && pDispatch != NULL && pFinger != NULL;
}

NSString *LTHIDStatusLine(void) {
    lt_load();
    if (!pFinger)   return @"HID符号缺失";
    if (!pDispatch) return @"HID派发缺失";
    if (!gClient)   return @"HID客户端未建";
    return @"HID就绪";
}

#pragma mark - 通道

void LTTapSetChannel(LTTapChannel ch) {
    gChannelCache = ch;
    [LTConfig shared].tapChannel = ch;
    [[LTConfig shared] saveSoon];
}

LTTapChannel LTTapGetChannel(void) {
    if (gChannelCache < 0) {
        NSInteger v = [LTConfig shared].tapChannel;
        if (v < LTTapChannelAuto || v > LTTapChannelHID) v = LTTapChannelAuto;
        gChannelCache = v;
    }
    return (LTTapChannel)gChannelCache;
}

#pragma mark - HID 单指事件

static void lt_hid_finger(CGPoint px, BOOL down, uint32_t identity) {
    if (!pFinger || !pDispatch || !gClient) return;

    uint64_t ts = mach_absolute_time();
    Boolean r = down ? 1 : 0;

    IOHIDEventRef finger = pFinger(kCFAllocatorDefault, ts,
                                   1, identity, 0x3,
                                   px.x, px.y, 0,
                                   0, 0,
                                   1.0, 1.0, 0.0,
                                   r, r, 0);
    if (!finger) return;

    if (pSetInt) pSetInt(finger, kLTFieldIsDisplayIntegrated, 1);

    IOHIDEventRef parent = NULL;
    if (pDigitizer && pAppend) {
        parent = pDigitizer(kCFAllocatorDefault, ts,
                            kLTTransducerHand, 0, 0, 0x3, 0,
                            px.x, px.y, 0, 0, 0,
                            1, 0, 0);
        if (parent) {
            if (pSetInt) pSetInt(parent, kLTFieldIsDisplayIntegrated, 1);
            pAppend(parent, finger);
        }
    }

    if (parent) {
        pDispatch(gClient, parent);
        CFRelease(parent);
    } else {
        pDispatch(gClient, finger);
    }
    CFRelease(finger);
}

static void lt_hid_tap(CGPoint pts, NSTimeInterval hold) {
    if (!LTHIDAvailable()) return;
    double k = lt_coord_scale();
    CGPoint a = CGPointMake(pts.x * k, pts.y * k);
    uint32_t ident = __atomic_add_fetch(&gIdentity, 1, __ATOMIC_RELAXED);

    lt_hid_finger(a, YES, ident);
    NSTimeInterval d = (hold < 0.005) ? 0.012 : hold;
    usleep((useconds_t)(d * 1000000.0));
    lt_hid_finger(a, NO, ident);
}

#pragma mark - 对外接口

void LTTapNormalized(CGPoint p, NSTimeInterval hold) {
    lt_load();
    lt_refresh_screen();

    LTTapChannel ch = LTTapGetChannel();
    CGPoint pts = lt_pts(p);

    if (ch == LTTapChannelHID) {
        lt_hid_tap(pts, hold);
        return;
    }

    BOOL ok = LTUITouchAtWindowPoint(pts, hold);
    if (!ok && ch == LTTapChannelAuto) {
        // 进程内找不到宿主视图（极少见），退回 HID
        lt_hid_tap(pts, hold);
    }
}

void LTSwipeNormalized(CGPoint from, CGPoint to, NSTimeInterval duration) {
    lt_load();
    lt_refresh_screen();

    if (duration < 0.08) duration = 0.08;

    LTTapChannel ch = LTTapGetChannel();
    CGPoint a = lt_pts(from);
    CGPoint b = lt_pts(to);

    if (ch == LTTapChannelHID) {
        double k = lt_coord_scale();
        CGPoint pa = CGPointMake(a.x * k, a.y * k);
        CGPoint pb = CGPointMake(b.x * k, b.y * k);
        uint32_t ident = __atomic_add_fetch(&gIdentity, 1, __ATOMIC_RELAXED);

        lt_hid_finger(pa, YES, ident);
        const int steps = 10;
        for (int i = 1; i <= steps; i++) {
            double t = (double)i / (double)steps;
            CGPoint p = CGPointMake(pa.x + (pb.x - pa.x) * t,
                                    pa.y + (pb.y - pa.y) * t);
            lt_hid_finger(p, YES, ident);
            usleep((useconds_t)(duration * 1000000.0 / steps));
        }
        lt_hid_finger(pb, NO, ident);
        return;
    }

    LTUITouchSwipeAtWindowPoint(a, b, duration);
}
