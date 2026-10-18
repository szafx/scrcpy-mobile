//
//  ScrcpyConstants.h
//  Scrcpy Remote
//
//  Created by Claude on 6/19/25.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Icon Constants

// System Icon Names
extern NSString * const kIconCapsuleHandle;
extern NSString * const kIconBackButton;
extern NSString * const kIconHomeButton;
extern NSString * const kIconSwitchButton;
extern NSString * const kIconKeyboardButton;
extern NSString * const kIconActionsButton;
extern NSString * const kIconDisconnectButton;
extern NSString * const kIconClipboardSyncButton;

// 投屏常驻快捷条（2026-10-18）
extern NSString * const kIconVolumeDownButton;
extern NSString * const kIconVolumeUpButton;
extern NSString * const kIconPowerButton;
extern NSString * const kIconRebootButton;
extern NSString * const kIconShutdownButton;
extern NSString * const kIconCollapseButton;
extern NSString * const kIconQuickMoreButton;

// UserDefaults Keys
extern NSString * const kUserDefaultsPositionRatioX;
extern NSString * const kUserDefaultsPositionRatioY;

// Notification Names
extern NSString * const kNotificationVNCDrag;
extern NSString * const kNotificationVNCDragOffset;
extern NSString * const kNotificationVNCMouseEvent;
extern NSString * const kNotificationVNCScrollEvent;
extern NSString * const kNotificationVNCKeyboardEvent;
/// 通知：VNC 剪贴板已同步到远端
extern NSString * const kNotificationVNCClipboardSynced;
/// 通知：请求同步本地剪贴板到 VNC 设备（由 UI 触发）
extern NSString * const kNotificationVNCSyncClipboardRequest;
/// 通知：请求清除一次性（候选）修饰键状态（由 VNC 客户端在接收到非修饰键后发出）
extern NSString * const kNotificationVNCClearCandidateModifiers;
/// 通知：Toolbar 修饰键状态变更（UI -> VNC），userInfo 包含 lock*/cand* 布尔值
extern NSString * const kNotificationVNCModifierStateUpdated;
/// 通知：下一次按键已经在 Toolbar 侧完成组合（UI -> VNC），VNC 不再进行修饰键增强（一次性）
extern NSString * const kNotificationVNCNextKeyAlreadyCombined;

// 投屏窗口收起 / 恢复（2026-10-18）
/// Swift -> ObjC：请求恢复投屏窗口（顶部横幅点击）
extern NSString * const kNotificationRestoreStreamRequest;
/// ObjC -> Swift：请求对远端设备执行电源命令。userInfo[kKeyPowerCommand]
extern NSString * const kNotificationDevicePowerCommand;
/// Swift -> ObjC：电源命令执行结果。userInfo[kKeyPowerOK] / userInfo[kKeyPowerMessage]
extern NSString * const kNotificationDevicePowerResult;

// Device Types
extern NSString * const kDeviceTypeVNC;
extern NSString * const kDeviceTypeADB;

// Mouse Event Types
extern NSString * const kMouseEventTypeMove;
extern NSString * const kMouseEventTypeDragStart;
extern NSString * const kMouseEventTypeDrag;
extern NSString * const kMouseEventTypeDragEnd;
extern NSString * const kMouseEventTypeClick;
extern NSString * const kMouseEventTypeScroll;

// Keyboard Event Types
extern NSString * const kKeyboardEventTypeKeyDown;
extern NSString * const kKeyboardEventTypeKeyUp;
extern NSString * const kKeyboardEventTypeTextInput;

// Drag States
extern NSString * const kDragStateBegan;
extern NSString * const kDragStateChanged;
extern NSString * const kDragStateEnded;
extern NSString * const kDragStateCancelled;

// Dictionary Keys
extern NSString * const kKeyState;
extern NSString * const kKeyLocation;
extern NSString * const kKeyViewSize;
extern NSString * const kKeyOffset;
extern NSString * const kKeyNormalizedOffset;
extern NSString * const kKeyZoomScale;
extern NSString * const kKeyType;
extern NSString * const kKeyIsRightClick;
/// Generic boolean key to indicate empty/no content states (e.g., clipboard empty)
extern NSString * const kKeyIsEmpty;

// Keyboard Event Keys
extern NSString * const kKeyKeyCode;
extern NSString * const kKeyText;
extern NSString * const kKeyModifiers;

// 电源命令 Keys
/// @"reboot" | @"reboot -p"
extern NSString * const kKeyPowerCommand;
extern NSString * const kKeyPowerOK;
extern NSString * const kKeyPowerMessage;

// Button Type Names
extern NSString * const kButtonTypeBack;
extern NSString * const kButtonTypeHome;
extern NSString * const kButtonTypeSwitch;
extern NSString * const kButtonTypeKeyboard;
extern NSString * const kButtonTypeActions;
extern NSString * const kButtonTypeDisconnect;
extern NSString * const kButtonTypeUnknown;

// Log Labels
extern NSString * const kLogLabelRight;
extern NSString * const kLogLabelLeft;

NS_ASSUME_NONNULL_END
