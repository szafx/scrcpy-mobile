//
//  ScrcpyRemotePadView.m
//  Scrcpy Remote
//
//  电视遥控器面板。按键 → scrcpy 控制通道注入安卓键码（ScrcpyInjectKeycodeRaw），
//  或经 adb shell 走特殊路径（TCL 的设置键没有可注入键码，用 am start 打开）。
//  方向/音量/频道/亮度按住会连发（先发一下，然后每 180ms 一发，走共同 runloop
//  模式保证触摸跟踪期间也持续触发）。
//
//  2026-10-07 晚在雷鸟鹤6Pro(24款)上实测后的取舍：
//   - 静音：KEYCODE_MUTE(91) 无效（物理键走 TCL 私有链路），但 KEYCODE_VOLUME_MUTE(164) 实测有效 ✓
//   - 设置：注入 176 无效 → 改走 adb shell `am start -n com.tcl.settings/.ui.MainActivity` ✓
//   - 语音/红/绿/蓝：原装遥控器这些键在内核层就是「未定义」的私有信号
//     （KEY_UNKNOWN / KEY_KBD_LCD_MENU4/5 / 0x2bd），无法用任何键码复刻 → 面板不提供
//     （语音可用电视的远场语音「小T小T」，不需要遥控器）
//   - 搜索：原装遥控器没有这个键 + 注入无效 → 不提供
//

#import "ScrcpyRemotePadView.h"
#import "ScrcpyADBClient.h"
#import "ADBClient.h"

#import <SDL3/SDL.h>

// 安卓键码（AKEYCODE_*，见 android/keycodes.h）
static const int KC_HOME            = 3;
static const int KC_BACK            = 4;
static const int KC_DPAD_UP         = 19;
static const int KC_DPAD_DOWN       = 20;
static const int KC_DPAD_LEFT       = 21;
static const int KC_DPAD_RIGHT      = 22;
static const int KC_DPAD_CENTER     = 23;
static const int KC_VOLUME_UP       = 24;
static const int KC_VOLUME_DOWN     = 25;
static const int KC_POWER           = 26;
static const int KC_MENU            = 82;
static const int KC_CHANNEL_UP      = 166;
static const int KC_CHANNEL_DOWN    = 167;
static const int KC_VOLUME_MUTE     = 164;   // 静音（KEYCODE_MUTE=91 在这台电视上无效）
static const int KC_TV_INPUT        = 178;   // 信号源
static const int KC_APP_SWITCH      = 187;
static const int KC_BRIGHTNESS_DOWN = 220;
static const int KC_BRIGHTNESS_UP   = 221;

static const CGFloat kPadWidth  = 356.0;
static const CGFloat kPadHeight = 300.0;
static const NSTimeInterval kRepeatInterval = 0.18;

@interface ScrcpyRemotePadView ()
@property (nonatomic, strong) UIView *headerBar;
@property (nonatomic, strong) NSTimer *repeatTimer;
@property (nonatomic, assign) int repeatKeycode;
@property (nonatomic, assign) BOOL hasCustomPosition;
@end

@implementation ScrcpyRemotePadView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:CGRectMake(0, 0, kPadWidth, kPadHeight)];
    if (self) {
        [self buildUI];
    }
    return self;
}

#pragma mark - UI

