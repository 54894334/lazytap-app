//
//  LTRootVC.m  —  独立版界面
//
//  一个跟屏幕等大的画布：点空白处加点、点圆点开关、长按删除、拖拽移动。
//  记的是**归一化坐标（0~1）**，所以换机型、换方向落点都不会跑偏。
//  底部控制条：间隔 / 模式 / 开始 / 测一次 / 清空 / 通道，可收起，免得挡住下半屏。
//
#import "LTRootVC.h"
#import "LTRunner.h"
#import "LTKeepAlive.h"
#import "LT.h"

static const CGFloat kDotSide = 46;
static const CGFloat kPanelFull = 214;
static const CGFloat kPanelMini = 50;

#pragma mark - 圆点

@interface LTDot : UIView
@property (nonatomic) NSInteger idx;
@property (nonatomic) BOOL enabled;
@property (nonatomic, strong) UILabel *num;
- (void)pulse;
@end

@implementation LTDot

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.borderWidth = 2;
        _num = [[UILabel alloc] initWithFrame:self.bounds];
        _num.textAlignment = NSTextAlignmentCenter;
        _num.font = [UIFont boldSystemFontOfSize:13];
        _num.textColor = [UIColor whiteColor];
        _num.backgroundColor = [UIColor clearColor];
        [self addSubview:_num];
        [self refreshStyle];
    }
    return self;
}

- (void)refreshStyle {
    self.layer.borderColor = (self.enabled ? [UIColor colorWithRed:0.30 green:0.85 blue:0.55 alpha:1]
                                           : [UIColor colorWithWhite:0.55 alpha:1]).CGColor;
    self.backgroundColor = self.enabled
        ? [UIColor colorWithRed:0.30 green:0.85 blue:0.55 alpha:0.28]
        : [UIColor colorWithWhite:0.35 alpha:0.25];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [self refreshStyle];
}

- (void)pulse {
    [UIView animateWithDuration:0.08 animations:^{
        self.transform = CGAffineTransformMakeScale(0.82, 0.82);
    } completion:^(BOOL f) {
        [UIView animateWithDuration:0.18 animations:^{ self.transform = CGAffineTransformIdentity; }];
    }];
}

@end

#pragma mark - 画布

@interface LTCanvas : UIView
@property (nonatomic, copy) void (^onAdd)(CGPoint norm);
@property (nonatomic, copy) void (^onToggle)(NSInteger idx);
@property (nonatomic, copy) void (^onDelete)(NSInteger idx);
@property (nonatomic, copy) void (^onMove)(NSInteger idx, CGPoint norm);
@property (nonatomic) BOOL editable;
- (void)reloadDots;
- (void)pulseIndex:(NSInteger)i;
@end

@implementation LTCanvas {
    NSMutableArray<LTDot *> *_dots;
    NSInteger _dragIdx;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        self.multipleTouchEnabled = NO;
        _dots = [NSMutableArray array];
        _editable = YES;
        _dragIdx = -1;

        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
        [self addGestureRecognizer:tap];

        UILongPressGestureRecognizer *lp =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLong:)];
        lp.minimumPressDuration = 0.55;
        [self addGestureRecognizer:lp];

        UIPanGestureRecognizer *pan =
            [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        pan.maximumNumberOfTouches = 1;
        [self addGestureRecognizer:pan];

        // 拖点的时候别让 tap 抢走
        [tap requireGestureRecognizerToFail:pan];
    }
    return self;
}

- (void)drawRect:(CGRect)r {
    CGContextRef g = UIGraphicsGetCurrentContext();
    CGContextSetLineWidth(g, 1);
    CGContextSetStrokeColorWithColor(g, [UIColor colorWithWhite:1.0 alpha:0.07].CGColor);
    const CGFloat step = 40;
    for (CGFloat x = 0; x < r.size.width; x += step) {
        CGContextMoveToPoint(g, x, 0);
        CGContextAddLineToPoint(g, x, r.size.height);
    }
    for (CGFloat y = 0; y < r.size.height; y += step) {
        CGContextMoveToPoint(g, 0, y);
        CGContextAddLineToPoint(g, r.size.width, y);
    }
    CGContextStrokePath(g);

    CGContextSetStrokeColorWithColor(g, [UIColor colorWithWhite:1.0 alpha:0.16].CGColor);
    CGContextMoveToPoint(g, r.size.width / 2, 0);
    CGContextAddLineToPoint(g, r.size.width / 2, r.size.height);
    CGContextMoveToPoint(g, 0, r.size.height / 2);
    CGContextAddLineToPoint(g, r.size.width, r.size.height / 2);
    CGContextStrokePath(g);
}

