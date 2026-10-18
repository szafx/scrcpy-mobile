//
//  ScrcpyConstants.m
//  Scrcpy Remote
//
//  Created by Claude on 6/19/25.
//

#import "ScrcpyConstants.h"

// MARK: - Icon Constants

// System Icon Names
NSString * const kIconCapsuleHandle = @"ellipsis";
NSString * const kIconBackButton = @"arrow.left";
NSString * const kIconHomeButton = @"house.circle";
NSString * const kIconSwitchButton = @"square.circle";
NSString * const kIconKeyboardButton = @"keyboard";
NSString * const kIconActionsButton = @"ellipsis.circle";
NSString * const kIconDisconnectButton = @"xmark.circle";
NSString * const kIconClipboardSyncButton = @"square.and.arrow.up.on.square";

// 投屏常驻快捷条（2026-10-18）
NSString * const kIconVolumeDownButton = @"speaker.minus";
NSString * const kIconVolumeUpButton = @"speaker.plus";
NSString * const kIconPowerButton = @"power";
NSString * const kIconRebootButton = @"arrow.clockwise.circle";
NSString * const kIconShutdownButton = @"power.circle";
NSString * const kIconCollapseButton = @"rectangle.compress.vertical";
NSString * const kIconQuickMoreButton = @"ellipsis";

// UserDefaults Keys
NSString * const kUserDefaultsPositionRatioX = @"ScrcpyMenuPositionRatioX";
NSString * const kUserDefaultsPositionRatioY = @"ScrcpyMenuPositionRatioY";

// Notification Names
NSString * const kNotificationVNCDrag = @"ScrcpyVNCDragNotification";
NSString * const kNotificationVNCDragOffset = @"ScrcpyVNCDragOffsetNotification";
NSString * const kNotificationVNCMouseEvent = @"ScrcpyVNCMouseEventNotification";
NSString * const kNotificationVNCScrollEvent = @"ScrcpyVNCScrollEventNotification";
NSString * const kNotificationVNCKeyboardEvent = @"ScrcpyVNCKeyboardEventNotification";
NSString * const kNotificationVNCClipboardSynced = @"ScrcpyVNCClipboardSyncedNotification";
NSString * const kNotificationVNCSyncClipboardRequest = @"ScrcpyVNCSyncClipboardRequestNotification";
NSString * const kNotificationVNCClearCandidateModifiers = @"ScrcpyVNCClearCandidateModifiersNotification";
NSString * const kNotificationVNCModifierStateUpdated = @"ScrcpyVNCModifierStateUpdatedNotification";
NSString * const kNotificationVNCNextKeyAlreadyCombined = @"ScrcpyVNCNextKeyAlreadyCombinedNotification";

// 投屏窗口收起 / 恢复（2026-10-18）
NSString * const kNotificationRestoreStreamRequest = @"ScrcpyRestoreStreamRequestNotification";
NSString * const kNotificationDevicePowerCommand = @"ScrcpyDevicePowerCommandNotification";
NSString * const kNotificationDevicePowerResult = @"ScrcpyDevicePowerResultNotification";

// Device Types
NSString * const kDeviceTypeVNC = @"vnc";
NSString * const kDeviceTypeADB = @"adb";

// Mouse Event Types
NSString * const kMouseEventTypeMove = @"mouseMove";
NSString * const kMouseEventTypeDragStart = @"mouseDragStart";
NSString * const kMouseEventTypeDrag = @"mouseDrag";
NSString * const kMouseEventTypeDragEnd = @"mouseDragEnd";
NSString * const kMouseEventTypeClick = @"mouseClick";
NSString * const kMouseEventTypeScroll = @"mouseScroll";

// Keyboard Event Types
NSString * const kKeyboardEventTypeKeyDown = @"keyDown";
NSString * const kKeyboardEventTypeKeyUp = @"keyUp";
NSString * const kKeyboardEventTypeTextInput = @"textInput";

// Drag States
NSString * const kDragStateBegan = @"began";
NSString * const kDragStateChanged = @"changed";
NSString * const kDragStateEnded = @"ended";
NSString * const kDragStateCancelled = @"cancelled";

// Dictionary Keys
NSString * const kKeyState = @"state";
NSString * const kKeyLocation = @"location";
NSString * const kKeyViewSize = @"viewSize";
NSString * const kKeyOffset = @"offset";
NSString * const kKeyNormalizedOffset = @"normalizedOffset";
NSString * const kKeyZoomScale = @"zoomScale";
NSString * const kKeyType = @"type";
NSString * const kKeyIsRightClick = @"isRightClick";
NSString * const kKeyIsEmpty = @"isEmpty";

// Keyboard Event Keys
NSString * const kKeyKeyCode = @"keyCode";
NSString * const kKeyText = @"text";
NSString * const kKeyModifiers = @"modifiers";

// 电源命令 Keys
NSString * const kKeyPowerCommand = @"command";
NSString * const kKeyPowerOK = @"ok";
NSString * const kKeyPowerMessage = @"message";

// Button Type Names
NSString * const kButtonTypeBack = @"back";
NSString * const kButtonTypeHome = @"home";
NSString * const kButtonTypeSwitch = @"switch";
NSString * const kButtonTypeKeyboard = @"keyboard";
NSString * const kButtonTypeActions = @"actions";
NSString * const kButtonTypeDisconnect = @"disconnect";
NSString * const kButtonTypeUnknown = @"unknown";

// Log Labels
NSString * const kLogLabelRight = @"Right";
NSString * const kLogLabelLeft = @"Left";