- (void)buildUI {
    self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.76];
    self.layer.cornerRadius = 16;
    self.clipsToBounds = YES;
    self.userInteractionEnabled = YES;

    // 顶部拖拽条
    self.headerBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPadWidth, 32)];
    self.headerBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    [self addSubview:self.headerBar];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, 148, 20)];
    title.text = @"电视遥控器";
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    [self.headerBar addSubview:title];

    // 亮屏/熄屏（scrcpy SET_DISPLAY_POWER，连接后被关屏可以随时点回来）
    UIButton *screenOn = [UIButton buttonWithType:UIButtonTypeSystem];
    screenOn.frame = CGRectMake(166, 3, 70, 26);
    [screenOn setTitle:@"亮屏" forState:UIControlStateNormal];
    [screenOn setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.9] forState:UIControlStateNormal];
    screenOn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    screenOn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    screenOn.layer.cornerRadius = 8;
    screenOn.exclusiveTouch = YES;
    [screenOn addTarget:self action:@selector(screenOnTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.headerBar addSubview:screenOn];

    UIButton *screenOff = [UIButton buttonWithType:UIButtonTypeSystem];
    screenOff.frame = CGRectMake(240, 3, 70, 26);
    [screenOff setTitle:@"熄屏" forState:UIControlStateNormal];
    [screenOff setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.9] forState:UIControlStateNormal];
    screenOff.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    screenOff.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    screenOff.layer.cornerRadius = 8;
    screenOff.exclusiveTouch = YES;
    [screenOff addTarget:self action:@selector(screenOffTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.headerBar addSubview:screenOff];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(kPadWidth - 38, 2, 32, 28);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.7] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    close.exclusiveTouch = YES;
    [self.headerBar addSubview:close];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.headerBar addGestureRecognizer:pan];

    // ---- 第一排：电源 / 静音 / 信号源 / 设置 ----
    NSArray *rowA = @[
        @[@"电源", @(KC_POWER)],
        @[@"静音", @(KC_VOLUME_MUTE)],
        @[@"信号源", @(KC_TV_INPUT)],
        @[@"设置", @(0)],   // 特殊：走 adb shell am start（TCL 的设置键没有可注入键码）
    ];
    for (int i = 0; i < (int)rowA.count; i++) {
        UIButton *b = [self makeButton:rowA[i][0] keycode:[rowA[i][1] intValue] repeatable:NO
                                 frame:CGRectMake(2 + i * 90.0, 38, 84, 30) fontSize:13];
        if ([rowA[i][1] intValue] == KC_POWER) {
            [b setTitleColor:[UIColor colorWithRed:1.0 green:0.42 blue:0.38 alpha:1.0] forState:UIControlStateNormal];
        }
        if ([rowA[i][0] isEqualToString:@"设置"]) {
            [b removeTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
            [b addTarget:self action:@selector(settingsTapped) forControlEvents:UIControlEventTouchUpInside];
        }
        [self addSubview:b];
    }

    // ---- 第二排：频道± ----
    [self addSubview:[self makeButton:@"频道−" keycode:KC_CHANNEL_DOWN repeatable:YES frame:CGRectMake(2, 74, 174, 28) fontSize:13]];
    [self addSubview:[self makeButton:@"频道+" keycode:KC_CHANNEL_UP repeatable:YES frame:CGRectMake(182, 74, 174, 28) fontSize:13]];

    // ---- 左侧：方向环（3×3 网格，中心 OK）----
    UIView *dpad = [[UIView alloc] initWithFrame:CGRectMake(2, 112, 168, 168)];
    [self addSubview:dpad];
    [dpad addSubview:[self makeButton:@"▲" keycode:KC_DPAD_UP repeatable:YES frame:CGRectMake(56, 0, 56, 56) fontSize:20]];
    [dpad addSubview:[self makeButton:@"◀" keycode:KC_DPAD_LEFT repeatable:YES frame:CGRectMake(0, 56, 56, 56) fontSize:20]];
    [dpad addSubview:[self makeButton:@"▶" keycode:KC_DPAD_RIGHT repeatable:YES frame:CGRectMake(112, 56, 56, 56) fontSize:20]];
    [dpad addSubview:[self makeButton:@"▼" keycode:KC_DPAD_DOWN repeatable:YES frame:CGRectMake(56, 112, 56, 56) fontSize:20]];
    UIButton *ok = [self makeButton:@"OK" keycode:KC_DPAD_CENTER repeatable:NO frame:CGRectMake(56, 56, 56, 56) fontSize:15];
    ok.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.28];
    [dpad addSubview:ok];

    // ---- 右侧：返回/主页/菜单/最近 + 侧键亮度 ----
    NSArray *rowC = @[
        @[@"返回", @(KC_BACK)],   @[@"主页", @(KC_HOME)],
        @[@"菜单", @(KC_MENU)],   @[@"最近", @(KC_APP_SWITCH)],
        @[@"亮度−", @(KC_BRIGHTNESS_DOWN)], @[@"亮度+", @(KC_BRIGHTNESS_UP)],
    ];
    for (int i = 0; i < (int)rowC.count; i++) {
        CGFloat x = 186.0 + (i % 2) * 86.0;
        CGFloat y = 112.0 + (i / 2) * 44.0;
        BOOL repeat = ([rowC[i][1] intValue] == KC_BRIGHTNESS_UP || [rowC[i][1] intValue] == KC_BRIGHTNESS_DOWN);
        [self addSubview:[self makeButton:rowC[i][0] keycode:[rowC[i][1] intValue] repeatable:repeat
                                    frame:CGRectMake(x, y, 80, 38) fontSize:13]];
    }

    // ---- 音量±（放在右列下方空隙，避开左侧方向环）----
    [self addSubview:[self makeButton:@"音量−" keycode:KC_VOLUME_DOWN repeatable:YES frame:CGRectMake(186, 250, 80, 38) fontSize:14]];
    [self addSubview:[self makeButton:@"音量+" keycode:KC_VOLUME_UP repeatable:YES frame:CGRectMake(272, 250, 82, 38) fontSize:14]];
}