- (void)reloadDots {
    for (LTDot *d in _dots) [d removeFromSuperview];
    [_dots removeAllObjects];

    LTConfig *c = [LTConfig shared];
    NSArray<LTPoint *> *pts = nil;
    @synchronized (c.points) { pts = [c.points copy]; }

    CGRect b = self.bounds;
    for (NSInteger i = 0; i < (NSInteger)pts.count; i++) {
        LTPoint *p = pts[i];
        CGPoint pt = CGPointMake(p.norm.x * b.size.width, p.norm.y * b.size.height);
        LTDot *d = [[LTDot alloc] initWithFrame:CGRectMake(pt.x - kDotSide / 2,
                                                           pt.y - kDotSide / 2,
                                                           kDotSide, kDotSide)];
        d.idx = i;
        d.enabled = p.enabled;
        d.num.text = [NSString stringWithFormat:@"%ld", (long)(i + 1)];
        [self addSubview:d];
        [_dots addObject:d];
    }
    [self setNeedsDisplay];
}

- (LTDot *)dotAt:(CGPoint)p {
    for (LTDot *d in [_dots reverseObjectEnumerator]) {
        if (CGRectContainsPoint(CGRectInset(d.frame, -8, -8), p)) return d;
    }
    return nil;
}

- (CGPoint)normOf:(CGPoint)p {
    CGRect b = self.bounds;
    return CGPointMake(MAX(0.0, MIN(1.0, p.x / MAX(b.size.width, 1.0))),
                       MAX(0.0, MIN(1.0, p.y / MAX(b.size.height, 1.0))));
}

- (void)handleTap:(UITapGestureRecognizer *)g {
    if (!_editable) return;
    CGPoint p = [g locationInView:self];
    LTDot *hit = [self dotAt:p];
    if (hit) {
        if (self.onToggle) self.onToggle(hit.idx);
    } else {
        if (self.onAdd) self.onAdd([self normOf:p]);
    }
}

- (void)handleLong:(UILongPressGestureRecognizer *)g {
    if (!_editable || g.state != UIGestureRecognizerStateBegan) return;
    LTDot *hit = [self dotAt:[g locationInView:self]];
    if (hit && self.onDelete) self.onDelete(hit.idx);
}

- (void)handlePan:(UIPanGestureRecognizer *)g {
    if (!_editable) return;
    CGPoint p = [g locationInView:self];

    if (g.state == UIGestureRecognizerStateBegan) {
        LTDot *hit = [self dotAt:p];
        _dragIdx = hit ? hit.idx : -1;
        return;
    }
    if (_dragIdx < 0) return;

    if (g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStateEnded) {
        CGPoint n = [self normOf:p];
        if (self.onMove) self.onMove(_dragIdx, n);
        if (_dragIdx < (NSInteger)_dots.count) {
            _dots[_dragIdx].center = CGPointMake(n.x * self.bounds.size.width,
                                                 n.y * self.bounds.size.height);
        }
    }
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        _dragIdx = -1;
    }
}

- (void)pulseIndex:(NSInteger)i {
    if (i >= 0 && i < (NSInteger)_dots.count) [_dots[i] pulse];
}

@end

#pragma mark - 控制器

@implementation LTRootVC {
    LTCanvas *_canvas;
    UIView *_panel;
    UILabel *_title;
    UILabel *_status;
    UILabel *_intervalLabel;
    UIButton *_channelBtn;
    UIButton *_startBtn;
    UIButton *_onceBtn;
    UIButton *_clearBtn;
    UIButton *_foldBtn;
    UIButton *_minusBtn;
    UIButton *_plusBtn;
    UISegmentedControl *_modeSeg;
    BOOL _folded;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _canvas = [[LTCanvas alloc] initWithFrame:self.view.bounds];
    _canvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_canvas];

    LTConfig *c = [LTConfig shared];
    __weak typeof(self) ws = self;

    _canvas.onAdd = ^(CGPoint n) {
        LTPoint *p = [LTPoint new];
        p.norm = n;
        p.enabled = YES;
        @synchronized (c.points) { [c.points addObject:p]; }
        [c saveSoon];
        [ws refreshAll];
    };
    _canvas.onToggle = ^(NSInteger i) {
        @synchronized (c.points) {
            if (i >= 0 && i < (NSInteger)c.points.count) c.points[i].enabled = !c.points[i].enabled;
        }
        [c saveSoon];
        [ws refreshAll];
    };
    _canvas.onDelete = ^(NSInteger i) {
        @synchronized (c.points) {
            if (i >= 0 && i < (NSInteger)c.points.count) [c.points removeObjectAtIndex:i];
        }
        [c saveSoon];
        [ws refreshAll];
    };
    _canvas.onMove = ^(NSInteger i, CGPoint n) {
        @synchronized (c.points) {
            if (i >= 0 && i < (NSInteger)c.points.count) c.points[i].norm = n;
        }
        [c saveSoon];
    };

    [self buildPanel];
    [self refreshAll];

    [LTRunner shared].onUpdate = ^(NSUInteger taps) { [ws refreshStatus]; };
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_canvas reloadDots];
    [self refreshAll];
}

