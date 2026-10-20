//
//  LT.h  —  LazyTap 懒触 独立版 1.0
//  不再注入目标 App：自带界面标点，靠 HID 通道把点击打进系统，
//  切到别的 App 后仍然继续点（静音音频保活）。
//
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#define LT_VERSION @"1.0.0-app"
#define LT_PREFS_FILE @"LazyTap.json"

#pragma mark - 触摸注入通道

typedef NS_ENUM(NSInteger, LTTapChannel) {
    LTTapChannelAuto = 0,   // 自动：WebView 走 JS，其余走进程内 UITouch；HID 可用时叠加
    LTTapChannelUI   = 1,   // 仅进程内 UITouch（无需任何 entitlement，最稳）
    LTTapChannelHID  = 2,   // 仅 IOHID（宿主进程必须带 hid.client.event-dispatch）
};

/// 私有 IOHID 符号是否解析成功
BOOL LTHIDAvailable(void);

/// 通道设置 / 读取（对应 LazyTap.json 的 tapChannel）
void LTTapSetChannel(LTTapChannel ch);
LTTapChannel LTTapGetChannel(void);

/// 一行人类可读的自检结论（面板底部显示，也进 NSLog）
NSString *LTTapDiagnose(void);

/// HID 通道状态一行摘要
NSString *LTHIDStatusLine(void);

/// 归一化坐标 (0~1)，y 轴向下。hold<=0 表示瞬时点按
void LTTapNormalized(CGPoint p, NSTimeInterval hold);

/// 归一化坐标下滑动
void LTSwipeNormalized(CGPoint from, CGPoint to, NSTimeInterval duration);

/// 最近一次点击的落点信息（诊断用）
NSString *LTLastHitDescription(void);

/// 进程内触摸合成（窗口坐标，主线程）。返回 NO 表示没找到可点击的宿主视图
BOOL LTUITouchAtWindowPoint(CGPoint pt, NSTimeInterval hold);
void LTUITouchSwipeAtWindowPoint(CGPoint from, CGPoint to, NSTimeInterval duration);

#pragma mark - 配置模型

@interface LTPoint : NSObject
@property (nonatomic) CGPoint norm;      // 0~1
@property (nonatomic) BOOL enabled;
@property (nonatomic) double interval;   // 0 = 跟随全局
@end

@interface LTConfig : NSObject
@property (nonatomic, strong) NSMutableArray<LTPoint *> *points;
@property (nonatomic) BOOL running;
@property (nonatomic) double globalInterval;   // 秒
@property (nonatomic) NSInteger mode;          // 0 点按 1 长按 2 滑动
@property (nonatomic) double holdDuration;     // 长按按住时长
@property (nonatomic) double swipeDistance;    // 归一化滑动距离
@property (nonatomic) double swipeDuration;
@property (nonatomic) BOOL flipY;
@property (nonatomic) BOOL haptic;
@property (nonatomic) BOOL collapsed;
@property (nonatomic) CGPoint barNorm;         // 竖条位置 0~1
@property (nonatomic) double coordScale;       // 1=屏幕点(默认) 3=像素，个别机型需要
@property (nonatomic) NSInteger tapChannel;    // LTTapChannel

+ (instancetype)shared;
- (void)save;
- (void)saveSoon;          // 合并高频写盘（拖动时用）
- (void)reset;
@end
