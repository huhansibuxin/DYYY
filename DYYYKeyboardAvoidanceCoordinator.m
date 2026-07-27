#import "DYYYKeyboardAvoidanceCoordinator.h"
#import <objc/runtime.h>

static char kDYYYKeyboardAvoidanceCoordinatorKey;

@interface DYYYKeyboardAvoidanceCoordinator ()

@property(nonatomic, weak) UIViewController *viewController;
@property(nonatomic, weak) UIScrollView *scrollView;
@property(nonatomic, weak) UIView *activeInputView;
@property(nonatomic, assign) UIEdgeInsets originalContentInset;
@property(nonatomic, assign) UIEdgeInsets originalScrollIndicatorInsets;
@property(nonatomic, assign) BOOL hasCapturedOriginalInsets;
@property(nonatomic, assign) CGRect keyboardFrameInScreen;
@property(nonatomic, assign) NSUInteger transitionGeneration;
@property(nonatomic, strong) id keyboardChangeObserver;
@property(nonatomic, strong) id keyboardHideObserver;

- (instancetype)initWithViewController:(UIViewController *)viewController scrollView:(UIScrollView *)scrollView;
- (void)beginAvoidingInputView:(UIView *)inputView;
- (void)restoreAnimated:(BOOL)animated;

@end

@implementation DYYYKeyboardAvoidanceCoordinator

+ (void)beginAvoidingInputView:(UIView *)inputView
             inViewController:(UIViewController *)viewController
                    scrollView:(UIScrollView *)scrollView {
    if (!inputView || !viewController || !scrollView || ![inputView isDescendantOfView:scrollView]) {
        return;
    }

    DYYYKeyboardAvoidanceCoordinator *coordinator = objc_getAssociatedObject(viewController, &kDYYYKeyboardAvoidanceCoordinatorKey);
    if (!coordinator || coordinator.scrollView != scrollView) {
        [coordinator restoreAnimated:NO];
        coordinator = [[self alloc] initWithViewController:viewController scrollView:scrollView];
        objc_setAssociatedObject(viewController, &kDYYYKeyboardAvoidanceCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [coordinator beginAvoidingInputView:inputView];
}

+ (void)restoreForViewController:(UIViewController *)viewController animated:(BOOL)animated {
    DYYYKeyboardAvoidanceCoordinator *coordinator = objc_getAssociatedObject(viewController, &kDYYYKeyboardAvoidanceCoordinatorKey);
    [coordinator restoreAnimated:animated];
}

- (instancetype)initWithViewController:(UIViewController *)viewController scrollView:(UIScrollView *)scrollView {
    self = [super init];
    if (self) {
        _viewController = viewController;
        _scrollView = scrollView;
        _keyboardFrameInScreen = CGRectNull;

        __weak typeof(self) weakSelf = self;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        _keyboardChangeObserver = [center addObserverForName:UIKeyboardWillChangeFrameNotification
                                                     object:nil
                                                      queue:NSOperationQueue.mainQueue
                                                 usingBlock:^(NSNotification *notification) {
                                                   [weakSelf handleKeyboardFrameChange:notification];
                                                 }];
        _keyboardHideObserver = [center addObserverForName:UIKeyboardWillHideNotification
                                                   object:nil
                                                    queue:NSOperationQueue.mainQueue
                                               usingBlock:^(NSNotification *notification) {
                                                 weakSelf.keyboardFrameInScreen = CGRectNull;
                                                 [weakSelf restoreWithKeyboardNotification:notification];
                                               }];
    }
    return self;
}

- (void)beginAvoidingInputView:(UIView *)inputView {
    if (!NSThread.isMainThread) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf beginAvoidingInputView:inputView];
        });
        return;
    }

    self.activeInputView = inputView;
    [self captureOriginalInsetsIfNeeded];
    if (!CGRectIsNull(self.keyboardFrameInScreen)) {
        [self applyKeyboardFrame:self.keyboardFrameInScreen notification:nil];
    }
}

- (void)captureOriginalInsetsIfNeeded {
    UIScrollView *scrollView = self.scrollView;
    if (!scrollView || self.hasCapturedOriginalInsets) {
        return;
    }
    self.originalContentInset = scrollView.contentInset;
    self.originalScrollIndicatorInsets = scrollView.scrollIndicatorInsets;
    self.hasCapturedOriginalInsets = YES;
}

