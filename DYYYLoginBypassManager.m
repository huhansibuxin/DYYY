#import "DYYYLoginBypassManager.h"

#import "AwemeHeaders.h"
#import <objc/message.h>

static NSString *const kDYYYLoginBypassManagerEnabledKey = @"DYYYEnableLoginBypass";

@implementation DYYYLoginBypassManager

+ (nullable NSString *)normalizedUserID:(id)value {
    NSString *userID = nil;
    if ([value isKindOfClass:NSString.class]) {
        userID = value;
    } else if ([value respondsToSelector:@selector(stringValue)]) {
        userID = [value stringValue];
    }

    userID = [userID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (userID.length == 0 ||
        [userID rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) {
        return nil;
    }

    NSCharacterSet *nonZeroDigits = [NSCharacterSet characterSetWithCharactersInString:@"123456789"];
    return [userID rangeOfCharacterFromSet:nonZeroDigits].location == NSNotFound ? nil : userID;
}

+ (BOOL)officialUserServiceConfirmsLoginWithUserID:(NSString *)callbackUserID {
    Class serviceClass = NSClassFromString(@"AWEUserService");
    if (!serviceClass || ![serviceClass respondsToSelector:@selector(sharedService)]) {
        return NO;
    }

    @try {
        AWEUserService *service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, @selector(sharedService));
        if (!service ||
            ![service respondsToSelector:@selector(isLogin)] ||
            ![service respondsToSelector:@selector(userID)] ||
            ![service isLogin]) {
            return NO;
        }

        NSString *serviceUserID = [self normalizedUserID:[service userID]];
        NSString *modelUserID = nil;
        if ([service respondsToSelector:@selector(currentLoginUser)]) {
            AWEUserModel *currentUser = [service currentLoginUser];
            if ([currentUser respondsToSelector:@selector(userID)]) {
                modelUserID = [self normalizedUserID:[currentUser userID]];
            }
        }

        return (serviceUserID.length > 0 && [serviceUserID isEqualToString:callbackUserID]) ||
               (modelUserID.length > 0 && [modelUserID isEqualToString:callbackUserID]);
    } @catch (NSException *exception) {
        NSLog(@"[DYYY][绕登录] 官方账号服务状态校验异常：%@", exception.reason);
        return NO;
    }
}

+ (BOOL)disableIfOfficialLoginIsConfirmedWithUserID:(NSString *)userID {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:kDYYYLoginBypassManagerEnabledKey]) {
        return YES;
    }
    if (![self officialUserServiceConfirmsLoginWithUserID:userID]) {
        return NO;
    }

    [defaults setBool:NO forKey:kDYYYLoginBypassManagerEnabledKey];
    NSLog(@"[DYYY][绕登录] 已通过官方账号服务确认登录，自动关闭绕登录开关");
    return YES;
}

+ (void)attemptDisableWithUserID:(NSString *)userID retryIndex:(NSUInteger)retryIndex {
    if ([self disableIfOfficialLoginIsConfirmedWithUserID:userID]) {
        return;
    }

    static NSArray<NSNumber *> *retryDelays = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      retryDelays = @[ @0.2, @0.8, @2.0 ];
    });
    if (retryIndex >= retryDelays.count) {
        return;
    }

    NSTimeInterval delay = retryDelays[retryIndex].doubleValue;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self attemptDisableWithUserID:userID retryIndex:retryIndex + 1];
    });
}

+ (void)handleOfficialLoginCompletionWithUserID:(nullable NSString *)userID {
    if (![NSUserDefaults.standardUserDefaults boolForKey:kDYYYLoginBypassManagerEnabledKey]) {
        return;
    }

    NSString *normalizedUserID = [self normalizedUserID:userID];
    if (normalizedUserID.length == 0) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [self attemptDisableWithUserID:normalizedUserID retryIndex:0];
    });
}

@end
