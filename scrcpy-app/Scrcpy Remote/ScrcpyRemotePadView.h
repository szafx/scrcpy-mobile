//
//  ScrcpyRemotePadView.h
//  Scrcpy Remote
//
//  电视/机顶盒等「没有触摸屏」的安卓设备的遥控器面板：
//  方向键 + 确定 + 返回/主页/菜单/最近 + 音量 + 电源。
//  走 scrcpy 控制通道直接注入安卓原始键码（ScrcpyInjectKeycodeRaw），
//  不依赖被控设备的键盘映射 —— 触摸注入在电视上本来就不适用（没触摸屏）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ScrcpyRemotePadView : UIView

/// 挂到当前 SDL 投屏窗口（找不到窗口时挂 keyWindow）
- (void)addToActiveWindow;

@end

NS_ASSUME_NONNULL_END
