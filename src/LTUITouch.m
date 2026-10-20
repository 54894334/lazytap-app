//
//  LTUITouch.m  —  进程内触摸合成（无需任何 entitlement）
//
//  为什么需要它：
//    IOHIDEventSystemClientDispatchEvent 走的是内核 HID 通道，内核校验的是
//    **宿主进程主二进制**的 com.apple.private.hid.client.event-dispatch 权限。
//    TrollStore / ESign 把 dylib 注入 App Store 应用时，宿主二进制没有这条权限，
//    dylib 自己签名里的 entitlements 不会生效 —— 派发被静默丢弃，表现就是
//    「计数在涨、屏幕没反应」。
//
//  本文件的通道完全跑在 App 进程内部：
//    · 普通 UIKit 视图 → 构造 UITouch 子类 + 调 touchesBegan/touchesEnded
//    · WKWebView 内     → 额外用 JS 在命中元素上派发 touch/click（最可靠）
//  不需要签名、不需要越狱、不会因为重签而失效。
//
#import "LT.h"
#import <QuartzCore/QuartzCore.h>
#import <WebKit/WebKit.h>

#pragma mark - 合成 UITouch

@interface LTSyntheticTouch : UITouch
@property (nonatomic) CGPoint ltPoint;          // window 坐标
@property (nonatomic, strong) UIView *ltView;
@property (nonatomic, strong) UIWindow *ltWindow;
@property (nonatomic) UITouchPhase ltPhase;
@property (nonatomic) NSTimeInterval ltTimestamp;
@property (nonatomic) NSUInteger ltTapCount;
@end

@implementation LTSyntheticTouch

- (CGPoint)locationInView:(UIView *)view {
    if (!view || view == self.ltWindow) return self.ltPoint;
    if (!self.ltWindow) return self.ltPoint;
    return [view convertPoint:self.ltPoint fromView:self.ltWindow];
}
- (CGPoint)previousLocationInView:(UIView *)view { return [self locationInView:view]; }
- (CGPoint)preciseLocationInView:(UIView *)view { return [self locationInView:view]; }
- (CGPoint)previousPreciseLocationInView:(UIView *)view { return [self locationInView:view]; }
- (UIView *)view { return self.ltView; }
- (UIWindow *)window { return self.ltWindow; }
- (UITouchPhase)phase { return self.ltPhase; }
- (NSTimeInterval)timestamp { return self.ltTimestamp; }
- (NSUInteger)tapCount { return self.ltTapCount; }
- (UITouchType)type { return UITouchTypeDirect; }
- (CGFloat)majorRadius { return 6.0; }
- (CGFloat)majorRadiusTolerance { return 0.0; }
- (CGFloat)force { return 0.0; }
- (CGFloat)maximumPossibleForce { return 0.0; }
- (CGFloat)altitudeAngle { return 1.5707963267948966; }
- (NSArray<UIGestureRecognizer *> *)gestureRecognizers { return @[]; }
- (NSArray<UIGestureRecognizer *> *)gestureRecognizersForView:(UIView *)v { return @[]; }
- (NSInteger)_compareIndex:(id)obj { return 0; }
- (NSString *)description {
    return [NSString stringWithFormat:@"<LTSyntheticTouch %p phase=%ld pt=(%.1f,%.1f)>",
            self, (long)self.ltPhase, self.ltPoint.x, self.ltPoint.y];
}

@end

#pragma mark - 工具

static UIWindow *lt_host_window(void) {
    UIApplication *app = [UIApplication sharedApplication];
    NSArray<UIWindow *> *all = app.windows;
    Class overlayCls = NSClassFromString(@"LTOverlayWindow");

    UIWindow *fallback = nil;
    for (UIWindow *w in all) {
        if (!w || w.hidden || w.alpha < 0.01f) continue;
        if (overlayCls && [w isKindOfClass:overlayCls]) continue;
        if (w.isKeyWindow) return w;
        if (!fallback) fallback = w;
        else if (w.windowLevel < fallback.windowLevel) fallback = w;
    }
    if (fallback) return fallback;
    if (app.keyWindow && !(overlayCls && [app.keyWindow isKindOfClass:overlayCls])) return app.keyWindow;
    return nil;
}

static UIEvent *lt_make_event(UITouch *touch) {
    UIEvent *ev = nil;
    @try { ev = [[UIEvent alloc] init]; } @catch (NSException *e) { return nil; }
    @try { [ev setValue:[NSSet setWithObject:touch] forKey:@"_touches"]; }
    @catch (NSException *e) {}
    @try { [ev setValue:@([[NSProcessInfo processInfo] systemUptime]) forKey:@"_timestamp"]; }
    @catch (NSException *e) {}
    return ev;
}

