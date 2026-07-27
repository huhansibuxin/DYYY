#import "DYYYBottomAlertView.h"
#import "AwemeHeaders.h"
#import "DYYYUtils.h"

@implementation DYYYBottomAlertView

+ (UIViewController *)showAlertWithTitle:(NSString *)title
                                 message:(NSString *)message
                               avatarURL:(nullable NSString *)avatarURL
                        cancelButtonText:(nullable NSString *)cancelButtonText
                       confirmButtonText:(nullable NSString *)confirmButtonText
                            cancelAction:(DYYYAlertActionHandler)cancelAction
                             closeAction:(nullable DYYYAlertActionHandler)closeAction
                           confirmAction:(DYYYAlertActionHandler)confirmAction {
    AFDPrivacyHalfScreenViewController *vc = [NSClassFromString(@"AFDPrivacyHalfScreenViewController") new];

    if (!vc)
        return nil;

    if (cancelButtonText.length == 0) {
        cancelButtonText = @"取消";
    }

    if (confirmButtonText.length == 0) {
        confirmButtonText = @"确定";
    }

    UIImageView *imageView = nil;
    if (avatarURL.length > 0) {
        imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        [imageView.widthAnchor constraintEqualToConstant:60].active = YES;
        [imageView.heightAnchor constraintEqualToConstant:60].active = YES;
        imageView.layer.cornerRadius = 30;
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        imageView.layer.masksToBounds = YES;
        imageView.clipsToBounds = YES;

        // 设置默认占位图
        imageView.image = [UIImage imageNamed:@"AppIcon60x60"];

        // 异步加载网络图片
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:avatarURL]];
          if (imageData) {
              UIImage *image = [UIImage imageWithData:imageData];
              if (image) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                    imageView.image = image;
                  });
              }
          }
        });
    }

    __block DYYYAlertActionHandler pendingAction = nil;
    __block BOOL didRunPendingAction = NO;
    void (^executePendingActionIfNeeded)(void) = ^{
      if (didRunPendingAction || !pendingAction) {
          return;
      }
      didRunPendingAction = YES;
      DYYYAlertActionHandler action = pendingAction;
      pendingAction = nil;
      action();
    };
    void (^schedulePendingActionFallback)(void) = ^{
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), executePendingActionIfNeeded);
    };

    DYYYAlertActionHandler wrappedCancelAction = ^{
      pendingAction = [cancelAction copy];
      schedulePendingActionFallback();
    };

    DYYYAlertActionHandler wrappedCloseActionBlock = ^{
      pendingAction = closeAction ? [closeAction copy] : [cancelAction copy];
      schedulePendingActionFallback();
    };

    DYYYAlertActionHandler wrappedConfirmAction = ^{
      pendingAction = [confirmAction copy];
      schedulePendingActionFallback();
    };

    vc.closeButtonClickedBlock = wrappedCloseActionBlock;
    vc.slideDismissBlock = wrappedCloseActionBlock;
    vc.tapDismissBlock = wrappedCloseActionBlock;

    [vc configWithImageView:imageView
                     lockImage:nil
              defaultLockState:NO
                titleLabelText:title
              contentLabelText:message
          leftCancelButtonText:cancelButtonText
        rightConfirmButtonText:confirmButtonText
          rightBtnClickedBlock:wrappedConfirmAction
        leftButtonClickedBlock:wrappedCancelAction];

    if (avatarURL.length > 0) {
        [vc setCornerRadius:11];
        [vc setOnlyTopCornerClips:YES];
    } else {
        [vc setUseCardUIStyle:YES];
    }
    vc.afterDismissBlock = executePendingActionIfNeeded;

    UIViewController *topVC = [DYYYUtils topView];
    if (topVC && [vc respondsToSelector:@selector(presentOnViewController:)] && ![topVC isBeingPresented] && ![topVC isBeingDismissed]) {
        [vc presentOnViewController:topVC];
    } else {
        return nil;
    }

    return vc;
}
@end