- (void)handleKeyboardFrameChange:(NSNotification *)notification {
    NSValue *frameValue = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    if (!frameValue) {
        return;
    }
    self.keyboardFrameInScreen = frameValue.CGRectValue;
    [self applyKeyboardFrame:self.keyboardFrameInScreen notification:notification];
}

- (void)applyKeyboardFrame:(CGRect)keyboardFrameInScreen notification:(NSNotification *_Nullable)notification {
    UIViewController *viewController = self.viewController;
    UIScrollView *scrollView = self.scrollView;
    UIView *activeInputView = self.activeInputView;
    UIWindow *window = viewController.view.window ?: scrollView.window;
    if (!viewController || !scrollView || !activeInputView || !window ||
        ![activeInputView isDescendantOfView:scrollView]) {
        return;
    }

    [self captureOriginalInsetsIfNeeded];
    CGRect keyboardFrameInWindow = [window convertRect:keyboardFrameInScreen fromWindow:nil];
    CGRect scrollFrameInWindow = [scrollView convertRect:scrollView.bounds toView:window];
    CGRect intersection = CGRectIntersection(scrollFrameInWindow, keyboardFrameInWindow);
    CGFloat overlap = CGRectIsNull(intersection) || CGRectIsEmpty(intersection) ? 0.0 : CGRectGetHeight(intersection);
    if (overlap <= 0.5) {
        [self restoreWithKeyboardNotification:notification];
        return;
    }

    UIEdgeInsets contentInset = self.originalContentInset;
    contentInset.bottom += overlap;
    UIEdgeInsets indicatorInsets = self.originalScrollIndicatorInsets;
    indicatorInsets.bottom += overlap;
    self.transitionGeneration += 1;

    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = (UIViewAnimationCurve)[notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | ((UIViewAnimationOptions)curve << 16);
    void (^updates)(void) = ^{
      scrollView.contentInset = contentInset;
      scrollView.scrollIndicatorInsets = indicatorInsets;
      [self scrollActiveInputIntoView];
    };

    if (notification && duration > 0.0) {
        [UIView animateWithDuration:duration
                              delay:0.0
                            options:options
                         animations:updates
                         completion:^(__unused BOOL finished) {
                           if (activeInputView.isFirstResponder && self.activeInputView == activeInputView) {
                               [self scrollActiveInputIntoView];
                           }
                         }];
    } else {
        updates();
    }
}

- (void)scrollActiveInputIntoView {
    UIScrollView *scrollView = self.scrollView;
    UIView *activeInputView = self.activeInputView;
    if (!scrollView || !activeInputView || ![activeInputView isDescendantOfView:scrollView]) {
        return;
    }

    CGRect inputRect = [activeInputView convertRect:activeInputView.bounds toView:scrollView];
    inputRect = CGRectInset(inputRect, 0.0, -12.0);
    [scrollView scrollRectToVisible:inputRect animated:NO];
}

- (void)restoreWithKeyboardNotification:(NSNotification *_Nullable)notification {
    if (!self.hasCapturedOriginalInsets) {
        return;
    }

    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = (UIViewAnimationCurve)[notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | ((UIViewAnimationOptions)curve << 16);
    [self restoreWithDuration:duration options:options];
}

- (void)restoreAnimated:(BOOL)animated {
    [self restoreWithDuration:animated ? 0.25 : 0.0
                      options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseInOut];
}

- (void)restoreWithDuration:(NSTimeInterval)duration options:(UIViewAnimationOptions)options {
    UIScrollView *scrollView = self.scrollView;
    if (!scrollView || !self.hasCapturedOriginalInsets) {
        self.activeInputView = nil;
        self.hasCapturedOriginalInsets = NO;
        return;
    }

    UIEdgeInsets contentInset = self.originalContentInset;
    UIEdgeInsets indicatorInsets = self.originalScrollIndicatorInsets;
    NSUInteger generation = ++self.transitionGeneration;
    void (^updates)(void) = ^{
      scrollView.contentInset = contentInset;
      scrollView.scrollIndicatorInsets = indicatorInsets;
    };
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
      if (self.transitionGeneration == generation) {
          self.hasCapturedOriginalInsets = NO;
          self.activeInputView = nil;
      }
    };

    if (duration > 0.0) {
        [UIView animateWithDuration:duration delay:0.0 options:options animations:updates completion:completion];
    } else {
        updates();
        completion(YES);
    }
}

- (void)dealloc {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.keyboardChangeObserver) {
        [center removeObserver:self.keyboardChangeObserver];
    }
    if (self.keyboardHideObserver) {
        [center removeObserver:self.keyboardHideObserver];
    }
}

@end