#pragma mark - 控件

- (UIButton *)mkButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    b.layer.cornerRadius = 10;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)buildPanel {
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - kPanelFull,
                                                      self.view.bounds.size.width, kPanelFull)];
    _panel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    _panel.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.96];
    _panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    _panel.layer.borderWidth = 1;
    [self.view addSubview:_panel];

    _title = [[UILabel alloc] init];
    _title.text = [NSString stringWithFormat:@"LazyTap 独立版 %@", LT_VERSION];
    _title.font = [UIFont boldSystemFontOfSize:15];
    _title.textColor = [UIColor whiteColor];
    [_panel addSubview:_title];

    _channelBtn = [self mkButton:@"" action:@selector(tapChannel)];
    _channelBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [_panel addSubview:_channelBtn];

    _foldBtn = [self mkButton:@"收起" action:@selector(tapFold)];
    _foldBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [_panel addSubview:_foldBtn];

    _minusBtn = [self mkButton:@"－" action:@selector(tapMinus)];
    _plusBtn  = [self mkButton:@"＋" action:@selector(tapPlus)];
    [_panel addSubview:_minusBtn];
    [_panel addSubview:_plusBtn];

    _intervalLabel = [[UILabel alloc] init];
    _intervalLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1];
    _intervalLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _intervalLabel.textAlignment = NSTextAlignmentCenter;
    [_panel addSubview:_intervalLabel];

    _modeSeg = [[UISegmentedControl alloc] initWithItems:@[@"点按", @"长按", @"滑动"]];
    [_modeSeg addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    [_panel addSubview:_modeSeg];

    _startBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _startBtn.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    [_startBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _startBtn.layer.cornerRadius = 12;
    [_startBtn addTarget:self action:@selector(tapStart) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_startBtn];

    _onceBtn  = [self mkButton:@"测一次" action:@selector(tapOnce)];
    _clearBtn = [self mkButton:@"清空" action:@selector(tapClear)];
    [_panel addSubview:_onceBtn];
    [_panel addSubview:_clearBtn];

    _status = [[UILabel alloc] init];
    _status.numberOfLines = 2;
    _status.font = [UIFont systemFontOfSize:11.5];
    _status.textColor = [UIColor colorWithWhite:0.62 alpha:1];
    [_panel addSubview:_status];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat w = self.view.bounds.size.width;
    CGFloat inset = 0;
    if (@available(iOS 11.0, *)) inset = self.view.safeAreaInsets.bottom;
    CGFloat h = _folded ? (kPanelMini + inset) : (kPanelFull + inset);
    _panel.frame = CGRectMake(0, self.view.bounds.size.height - h, w, h);

    const CGFloat pad = 12;
    _title.frame = CGRectMake(pad, 12, w - pad * 2 - 210, 20);
    _foldBtn.frame = CGRectMake(w - pad - 56, 10, 56, 26);
    _channelBtn.frame = CGRectMake(w - pad - 56 - 6 - 96, 10, 96, 26);

    // 收起状态：只留标题 + 开始/停止 + 通道 + 展开，其余全隐
    BOOL showAll = !_folded;
    for (UIView *v in @[_minusBtn, _plusBtn, _intervalLabel, _modeSeg, _onceBtn, _clearBtn, _status]) {
        v.hidden = !showAll;
    }
    [_foldBtn setTitle:(_folded ? @"展开" : @"收起") forState:UIControlStateNormal];

    if (_folded) {
        _startBtn.frame = CGRectMake(w - pad - 56 - 6 - 96 - 6 - 74, 10, 74, 26);
        _startBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        return;
    }

    _startBtn.titleLabel.font = [UIFont boldSystemFontOfSize:19];

    CGFloat y = 46;
    _minusBtn.frame = CGRectMake(pad, y, 48, 36);
    _intervalLabel.frame = CGRectMake(pad + 48 + 6, y, 92, 36);
    _plusBtn.frame = CGRectMake(pad + 48 + 6 + 92 + 6, y, 48, 36);
    CGFloat segX = pad + 48 + 6 + 92 + 6 + 48 + 14;
    _modeSeg.frame = CGRectMake(segX, y + 4, MAX(120, w - segX - pad), 28);

    y = 92;
    _startBtn.frame = CGRectMake(pad, y, w - pad * 2, 48);

    y = 150;
    CGFloat bw = (w - pad * 2 - 12) / 2.0;
    _onceBtn.frame  = CGRectMake(pad, y, bw, 34);
    _clearBtn.frame = CGRectMake(pad + bw + 12, y, bw, 34);

    _status.frame = CGRectMake(pad, y + 36, w - pad * 2, 32);
}

#pragma mark - 刷新

- (void)refreshStatus {
    LTConfig *c = [LTConfig shared];
    BOOL hidCh = (LTTapGetChannel() == LTTapChannelHID);
    NSUInteger n = 0;
    @synchronized (c.points) { n = c.points.count; }

    LTRunner *r = [LTRunner shared];
    _status.text = [NSString stringWithFormat:@"%@ · 点位 %lu · 已点 %lu%@",
                    LTHIDStatusLine(), (unsigned long)n, (unsigned long)r.taps,
                    r.isRunning ? @"\n运行中：现在可以切到目标 App，点击会继续" : @""];

    [_channelBtn setTitle:(hidCh ? @"通道：HID" : @"通道：自测")
                 forState:UIControlStateNormal];

    [_startBtn setTitle:(r.isRunning ? @"停止" : @"开始") forState:UIControlStateNormal];
    _startBtn.backgroundColor = r.isRunning
        ? [UIColor colorWithRed:0.85 green:0.25 blue:0.25 alpha:1]
        : [UIColor colorWithRed:0.16 green:0.62 blue:0.36 alpha:1];
}

- (void)refreshAll {
    [_canvas reloadDots];
    _intervalLabel.text = [NSString stringWithFormat:@"%.2fs", [LTConfig shared].globalInterval];
    _modeSeg.selectedSegmentIndex = MAX(0, MIN(2, [LTConfig shared].mode));
    [self refreshStatus];
    [self.view setNeedsLayout];
}

#pragma mark - 动作

- (void)tapMinus {
    LTConfig *c = [LTConfig shared];
    c.globalInterval = MAX(0.02, c.globalInterval - 0.02);
    [c saveSoon];
    [self refreshAll];
}

- (void)tapPlus {
    LTConfig *c = [LTConfig shared];
    c.globalInterval = MIN(10.0, c.globalInterval + 0.02);
    [c saveSoon];
    [self refreshAll];
}

- (void)modeChanged {
    [LTConfig shared].mode = _modeSeg.selectedSegmentIndex;
    [[LTConfig shared] saveSoon];
}

- (void)tapChannel {
    LTTapSetChannel((LTTapGetChannel() == LTTapChannelHID) ? LTTapChannelUI : LTTapChannelHID);
    [self refreshStatus];
}

- (void)tapFold {
    _folded = !_folded;
    [self.view setNeedsLayout];
    [UIView animateWithDuration:0.22 animations:^{ [self.view layoutIfNeeded]; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.24 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refreshStatus]; });
}

