//
//  LTAppMain.m  —  独立 App 入口
//
//  和注入版最大的区别：这里没有宿主进程，触摸只能走内核 HID 通道
//  （IOHIDEventSystemClientDispatchEvent）。所以必须有
//  com.apple.private.hid.client.event-dispatch 这条权限，
//  也就是必须用 TrollStore（会保留二进制自带的 entitlements）安装。
//
#import <UIKit/UIKit.h>
#import "LTRootVC.h"
#import "LT.h"

@interface LTAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation LTAppDelegate

- (BOOL)application:(UIApplication *)app
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    LTConfig *c = [LTConfig shared];
    // 独立版默认 HID；用户手动切到「自测」的话保持不动
    if (c.tapChannel == LTTapChannelAuto) c.tapChannel = LTTapChannelHID;

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.backgroundColor = [UIColor blackColor];
    self.window.rootViewController = [LTRootVC new];
    [self.window makeKeyAndVisible];

    // 一直亮着，方便标点；点开始时也避免锁屏打断
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    NSLog(@"[LazyTap] 独立版启动 %@ · %@", LT_VERSION, LTHIDStatusLine());
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"LTAppDelegate");
    }
}
