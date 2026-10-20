//
//  LTConfig.m  —  配置模型 + 落盘
//  配置写在目标 App 自己的沙盒（Documents/LazyTap.json），每个 App 一套独立点位
//
#import "LT.h"

@implementation LTPoint

- (instancetype)init {
    if ((self = [super init])) {
        _norm = CGPointMake(0.5, 0.5);
        _enabled = YES;
        _interval = 0;
    }
    return self;
}

- (NSDictionary *)dictionary {
    return @{ @"x": @(self.norm.x),
              @"y": @(self.norm.y),
              @"on": @(self.enabled),
              @"iv": @(self.interval) };
}

+ (instancetype)pointFromDictionary:(NSDictionary *)d {
    LTPoint *p = [LTPoint new];
    p.norm = CGPointMake([d[@"x"] doubleValue], [d[@"y"] doubleValue]);
    p.enabled = d[@"on"] ? [d[@"on"] boolValue] : YES;
    p.interval = [d[@"iv"] doubleValue];
    return p;
}

@end

@implementation LTConfig {
    BOOL _savePending;
}

+ (instancetype)shared {
    static LTConfig *ins;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ins = [LTConfig readFromDisk];
    });
    return ins;
}

+ (NSString *)path {
    NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *doc = dirs.count ? dirs.firstObject : NSTemporaryDirectory();
    return [doc stringByAppendingPathComponent:LT_PREFS_FILE];
}

+ (instancetype)readFromDisk {
    LTConfig *c = [LTConfig new];
    c.points = [NSMutableArray array];
    c.running = NO;
    c.globalInterval = 0.30;
    c.mode = 0;
    c.holdDuration = 0.60;
    c.swipeDistance = 0.10;
    c.swipeDuration = 0.25;
    c.flipY = NO;
    c.haptic = YES;
    c.collapsed = NO;
    c.barNorm = CGPointMake(0.93, 0.42);
    c.coordScale = 1.0;
    c.tapChannel = LTTapChannelAuto;

    NSData *raw = [NSData dataWithContentsOfFile:[LTConfig path]];
    if (raw) {
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
        if ([d isKindOfClass:[NSDictionary class]]) {
            if ([d[@"globalInterval"] isKindOfClass:[NSNumber class]]) c.globalInterval = [d[@"globalInterval"] doubleValue];
            if ([d[@"mode"] isKindOfClass:[NSNumber class]]) c.mode = [d[@"mode"] integerValue];
            if ([d[@"hold"] isKindOfClass:[NSNumber class]]) c.holdDuration = [d[@"hold"] doubleValue];
            if ([d[@"swipeDistance"] isKindOfClass:[NSNumber class]]) c.swipeDistance = [d[@"swipeDistance"] doubleValue];
            if ([d[@"swipeDuration"] isKindOfClass:[NSNumber class]]) c.swipeDuration = [d[@"swipeDuration"] doubleValue];
            if ([d[@"flipY"] isKindOfClass:[NSNumber class]]) c.flipY = [d[@"flipY"] boolValue];
            if ([d[@"haptic"] isKindOfClass:[NSNumber class]]) c.haptic = [d[@"haptic"] boolValue];
            if ([d[@"collapsed"] isKindOfClass:[NSNumber class]]) c.collapsed = [d[@"collapsed"] boolValue];
            if ([d[@"tapChannel"] isKindOfClass:[NSNumber class]]) {
                NSInteger v = [d[@"tapChannel"] integerValue];
                if (v >= 0 && v <= 2) c.tapChannel = v;
            }
            if ([d[@"coordScale"] isKindOfClass:[NSNumber class]]) {
                double v = [d[@"coordScale"] doubleValue];
                if (v > 0.1 && v < 10.0) c.coordScale = v;
            }
            if ([d[@"barX"] isKindOfClass:[NSNumber class]] && [d[@"barY"] isKindOfClass:[NSNumber class]]) {
                c.barNorm = CGPointMake([d[@"barX"] doubleValue], [d[@"barY"] doubleValue]);
            }
            NSArray *arr = d[@"points"];
            if ([arr isKindOfClass:[NSArray class]]) {
                for (NSDictionary *pd in arr) {
                    if ([pd isKindOfClass:[NSDictionary class]]) {
                        [c.points addObject:[LTPoint pointFromDictionary:pd]];
                    }
                }
            }
        }
    }

    // 首次安装给一个居中占位点，方便直接看到效果
    if (c.points.count == 0) {
        LTPoint *p = [LTPoint new];
        p.norm = CGPointMake(0.5, 0.62);
        [c.points addObject:p];
    }

    // 竖条位置兜底：老版本可能存了越界值
    CGPoint bn = c.barNorm;
    bn.x = MAX(0.06, MIN(0.94, bn.x));
    bn.y = MAX(0.10, MIN(0.90, bn.y));
    c.barNorm = bn;
    return c;
}

- (void)save {
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:self.points.count];
    for (LTPoint *p in self.points) [arr addObject:[p dictionary]];

    NSDictionary *d = @{ @"v": @2,
                         @"globalInterval": @(self.globalInterval),
                         @"mode": @(self.mode),
                         @"hold": @(self.holdDuration),
                         @"swipeDistance": @(self.swipeDistance),
                         @"swipeDuration": @(self.swipeDuration),
                         @"flipY": @(self.flipY),
                         @"haptic": @(self.haptic),
                         @"collapsed": @(self.collapsed),
                         @"tapChannel": @(self.tapChannel),
                         @"coordScale": @(self.coordScale),
                         @"barX": @(self.barNorm.x),
                         @"barY": @(self.barNorm.y),
                         @"points": arr };

    NSData *data = [NSJSONSerialization dataWithJSONObject:d options:0 error:NULL];
    if (!data) return;

    // 原子写：先写临时文件再 rename，避免 App 被杀时留下半截 JSON
    NSString *p = [LTConfig path];
    NSString *tmp = [p stringByAppendingString:@".tmp"];
    if ([data writeToFile:tmp atomically:NO]) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:p error:NULL];
        [fm moveItemAtPath:tmp toPath:p error:NULL];
    }
}

// 拖动点位 / 拖竖条时每帧都会变化，合并成 0.8 秒一次写盘，避免主线程被磁盘 IO 卡住
- (void)saveSoon {
    if (_savePending) return;
    _savePending = YES;
    __weak LTConfig *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LTConfig *s = weakSelf;
        if (!s) return;
        s->_savePending = NO;
        [s save];
    });
}

- (void)reset {
    [self.points removeAllObjects];
    self.running = NO;
    self.globalInterval = 0.30;
    self.mode = 0;
    self.holdDuration = 0.60;
    self.swipeDistance = 0.10;
    self.flipY = NO;
    [self save];
}

@end
