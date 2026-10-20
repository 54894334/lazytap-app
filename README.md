# LazyTap 独立版（不注入的连点器）

LazyTap 1.2.0 原来是 dylib，要注入到目标 App 里才能用。这一版是**独立 App**：
直接装、直接开，自己的界面里标点，开始之后切到游戏/小程序，点击继续落到屏幕上。

产物：`LazyTap.tipa` / `LazyTap.ipa`（同一个包，TrollStore 认 `.tipa` 后缀）。

---

## 一、为什么必须用 TrollStore 装

向**别的 App** 打点击，只能用内核 HID 通道：

```
IOHIDEventSystemClientCreate → IOHIDEventCreateDigitizerFingerEventWithQuality
  → IOHIDEventSetIntegerValue(IsDisplayIntegrated=0xb0019, 1)
  → IOHIDEventAppendEvent(hand, finger) → IOHIDEventSystemClientDispatchEvent
```

这条通道要求进程主二进制带 `com.apple.private.hid.client.event-dispatch`。
本包已经把这些 entitlement 签进主二进制了（`entitlements.plist`）：

| entitlement | 作用 |
|---|---|
| `com.apple.private.hid.client.event-dispatch` | 派发触摸（核心） |
| `com.apple.private.hid.client.event-filter` / `event-monitor` | 建客户端时用到的配套权限 |
| `platform-application` + `no-sandbox` | TrollStore 安装时保留权限、后台不被沙盒回收 |

TrollStore 安装时会沿用二进制自带的 entitlements，所以才有效。
**普通自签（AltStore / Sideloadly / 7 天证书）拿不到这条权限**，那时只能用
面板里的「通道：自测」——它只点得到本 App 自己的界面，用来确认逻辑没坏。

## 二、用法

1. 打开 App → 黑色画布上点一下 = 放一个点（绿色圆圈，带序号）。
2. 点圆点 = 开/关这个点（灰掉的不参与）；长按圆点 = 删除；拖拽 = 移动。
3. 底部条：`－/＋` 调间隔（0.02~10s，默认 0.30s），模式选 `点按 / 长按 / 滑动`。
4. 先按「测一次」验证权限是否生效 —— 屏幕上应该能看到点一下。
5. 按「开始」→ 面板自动收起 → 切到目标 App，点击会继续。
6. 想停：回到本 App 按「停止」（收起状态下是标题右边那个红按钮）。

「收起/展开」可以把面板缩成一条，方便往屏幕下半部分标点。

## 三、它怎么在后台活着

iOS 会把切到后台的 App 挂起。这里用 `UIBackgroundModes: audio` +
循环播放一段代码里现造的静音 WAV（8kHz/16bit/全零，不占体积）把进程留在运行态，
再挂一个 `beginBackgroundTask` 做保险。音频会话用 `MixWithOthers`，不会打断你在放的音乐。

## 四、代码结构

```
src/
├── LTAppMain.m      main + AppDelegate（首次启动默认把通道设成 HID）
├── LTRootVC.m       界面：全屏标点画布 + 底部控制条（可收起）
├── LTRunner.m       调度引擎：每点独立到期时刻，6ms 轮询，落后不补点
├── LTKeepAlive.m    静音音频保活
├── LT.h             配置模型 / 通道枚举 / 注入接口声明
├── LTConfig.m       点位与参数落盘（沙盒 Documents/LazyTap.json）
├── LTHID.m          HID 注入（和注入版 1.2.0 同一套，已被真机验证）
└── LTUITouch.m      进程内 UITouch 合成（只用于"自测"通道）
LazyTap/
├── Info.plist       含 UIBackgroundModes=audio、UIRequiresFullScreen
└── AppIcon*.png
entitlements.plist   上面那张表
```

坐标一律存**归一化值（0~1）**，发事件时再乘屏幕尺寸，所以换机型不会跑偏。

## 五、已知边界

- 面板收起后是 50pt 高的条，会盖住屏幕最底下一条；标最下面的点时先展开/收起再挪。
- 系统级的「辅助触控」「引导式访问」开启时可能抢走焦点，建议关掉。
- iOS 17.1+ 的 TrollStore 支持有限，本包按 `iphone:clang:latest:14.0`、
  arm64 + arm64e 编的；装不上就先确认 TrollStore 本身能不能装别的 app。
- 只有竖屏（`UISupportedInterfaceOrientations` 里只留了 Portrait）——
  归一化坐标是相对当前方向算的，横屏会偏，所以先禁掉。

## 六、自己改 / 重新编

```bash
# 改完推上去，GitHub Actions（macos-14 + Theos）自动编 + 打 ipa
node ../gh_deploy.js --src=lazytap-app --repo=lazytap-app

# 取产物（raw.githubusercontent 不通，走 contents API）
node ../gh_get.js lazytap-app dist LazyTap.tipa dist/LazyTap.tipa
```

CI 里的打包步骤做三件事：把 `LazyTap/Info.plist` 拷进 `.app`（Theos 跑 `make`
时不会自动拷）、`ldid -S entitlements.plist` 重签、`zip` 成 `Payload/LazyTap.app`。