static WKWebView *lt_webview_for(UIView *v) {
    UIView *cur = v;
    while (cur) {
        if ([cur isKindOfClass:[WKWebView class]]) return (WKWebView *)cur;
        cur = cur.superview;
    }
    return nil;
}

#pragma mark - WebView JS 点击

// 返回 YES 表示已尝试过 JS
static BOOL lt_js_tap(WKWebView *wv, CGPoint ptInWindow, BOOL isSwipe, CGPoint toPoint) {
    if (!wv) return NO;

    CGPoint p = [wv convertPoint:ptInWindow fromView:wv.window];
    CGSize sz = wv.bounds.size;
    if (sz.width < 1 || sz.height < 1) return NO;

    NSString *js;
    if (isSwipe) {
        CGPoint q = [wv convertPoint:toPoint fromView:wv.window];
        js = [NSString stringWithFormat:
              @"(function(px,py,qx,qy,w,h){"
              @"var rx=(window.innerWidth||w)/w, ry=(window.innerHeight||h)/h;"
              @"var x=px*rx,y=py*ry,u=qx*rx,v=qy*ry;"
              @"var el=document.elementFromPoint(x,y)||document.elementFromPoint(u,v)||document.body;"
              @"if(!el)return 'nil';"
              @"function T(t,cx,cy){return {identifier:1,target:el,clientX:cx,clientY:cy,pageX:cx+window.scrollX,pageY:cy+window.scrollY,screenX:cx,screenY:cy};}"
              @"function F(t,cx,cy){var o={bubbles:true,cancelable:true,view:window,touches:[T(t,cx,cy)],targetTouches:[T(t,cx,cy)],changedTouches:[T(t,cx,cy)]};"
              @"try{el.dispatchEvent(new TouchEvent(t,o));}catch(e){try{var ev=document.createEvent('TouchEvent');ev.initTouchEvent(t,true,true,window,0,0,0,0,cx,cy,cx,cy,null);el.dispatchEvent(ev);}catch(e2){}}}"
              @"F('touchstart',x,y);"
              @"var N=6;for(var i=1;i<=N;i++){F('touchmove',x+(u-x)*i/N,y+(v-y)*i/N);}"
              @"F('touchend',u,v);"
              @"return el.tagName;"
              @"})(%.1f,%.1f,%.1f,%.1f,%.1f,%.1f)",
              p.x, p.y, q.x, q.y, sz.width, sz.height];
    } else {
        // 只派发鼠标/点击语义，不发 touch：
        // 真机上 WKWebView 的触摸由内部手势识别器驱动，程序化 TouchEvent 不会被它采纳，
        // 而 touch 序列 + click 双发会让 js 框架（含小程序基础库）触发两次。
        js = [NSString stringWithFormat:
              @"(function(px,py,w,h){"
              @"var rx=(window.innerWidth||w)/w, ry=(window.innerHeight||h)/h;"
              @"var x=px*rx,y=py*ry;"
              @"var el=document.elementFromPoint(x,y);"
              @"if(!el)return 'nil';"
              @"function M(t){try{el.dispatchEvent(new MouseEvent(t,{bubbles:true,cancelable:true,clientX:x,clientY:y,view:window,button:0}));}catch(e){}}"
              @"M('mousedown');M('mouseup');"
              @"try{el.click();}catch(e){}"
              @"return el.tagName.toUpperCase()+(typeof el.className==='string'?'.'+el.className:'');"
              @"})(%.1f,%.1f,%.1f,%.1f)",
              p.x, p.y, sz.width, sz.height];
    }

    @try {
        [wv evaluateJavaScript:js completionHandler:nil];
    } @catch (NSException *e) {
        return NO;
    }
    return YES;
}

#pragma mark - 合成点按

static NSString *gLastHit = nil;

static void lt_send(UITouch *t, UIView *hit, UIEvent *ev, BOOL began) {
    NSSet *set = [NSSet setWithObject:t];
    @try {
        if (began) [hit touchesBegan:set withEvent:ev];
        else       [hit touchesEnded:set withEvent:ev];
    } @catch (NSException *e) {
        NSLog(@"[LazyTap] touches 派发异常: %@", e.reason);
    }
}

