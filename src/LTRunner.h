//
//  LTRunner.h  —  独立版调度引擎
//
//  和注入版 LTUI.m 里那套 tick 逻辑同源：每个点各自维护「下次到期时刻」，
//  6ms 粒度轮询，到期就派发；落后太多不补点（避免卡顿恢复后瞬间连击）。
//
//  差别只有两处：
//    · tick 跑在自己的串行队列上（App 切后台后主线程可能被降频）
//    · HID 通道直接在引擎队列派发，进程内通道才回主线程（UIKit 要求）
//
#import <Foundation/Foundation.h>
#import "LT.h"

@interface LTRunner : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSUInteger taps;

/// 每次派发后回调（主线程），taps 是累计点击数
@property (nonatomic, copy) void (^onUpdate)(NSUInteger taps);

- (void)start;
- (void)stop;

/// 立刻把所有启用的点点一遍（用来验证权限是否生效）
- (void)fireOnce;

@end