- (UIButton *)makeButton:(NSString *)title
                 keycode:(int)keycode
              repeatable:(BOOL)repeatable
                   frame:(CGRect)frame
                fontSize:(CGFloat)fontSize {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    button.tag = keycode;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.95] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    button.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    button.layer.cornerRadius = 10;
    button.exclusiveTouch = YES;
    if (repeatable) {
        [button addTarget:self action:@selector(buttonTouchDown:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(buttonTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    } else {
        [button addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    }
    return button;
}

#pragma mark - 按键

- (void)buttonTapped:(UIButton *)sender {
    ScrcpyInjectKeycodeRaw((int)sender.tag);
    NSLog(@"📺 [RemotePad] key %ld (tap)", (long)sender.tag);
}

- (void)buttonTouchDown:(UIButton *)sender {
    self.repeatKeycode = (int)sender.tag;
    ScrcpyInjectKeycodeRaw(self.repeatKeycode);
    NSLog(@"📺 [RemotePad] key %d (down, repeat)", self.repeatKeycode);
    [self startRepeatTimer];
}

- (void)buttonTouchUp:(UIButton *)sender {
    [self stopRepeatTimer];
}

- (void)startRepeatTimer {
    [self stopRepeatTimer];
    self.repeatTimer = [NSTimer timerWithTimeInterval:kRepeatInterval
                                               target:self
                                             selector:@selector(fireRepeat)
                                             userInfo:nil
                                              repeats:YES];
    // 共同模式：触摸按住不放时 runloop 处于 tracking 模式，默认模式的 timer 不会走
    [[NSRunLoop mainRunLoop] addTimer:self.repeatTimer forMode:NSRunLoopCommonModes];
}

- (void)stopRepeatTimer {
    [self.repeatTimer invalidate];
    self.repeatTimer = nil;
}

- (void)fireRepeat {
    if (self.repeatKeycode != 0) {
        ScrcpyInjectKeycodeRaw(self.repeatKeycode);
    }
}

- (void)closeTapped {
    [self stopRepeatTimer];
    [self removeFromSuperview];
}

- (void)screenOnTapped {
    ScrcpySetDisplayPower(true);
    NSLog(@"📺 [RemotePad] display ON");
}

- (void)screenOffTapped {
    ScrcpySetDisplayPower(false);
    NSLog(@"📺 [RemotePad] display OFF");
}

- (void)settingsTapped {
    // TCL 的设置键在物理遥控器上是私有信号（内核层未定义），注入任何键码都无效；
    // 但可以直接把它的设置 App 拉起来（实测有效）。
    NSLog(@"📺 [RemotePad] settings via adb (TCL am start)");
    [ADBClient.shared executeADBCommandAsync:@[@"shell", @"am start -n com.tcl.settings/.ui.MainActivity"]
                                    callback:^(NSString * _Nullable result, int returnCode) {
        NSLog(@"📺 [RemotePad] settings launch rc=%d %@", returnCode, result ?: @"");
    }];
}

#pragma mark - 拖拽

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *container = self.superview;
    if (!container) return;

    CGPoint translation = [pan translationInView:container];
    CGPoint center = self.center;
    center.x += translation.x;
    center.y += translation.y;
    [pan setTranslation:CGPointZero inView:container];

    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    center.x = MIN(MAX(center.x, halfW + 4), container.bounds.size.width - halfW - 4);
    center.y = MIN(MAX(center.y, halfH + 4), container.bounds.size.height - halfH - 4);
    self.center = center;
    self.hasCustomPosition = YES;
}

#pragma mark - 挂到窗口

- (UIWindow *)activeWindow {
    // 与 ScrcpyMenuView 相同的取窗方式（SDL3 的 properties bag）
    SDL_Window *window = SDL_GetMouseFocus();
    if (window) {
        SDL_PropertiesID props = SDL_GetWindowProperties(window);
        UIWindow *uiWindow = (__bridge UIWindow *)
            SDL_GetPointerProperty(props, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, NULL);
        if (uiWindow) {
            return uiWindow;
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

- (void)addToActiveWindow {
    UIWindow *window = [self activeWindow];
    if (!window) {
        NSLog(@"📺 [RemotePad] 找不到窗口，放弃");
        return;
    }
    if (self.superview != window) {
        [self removeFromSuperview];
        [window addSubview:self];
    }

    if (!self.hasCustomPosition) {
        CGFloat x = (window.bounds.size.width - kPadWidth) / 2.0;
        CGFloat y = window.bounds.size.height - kPadHeight - 36.0;
        self.frame = CGRectMake(MAX(8.0, x), MAX(8.0, y), kPadWidth, kPadHeight);
    } else {
        CGFloat halfW = kPadWidth / 2.0;
        CGFloat halfH = kPadHeight / 2.0;
        CGPoint center = self.center;
        center.x = MIN(MAX(center.x, halfW + 4), window.bounds.size.width - halfW - 4);
        center.y = MIN(MAX(center.y, halfH + 4), window.bounds.size.height - halfH - 4);
        self.center = center;
    }
}

- (void)dealloc {
    [self.repeatTimer invalidate];
}

@end
