//
//  LTKeepAlive.m
//
#import "LTKeepAlive.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

@implementation LTKeepAlive {
    AVAudioPlayer *_player;
    UIBackgroundTaskIdentifier _bgTask;
}

+ (instancetype)shared {
    static LTKeepAlive *ins;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ins = [LTKeepAlive new]; });
    return ins;
}

- (BOOL)isActive { return _player.isPlaying; }

#pragma mark - 静音音轨

// 现造一个 1 秒 8kHz 单声道 16bit 全零 WAV，不占体积、不需要资源文件
static void lt_put(NSMutableData *d, const char *p, size_t n) {
    [d appendBytes:p length:n];
}
static void lt_u32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v & 0xff), (uint8_t)((v >> 8) & 0xff),
                     (uint8_t)((v >> 16) & 0xff), (uint8_t)((v >> 24) & 0xff) };
    [d appendBytes:b length:4];
}
static void lt_u16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xff), (uint8_t)((v >> 8) & 0xff) };
    [d appendBytes:b length:2];
}

- (NSData *)silentWav {
    const uint32_t rate = 8000;
    const uint32_t frames = rate;              // 1 秒
    const uint32_t dataBytes = frames * 2;
    NSMutableData *d = [NSMutableData dataWithCapacity:44 + dataBytes];

    lt_put(d, "RIFF", 4);
    lt_u32(d, 36 + dataBytes);
    lt_put(d, "WAVEfmt ", 8);
    lt_u32(d, 16);            // fmt chunk size
    lt_u16(d, 1);             // PCM
    lt_u16(d, 1);             // 单声道
    lt_u32(d, rate);
    lt_u32(d, rate * 2);      // byte rate
    lt_u16(d, 2);             // block align
    lt_u16(d, 16);            // bits
    lt_put(d, "data", 4);
    lt_u32(d, dataBytes);
    [d increaseLengthBy:dataBytes];   // 全零
    return d;
}

#pragma mark - 启停

- (BOOL)start {
    if (_player.isPlaying) return YES;

    NSError *err = nil;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    // MixWithOthers：不打断用户正在放的音乐
    [s setCategory:AVAudioSessionCategoryPlayback
       withOptions:AVAudioSessionCategoryOptionMixWithOthers
             error:&err];
    if (err) NSLog(@"[LazyTap] audio category: %@", err.localizedDescription);

    err = nil;
    [s setActive:YES error:&err];
    if (err) NSLog(@"[LazyTap] audio active: %@", err.localizedDescription);

    if (!_player) {
        NSData *wav = [self silentWav];
        err = nil;
        _player = [[AVAudioPlayer alloc] initWithData:wav error:&err];
        if (!_player || err) {
            NSLog(@"[LazyTap] 静音音轨创建失败: %@", err.localizedDescription);
            _player = nil;
            return NO;
        }
        _player.numberOfLoops = -1;   // 无限循环
        _player.volume = 0.0;         // 完全静音
        [_player prepareToPlay];
    }

    BOOL ok = [_player play];
    NSLog(@"[LazyTap] 保活音频 %@", ok ? @"已启动" : @"启动失败");
    if (!ok) return NO;

    // 双保险：再挂一个后台任务占位，被系统回收时自动续
    [self renewBackgroundTask];
    return YES;
}

- (void)stop {
    if (_player) [_player stop];
    if (_bgTask && _bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:_bgTask];
        _bgTask = UIBackgroundTaskInvalid;
    }
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:&err];
}

- (void)renewBackgroundTask {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    __weak typeof(self) ws = self;
    _bgTask = [app beginBackgroundTaskWithExpirationHandler:^{
        LTKeepAlive *s = ws;
        if (!s) return;
        if (s->_bgTask != UIBackgroundTaskInvalid) {
            [app endBackgroundTask:s->_bgTask];
            s->_bgTask = UIBackgroundTaskInvalid;
        }
        // 音频还在放就再要一个；纯粹是保险丝，正常情况下音频就够了
        if (s->_player.isPlaying) [s renewBackgroundTask];
    }];
}

@end