BOOL LTUITouchAtWindowPoint(CGPoint pt, NSTimeInterval hold) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ LTUITouchAtWindowPoint(pt, hold); });
        return YES;
    }

    UIWindow *win = lt_host_window();
    if (!win) { gLastHit = @"无宿主窗口"; return NO; }

    UIView *hit = [win hitTest:pt withEvent:nil];
    if (!hit) { gLastHit = @"hitTest 为空"; return NO; }

    // WebView 走 JS：WKWebView 的触摸由内部手势识别器处理，程序化 UITouch 喂不进去；
    // 这里只走 JS，避免和原生触摸叠加成双触发
    WKWebView *wv = lt_webview_for(hit);
    if (wv) {
        BOOL ok = lt_js_tap(wv, pt, NO, CGPointZero);
        gLastHit = ok ? @"WKWebView→JS点击" : @"WKWebView→JS失败";
        return ok;
    }

    // 祖先里有 UIControl（按钮/分段控件等）：直接发 action，最安全，不需要伪造 UITouch
    UIView *cur = hit;
    while (cur && ![cur isKindOfClass:[UIControl class]]) cur = cur.superview;
    if ([cur isKindOfClass:[UIControl class]]) {
        UIControl *ctl = (UIControl *)cur;
        BOOL sent = NO;
        @try {
            [ctl sendActionsForControlEvents:UIControlEventTouchDown];
            [ctl sendActionsForControlEvents:UIControlEventTouchUpInside];
            sent = YES;
        } @catch (NSException *e) {
            sent = NO;
        }
        gLastHit = [NSString stringWithFormat:@"%@(UIControl)", NSStringFromClass([ctl class])];
        if (sent) return YES;
    }

    LTSyntheticTouch *t = nil;
    @try { t = [LTSyntheticTouch new]; } @catch (NSException *e) { t = nil; }
    if (!t) { gLastHit = @"UITouch 构造失败"; return NO; }

    t.ltPoint = pt;
    t.ltView = hit;
    t.ltWindow = win;
    t.ltTapCount = 1;

    UIEvent *ev = lt_make_event(t);

    t.ltPhase = UITouchPhaseBegan;
    t.ltTimestamp = CACurrentMediaTime();
    lt_send(t, hit, ev, YES);

    gLastHit = NSStringFromClass([hit class]);

    NSTimeInterval d = (hold < 0.005) ? 0.012 : hold;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        t.ltPhase = UITouchPhaseEnded;
        t.ltTimestamp = CACurrentMediaTime();
        lt_send(t, hit, ev, NO);
    });
    return YES;
}

#pragma mark - 合成滑动

void LTUITouchSwipeAtWindowPoint(CGPoint from, CGPoint to, NSTimeInterval duration) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LTUITouchSwipeAtWindowPoint(from, to, duration);
        });
        return;
    }

    UIWindow *win = lt_host_window();
    if (!win) return;

    UIView *hit = [win hitTest:from withEvent:nil];
    if (!hit) return;

    WKWebView *wv = lt_webview_for(hit);
    if (wv) { lt_js_tap(wv, from, YES, to); return; }   // WebView 用 JS 更准，不再发原生序列

    if (duration < 0.08) duration = 0.08;

    LTSyntheticTouch *t = [LTSyntheticTouch new];
    t.ltView = hit;
    t.ltWindow = win;
    t.ltTapCount = 1;
    t.ltPoint = from;

    UIEvent *ev = lt_make_event(t);

    t.ltPhase = UITouchPhaseBegan;
    t.ltTimestamp = CACurrentMediaTime();
    lt_send(t, hit, ev, YES);

    const int steps = 8;
    for (int i = 1; i <= steps; i++) {
        double f = (double)i / (double)steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * f,
                                from.y + (to.y - from.y) * f);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(duration * f * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            t.ltPoint = p;
            t.ltPhase = UITouchPhaseMoved;
            t.ltTimestamp = CACurrentMediaTime();
            @try { [hit touchesMoved:[NSSet setWithObject:t] withEvent:ev]; }
            @catch (NSException *e) {}
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        t.ltPoint = to;
        t.ltPhase = UITouchPhaseEnded;
        t.ltTimestamp = CACurrentMediaTime();
        lt_send(t, hit, ev, NO);
    });
}

#pragma mark - 诊断

NSString *LTLastHitDescription(void) {
    return gLastHit ?: @"尚未点击";
}

NSString *LTTapDiagnose(void) {
    NSString *ch = @"自动";
    switch (LTTapGetChannel()) {
        case LTTapChannelUI:  ch = @"进程内"; break;
        case LTTapChannelHID: ch = @"HID"; break;
        default: break;
    }
    return [NSString stringWithFormat:@"通道:%@ · %@ · 上次命中:%@",
            ch, LTHIDStatusLine(), LTLastHitDescription()];
}
