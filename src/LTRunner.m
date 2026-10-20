//
//  LTRunner.m
//
#import "LTRunner.h"
#import <QuartzCore/QuartzCore.h>

@implementation LTRunner {
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    double *_nextBuf;
    NSInteger _nextCount;
    NSUInteger _taps;
    BOOL _running;
}

+ (instancetype)shared {
    static LTRunner *ins;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ins = [LTRunner new];
        ins->_q = dispatch_queue_create("com.xt.lazytap.engine", DISPATCH_QUEUE_SERIAL);
    });
    return ins;
}

- (BOOL)isRunning { return _running; }
- (NSUInteger)taps { return _taps; }

#pragma mark - 生命周期

- (void)start {
    if (_running) return;
    _running = YES;
    [LTConfig shared].running = YES;

    LTConfig *c = [LTConfig shared];
    NSInteger n = 0;
    @synchronized (c.points) { n = (NSInteger)c.points.count; }

    // buffer 在引擎队列上分配：stop 是异步取消，正在跑的 tick 可能还在读旧 buffer
    dispatch_sync(_q, ^{
        if (self->_nextBuf) { free(self->_nextBuf); self->_nextBuf = NULL; }
        self->_nextCount = n;
        self->_nextBuf = (double *)calloc((size_t)MAX(n, 1), sizeof(double));
        double t0 = CACurrentMediaTime();
        for (NSInteger i = 0; i < n; i++) self->_nextBuf[i] = t0;
    });

    _taps = 0;

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    dispatch_source_set_timer(_timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              6ull * NSEC_PER_MSEC,
                              2ull * NSEC_PER_MSEC);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(_timer, ^{ [ws tick]; });
    dispatch_resume(_timer);

    [self notify];
}

- (void)stop {
    _running = NO;
    [LTConfig shared].running = NO;
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    [self notify];
}

- (void)notify {
    NSUInteger t = _taps;
    void (^cb)(NSUInteger) = self.onUpdate;
    if (!cb) return;
    dispatch_async(dispatch_get_main_queue(), ^{ if (cb) cb(t); });
}

#pragma mark - tick

- (void)tick {
    LTConfig *c = [LTConfig shared];
    if (!c.running) return;

    double now = CACurrentMediaTime();
    NSMutableArray<NSNumber *> *due = nil;

    @synchronized (c.points) {
        NSInteger n = MIN((NSInteger)c.points.count, _nextCount);
        for (NSInteger i = 0; i < n; i++) {
            LTPoint *p = c.points[i];
            if (!p.enabled) continue;
            if (now < _nextBuf[i]) continue;

            double iv = p.interval > 0 ? p.interval : c.globalInterval;
            if (iv < 0.02) iv = 0.02;

            double next = _nextBuf[i] + iv;
            if (next < now) next = now + iv;
            _nextBuf[i] = next;

            if (!due) due = [NSMutableArray arrayWithCapacity:2];
            [due addObject:@(i)];
        }
    }

    if (!due.count) return;
    [self fireIndices:due];
}

- (void)fireIndices:(NSArray<NSNumber *> *)list {
    LTConfig *c = [LTConfig shared];

    // 锁内只取快照，锁外再派发（HID 派发里可能 usleep，不能占着锁）
    NSMutableArray<NSValue *> *vals = [NSMutableArray arrayWithCapacity:list.count];
    NSInteger mode = 0;
    BOOL flip = NO;
    double hold = 0.02, swd = 0.10, swdur = 0.25;

    @synchronized (c.points) {
        mode = c.mode;
        flip = c.flipY;
        hold = c.holdDuration;
        swd = c.swipeDistance;
        swdur = c.swipeDuration;
        for (NSNumber *ix in list) {
            NSInteger i = ix.integerValue;
            if (i < 0 || i >= (NSInteger)c.points.count) continue;
            [vals addObject:[NSValue valueWithCGPoint:c.points[i].norm]];
        }
    }

    LTTapChannel ch = LTTapGetChannel();

    for (NSValue *v in vals) {
        CGPoint n = v.CGPointValue;
        if (flip) n.y = 1.0 - n.y;

        if (ch == LTTapChannelHID) {
            // HID 派发是内核级的，任意线程都可以
            if (mode == 2) {
                CGPoint to = CGPointMake(n.x, MAX(0.02, n.y - swd));
                LTSwipeNormalized(n, to, swdur);
            } else {
                LTTapNormalized(n, (mode == 1) ? hold : 0.02);
            }
        } else {
            // 进程内合成 UITouch，必须主线程
            dispatch_async(dispatch_get_main_queue(), ^{
                if (mode == 2) {
                    CGPoint to = CGPointMake(n.x, MAX(0.02, n.y - swd));
                    LTSwipeNormalized(n, to, swdur);
                } else {
                    LTTapNormalized(n, (mode == 1) ? hold : 0.02);
                }
            });
        }
        _taps++;
    }

    [self notify];
}

#pragma mark - 手动

- (void)fireOnce {
    LTConfig *c = [LTConfig shared];
    NSMutableArray<NSNumber *> *list = [NSMutableArray array];
    @synchronized (c.points) {
        for (NSInteger i = 0; i < (NSInteger)c.points.count; i++) {
            if (c.points[i].enabled) [list addObject:@(i)];
        }
        if (!list.count && c.points.count) [list addObject:@(0)];
    }
    if (!list.count) return;
    [self fireIndices:list];
}

@end
