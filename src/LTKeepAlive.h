//
//  LTKeepAlive.h  —  后台保活
//
//  切到别的 App 之后本 App 会被挂起，点击就停了。这里用「循环播放静音音轨 +
//  UIBackgroundModes: audio」把进程留在运行态 —— 事件派发是内核级的，
//  进程活着就能继续点，跟当前前台是谁无关。
//
#import <Foundation/Foundation.h>

@interface LTKeepAlive : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isActive) BOOL active;

/// 返回 NO 表示音频通道没起来（此时切后台几秒后会被挂起）
- (BOOL)start;
- (void)stop;

@end
