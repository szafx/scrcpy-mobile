//
//  SDL_uikitviewcontroller+Extend.h
//  Scrcpy Remote
//
//  Created by Ethan on 1/4/25.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class ScrcpyMenuView;
@class SessionConnectionManager;
@class ScrcpyRemotePadView;

@interface SDL_uikitviewcontroller : UIViewController
@end

@interface SDL_uikitviewcontroller (Extend)

@property (nonatomic, strong) ScrcpyMenuView *menuView;
@property (nonatomic, strong) ScrcpyRemotePadView *remotePadView;

- (void)viewWillLayoutSubviews;
- (void)viewDidLoad;
- (void)dealloc;

@end

NS_ASSUME_NONNULL_END
