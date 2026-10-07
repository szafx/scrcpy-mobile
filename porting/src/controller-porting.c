//
//  controller-porting.c
//  scrcpy-mobile
//
//  Created by Ethan on 2022/6/2.
//

// include time
#include <sys/time.h>

#define sc_controller_push_msg(...)     sc_controller_push_msg_hijack(__VA_ARGS__)
#define sc_controller_init(...)         sc_controller_init_hijack(__VA_ARGS__)
#define sc_controller_destroy(...)      sc_controller_destroy_hijack(__VA_ARGS__)

#include "controller.c"

#undef sc_controller_push_msg
#undef sc_controller_init
#undef sc_controller_destroy

#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) ((a) < (b) ? (a) : (b))

// Defined in screen-porting.m
#import "screen.h"
struct sc_screen *
sc_screen_current_screen(struct sc_screen *screen);

// Fix negative point values and larger than screen size
bool sc_controller_push_msg(struct sc_controller *controller,
                            struct sc_control_msg *msg) {
    if (msg->type == SC_CONTROL_MSG_TYPE_INJECT_TOUCH_EVENT) {
      	// log current touch event with time and position
        struct timeval tv;
        gettimeofday(&tv, NULL);
        // printf("inject_touch_event: %ld.%06ld, x=%d, y=%d\n", tv.tv_sec, tv.tv_usec,
        //       msg->inject_touch_event.position.point.x, msg->inject_touch_event.position.point.y);

        // x/y is negative
        msg->inject_touch_event.position.point.x = MAX(msg->inject_touch_event.position.point.x, 0);;
        msg->inject_touch_event.position.point.y = MAX(msg->inject_touch_event.position.point.y, 0);
        
        // x/y exceed max frame size
        struct sc_screen *screen = sc_screen_current_screen(NULL);
        if (screen != NULL) {
            struct sc_size screen_size;
            screen_size.width = screen->frame->width;
            screen_size.height = screen->frame->height;

			msg->inject_touch_event.position.point.x = MIN(msg->inject_touch_event.position.point.x, screen_size.width);
            msg->inject_touch_event.position.point.y = MIN(msg->inject_touch_event.position.point.y, screen_size.height);
        }
    }
    
    return sc_controller_push_msg_hijack(controller, msg);
}

// ---------------------------------------------------------------------------
// TV 遥控器支持：记录当前活动的 controller，并提供「直接注入安卓原始键码」的口子。
//
// 为什么不用 SDL 事件 + 快捷键那条路：遥控器的核心是方向键和 OK，走 SDL 事件时
// 键码要经过被控设备的键盘映射（KeyCharacterMap）转一道，电视上不保证；
// 这里直接构造 scrcpy 的 INJECT_KEYCODE 控制消息，键码是什么就是什么。
// ---------------------------------------------------------------------------

static struct sc_controller *g_active_controller = NULL;

bool sc_controller_init(struct sc_controller *controller, sc_socket control_socket,
                        const struct sc_controller_callbacks *cbs, void *cbs_userdata) {
    bool ok = sc_controller_init_hijack(controller, control_socket, cbs, cbs_userdata);
    if (ok) {
        g_active_controller = controller;
    }
    return ok;
}

void sc_controller_destroy(struct sc_controller *controller) {
    if (g_active_controller == controller) {
        g_active_controller = NULL;
    }
    sc_controller_destroy_hijack(controller);
}

// 向被控设备注入一个「按下+抬起」的安卓键码（AKEYCODE_*，见 android/keycodes.h）
bool ScrcpyInjectKeycodeRaw(int32_t keycode) {
    if (g_active_controller == NULL) {
        return false;
    }
    struct sc_control_msg msg;
    msg.type = SC_CONTROL_MSG_TYPE_INJECT_KEYCODE;
    msg.inject_keycode.action = AKEY_EVENT_ACTION_DOWN;
    msg.inject_keycode.keycode = (enum android_keycode) keycode;
    msg.inject_keycode.repeat = 0;
    msg.inject_keycode.metastate = AMETA_NONE;
    sc_controller_push_msg(g_active_controller, &msg);
    msg.inject_keycode.action = AKEY_EVENT_ACTION_UP;
    return sc_controller_push_msg(g_active_controller, &msg);
}