- (void)tapOnce {
    LTConfig *c = [LTConfig shared];
    if (!c.points.count) {
        LTPoint *p = [LTPoint new];
        p.norm = CGPointMake(0.5, 0.5);
        @synchronized (c.points) { [c.points addObject:p]; }
        [[LTConfig shared] saveSoon];
        [self refreshAll];
    }
    if (LTTapGetChannel() != LTTapChannelHID) LTTapSetChannel(LTTapChannelHID);
    [[LTKeepAlive shared] start];
    [[LTRunner shared] fireOnce];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self refreshStatus]; });
}

- (void)tapClear {
    @synchronized ([LTConfig shared].points) { [[LTConfig shared].points removeAllObjects]; }
    [[LTConfig shared] saveSoon];
    [self refreshAll];
}

- (void)tapStart {
    LTRunner *r = [LTRunner shared];
    if (r.isRunning) {
        [r stop];
        [[LTKeepAlive shared] stop];
        [self refreshStatus];
        return;
    }

    if (![LTConfig shared].points.count) {
        UIAlertController *a =
            [UIAlertController alertControllerWithTitle:@"先放一个点"
                                                message:@"在黑色画布上点一下就会出现 1 号点。点圆点开关，长按删除，拖拽移动。"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    // 独立版必须走 HID：进程内通道只能点到自己这个 App
    if (LTTapGetChannel() != LTTapChannelHID) LTTapSetChannel(LTTapChannelHID);
    [[LTKeepAlive shared] start];
    [r start];
    [self tapFold];          // 收起面板，免得挡住下面
    [self refreshStatus];
}

@end
