//
//  ScrcpyRemotePadView.m
//  Scrcpy Remote
//
//  电视遥控器面板（对着雷鸟鹤6 Pro 原装遥控器的按键表做的：
//  电源/语音/静音/信号源/设置/搜索 + 红绿蓝一键直达 + 方向环/OK
//  + 返回/主页/菜单/最近 + 音量/频道/亮度）。
//  按键 → ScrcpyInjectKeycodeRaw(安卓键码) → scrcpy 控制通道 → 被控设备。
//  方向/音量/频道/亮度按住会连发（先发一下，然后每 180ms 一发，走共同 runloop
//  模式保证触摸跟踪期间也持续触发）。
//
//  注：原装遥控器的「图像模式」「音箱模式切换」是厂商私有键，安卓没有标准键码，
//  注入不了；「语音」注入的是系统语音助手键（KEYCODE_VOICE_ASSIST）。
//

#import "ScrcpyRemotePadView.h"
#import "ScrcpyADBClient.h"

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
static const int KC_SEARCH          = 84;
static const int KC_MUTE            = 91;
static const int KC_CHANNEL_UP      = 166;
static const int KC_CHANNEL_DOWN    = 167;
static const int KC_SETTINGS        = 176;
static const int KC_TV_INPUT        = 178;   // 信号源
static const int KC_PROG_RED        = 183;   // 红键（一键直达）
static const int KC_PROG_GREEN      = 184;   // 绿键
static const int KC_PROG_BLUE       = 185;   // 蓝键
static const int KC_APP_SWITCH      = 187;
static const int KC_BRIGHTNESS_DOWN = 220;
static const int KC_BRIGHTNESS_UP   = 221;
static const int KC_VOICE_ASSIST    = 231;   // 语音键

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

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, 240, 20)];
    title.text = @"电视遥控器";
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    [self.headerBar addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(kPadWidth - 40, 2, 34, 28);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.7] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    close.exclusiveTouch = YES;
    [self.headerBar addSubview:close];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.headerBar addGestureRecognizer:pan];

    // ---- 第一排：电源/语音/静音/信号源/设置/搜索 ----
    NSArray *rowA = @[
        @[@"电源", @(KC_POWER)],
        @[@"语音", @(KC_VOICE_ASSIST)],
        @[@"静音", @(KC_MUTE)],
        @[@"信号源", @(KC_TV_INPUT)],
        @[@"设置", @(KC_SETTINGS)],
        @[@"搜索", @(KC_SEARCH)],
    ];
    for (int i = 0; i < (int)rowA.count; i++) {
        UIButton *b = [self makeButton:rowA[i][0] keycode:[rowA[i][1] intValue] repeatable:NO
                                 frame:CGRectMake(2 + i * 59.0, 38, 52, 30) fontSize:12];
        if ([rowA[i][1] intValue] == KC_POWER) {
            [b setTitleColor:[UIColor colorWithRed:1.0 green:0.42 blue:0.38 alpha:1.0] forState:UIControlStateNormal];
        }
        [self addSubview:b];
    }

    // ---- 第二排：红/绿/蓝 一键直达 + 频道± ----
    NSArray *rowB = @[
        @[@"红", @(KC_PROG_RED), UIColor.systemRedColor],
        @[@"绿", @(KC_PROG_GREEN), UIColor.systemGreenColor],
        @[@"蓝", @(KC_PROG_BLUE), UIColor.systemBlueColor],
    ];
    for (int i = 0; i < (int)rowB.count; i++) {
        UIButton *b = [self makeButton:rowB[i][0] keycode:[rowB[i][1] intValue] repeatable:NO
                                 frame:CGRectMake(2 + i * 59.0, 74, 52, 28) fontSize:12];
        [b setTitleColor:rowB[i][2] forState:UIControlStateNormal];
        [self addSubview:b];
    }
    [self addSubview:[self makeButton:@"频道−" keycode:KC_CHANNEL_DOWN repeatable:YES frame:CGRectMake(192, 74, 76, 28) fontSize:12]];
    [self addSubview:[self makeButton:@"频道+" keycode:KC_CHANNEL_UP repeatable:YES frame:CGRectMake(276, 74, 76, 28) fontSize:12]];

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
