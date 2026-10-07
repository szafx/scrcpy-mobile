//
//  ScrcpyRemotePadView.m
//  Scrcpy Remote
//
//  电视遥控器面板。按键 → ScrcpyInjectKeycodeRaw(安卓键码) → scrcpy 控制通道 → 被控设备。
//  方向键/音量键按住会连发（先发一下，然后每 180ms 一发，走共同 runloop 模式保证
//  触摸跟踪期间也持续触发）。
//

#import "ScrcpyRemotePadView.h"
#import "ScrcpyADBClient.h"

#import <SDL3/SDL.h>

// 安卓键码（AKEYCODE_*，见 android/keycodes.h）
static const int KC_HOME          = 3;
static const int KC_BACK          = 4;
static const int KC_DPAD_UP       = 19;
static const int KC_DPAD_DOWN     = 20;
static const int KC_DPAD_LEFT     = 21;
static const int KC_DPAD_RIGHT    = 22;
static const int KC_DPAD_CENTER   = 23;
static const int KC_VOLUME_UP     = 24;
static const int KC_VOLUME_DOWN   = 25;
static const int KC_POWER         = 26;
static const int KC_MENU          = 82;
static const int KC_APP_SWITCH    = 187;

static const CGFloat kPadWidth  = 316.0;
static const CGFloat kPadHeight = 224.0;
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
    self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.74];
    self.layer.cornerRadius = 16;
    self.clipsToBounds = YES;
    self.userInteractionEnabled = YES;

    // 顶部拖拽条
    self.headerBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kPadWidth, 34)];
    self.headerBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    [self addSubview:self.headerBar];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 7, 220, 20)];
    title.text = @"电视遥控器";
    title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    title.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    [self.headerBar addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(kPadWidth - 40, 3, 34, 28);
    [close setTitle:@"✕" forState:UIControlStateNormal];
    [close setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.7] forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [close addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    close.exclusiveTouch = YES;
    [self.headerBar addSubview:close];

    // 拖拽（只挂在顶栏上，不干扰按键）
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.headerBar addGestureRecognizer:pan];

    // ---- 左侧：方向键（3×3 网格，中心是确定）----
    UIView *dpad = [[UIView alloc] initWithFrame:CGRectMake(14, 44, 168, 168)];
    [self addSubview:dpad];

    [dpad addSubview:[self makeButton:@"▲" keycode:KC_DPAD_UP repeatable:YES frame:CGRectMake(56, 0, 56, 56) fontSize:20]];
    [dpad addSubview:[self makeButton:@"◀" keycode:KC_DPAD_LEFT repeatable:YES frame:CGRectMake(0, 56, 56, 56) fontSize:20]];
    [dpad addSubview:[self makeButton:@"▶" keycode:KC_DPAD_RIGHT repeatable:YES frame:CGRectMake(112, 56, 56, 56) fontSize:20]];
    [dpad addSubview:[self makeButton:@"▼" keycode:KC_DPAD_DOWN repeatable:YES frame:CGRectMake(56, 112, 56, 56) fontSize:20]];

    UIButton *ok = [self makeButton:@"OK" keycode:KC_DPAD_CENTER repeatable:NO frame:CGRectMake(56, 56, 56, 56) fontSize:15];
    ok.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.28];
    [dpad addSubview:ok];

    // ---- 右侧：功能键 ----
    [self addSubview:[self makeButton:@"返回" keycode:KC_BACK repeatable:NO frame:CGRectMake(194, 44, 50, 34) fontSize:13]];
    [self addSubview:[self makeButton:@"主页" keycode:KC_HOME repeatable:NO frame:CGRectMake(252, 44, 50, 34) fontSize:13]];
    [self addSubview:[self makeButton:@"菜单" keycode:KC_MENU repeatable:NO frame:CGRectMake(194, 82, 50, 34) fontSize:13]];
    [self addSubview:[self makeButton:@"最近" keycode:KC_APP_SWITCH repeatable:NO frame:CGRectMake(252, 82, 50, 34) fontSize:13]];
    [self addSubview:[self makeButton:@"音量+" keycode:KC_VOLUME_UP repeatable:YES frame:CGRectMake(194, 120, 50, 34) fontSize:12]];
    [self addSubview:[self makeButton:@"音量−" keycode:KC_VOLUME_DOWN repeatable:YES frame:CGRectMake(252, 120, 50, 34) fontSize:12]];

    UIButton *power = [self makeButton:@"电源" keycode:KC_POWER repeatable:NO frame:CGRectMake(194, 158, 108, 34) fontSize:13];
    [power setTitleColor:[UIColor colorWithRed:1.0 green:0.42 blue:0.38 alpha:1.0] forState:UIControlStateNormal];
    [self addSubview:power];
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
        // 换窗口/旋转后重新夹进可视区
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
