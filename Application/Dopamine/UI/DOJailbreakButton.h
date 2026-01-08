//
//  DOJailbreakButton.h
//  Dopamine
//
//  Created by tomt000 on 13/01/2024.
//

#import <UIKit/UIKit.h>
#import "DOActionMenuButton.h"
#import "DOLyricsLogView.h"
#import "DODebugLogView.h"
#import "DOPkgManagerPickerView.h"
#import <pthread.h>

NS_ASSUME_NONNULL_BEGIN

@interface DOJailbreakButton : UIView

@property DOActionMenuButton *button;
@property UIView<DOLogViewProtocol> *logView;
@property DOPkgManagerPickerView *pkgManagerPickerView;

@property (nonatomic, getter=isEnabled) BOOL enabled;
@property (nonatomic) BOOL didExpand;
@property (nonatomic, assign) pthread_mutex_t canStartJailbreak;

- (instancetype)initWithAction:(UIAction *)actions;
- (void)expandButton:(NSArray<NSLayoutConstraint *> *)constraints;

/// Updates the title line shown while jailbreaking (the label above the log view).
/// If called before the title is created, the value will be applied once it appears.
- (void)setJailbreakingTitleText:(NSString *)text;

- (void)lockMutex;
- (void)unlockMutex;

@end

NS_ASSUME_NONNULL_END
