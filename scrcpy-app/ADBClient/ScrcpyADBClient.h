//
//  ScrcpyADBClient.h
//  Scrcpy Remote
//
//  Created by Ethan on 12/16/24.
//

#import <Foundation/Foundation.h>
#import "scrcpy-porting.h"
#import <SDL3/SDL.h>

NS_ASSUME_NONNULL_BEGIN

// Notification name for disconnect scrcpy request
#define ScrcpyRequestDisconnectNotification @"ScrcpyRequestDisconnectNotification"

// C function declaration
#ifdef __cplusplus
extern "C" {
#endif

/**
 * Send a keyboard event to the scrcpy window
 * @param scancode The SDL scancode for the key
 * @param keycode The SDL keycode for the key
 * @param keymod The SDL key modifier flags
 */
void ScrcpySendKeycodeEvent(SDL_Scancode scancode, SDL_Keycode keycode, SDL_Keymod keymod);

/**
 * Inject a raw Android keycode (AKEYCODE_*) directly through the scrcpy control
 * channel — used by the TV remote pad. Unlike ScrcpySendKeycodeEvent, the
 * keycode is not translated through the target's keyboard map, which matters
 * for Android TV devices (D-pad / OK navigation).
 * @param keycode Android keycode, e.g. 19 (DPAD_UP), 23 (DPAD_CENTER)
 * @return true if the message was queued to the active controller
 */
bool ScrcpyInjectKeycodeRaw(int32_t keycode);

/**
 * Turn the remote device's display on/off (scrcpy SET_DISPLAY_POWER control
 * message, same as upstream shortcut MOD+o). Used by the TV remote pad's
 * 亮屏/熄屏 buttons.
 * @param on true = screen on, false = screen off
 */
bool ScrcpySetDisplayPower(bool on);

#ifdef __cplusplus
}
#endif

@interface ScrcpyADBClient : NSObject
@end

NS_ASSUME_NONNULL_END
