#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYYYKeyboardAvoidanceCoordinator : NSObject

+ (void)beginAvoidingInputView:(UIView *)inputView
             inViewController:(UIViewController *)viewController
                    scrollView:(UIScrollView *)scrollView;
+ (void)restoreForViewController:(UIViewController *)viewController animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
