#import "AwemeHeaders.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import "DYYYBottomAlertView.h"
#import "DYYYConfirmCloseView.h"
#import "DYYYCustomInputView.h"
#import "DYYYFilterSettingsView.h"
#import "DYYYKeywordListView.h"
#import "DYYYManager.h"
#import "DYYYToast.h"
#import "DYYYUtils.h"

static UIView *findLandscapeEntryViewInView(UIView *view) {
    if (!view) return nil;
    Class entryClass = NSClassFromString(@"AWELandscapeFeedEntryView");
    if (entryClass && [view isKindOfClass:entryClass]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = findLandscapeEntryViewInView(subview);
        if (found) return found;
    }
    return nil;
}

static void DYYYFSResetBeforeEntry(void);   // 定义见下方 DYYYFS 区

static void simulateTapOnEntryView(UIView *entryView) {
    if (!entryView) return;
    // 进屏前先复位残留的旋转状态（否则「全屏观看」会被上一次「反向全屏」带偏）
    DYYYFSResetBeforeEntry();
    if ([entryView respondsToSelector:@selector(sendActionsForControlEvents:)]) {
        [(UIControl *)entryView sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }
    for (UIGestureRecognizer *gr in entryView.gestureRecognizers) {
        if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
            id targets = [gr valueForKey:@"targets"];
            if ([targets isKindOfClass:[NSArray class]]) {
                for (id t in targets) {
                    id target = [t valueForKey:@"target"];
                    SEL action = (SEL)((void *(*)(id, SEL))objc_msgSend)(t, @selector(action));
                    if (target && action && [target respondsToSelector:action]) {
                        void (*fn)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
                        fn(target, action, gr);
                    }
                }
            }
        }
    }
}

// ======================= 【反向全屏】 =======================
// 需求：长按菜单「全屏观看」之外，再提供一个【方向相反】的全屏入口，且不要"转两圈"。
// 现状：进全屏靠模拟点击抖音原生横屏入口 AWELandscapeFeedEntryView，抖音固定落在同一侧(3)。
// 做法（v39 起）：进屏【之前】把 scene 几何偏好收窄成「竖屏 + 仅目标横屏侧」，再点原生入口 ——
//      抖音入口转横屏时唯一可选项就是目标侧，于是一次到位落到 4，不再需要"先进左再翻右"的第二段旋转。
//      万一入口没按预置落，才退回翻面兜底（geometry + KVC + attemptRotationToDeviceOrientation 三件套）。
// 依据：AwemeCore 二进制核验到 Landscape_right 常量 + AWEXPlayOrientationManager /
//      LandscapeFeedAutoRotateController，抖音内部本就区分左右两向，翻面不破坏布局。
// 探针：`入口准备 seed/mask` / `✅ 入口一次落到目标侧` / `翻面兜底` / `1.0s 复核`。

// 精简诊断日志（DYYYSpeedDiag 在 DYYY.xm 里是 static，本编译单元看不到，故另写一份）
static void DYYYFSDiag(NSString *msg) {
    @try {
        if (!DYYYGetBool(@"DYYYDiagLog")) return;
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
        static dispatch_queue_t q;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ q = dispatch_queue_create("com.dyyy.fsdiag", DISPATCH_QUEUE_SERIAL); });
        dispatch_async(q, ^{
            @try {
                NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"DYYY"];
                [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *path = [dir stringByAppendingPathComponent:@"speed_diag.log"];
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
                if (fh) {
                    [fh seekToEndOfFile];
                    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh closeFile];
                } else {
                    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
                    [((old ? [old stringByAppendingString:line] : line)) writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            } @catch (__unused NSException *e) {}
        });
    } @catch (__unused NSException *e) {}
}

// 两个目标侧，按老板肉眼方向命名：
//   「左」= UIInterfaceOrientationLandscapeRight(3) —— 抖音原生入口默认会落的那一侧
//   「右」= UIInterfaceOrientationLandscapeLeft(4)  —— 「反向全屏」要的那一侧
static UIInterfaceOrientation DYYYFSReverseTarget(void) { return UIInterfaceOrientationLandscapeLeft;  }

// ⚠️【进全屏前的复位】——长按菜单刚收起、界面还是竖屏时执行，无感。
// 为什么需要：「反向全屏」为了落右，会把"要落哪一侧"写进 UIKit 的持久状态（实机已确认会留下来），
//            不复位的话下一次点「全屏观看」也会被带成右侧（老板实测）。v38 用这套复位时正向是正常的。
// 做法：把 UIDevice.orientation 写回竖屏 + 把 scene 的允许方向复位成"全竖屏 + 两横屏"（抖音原生默认）。
static void DYYYFSResetBeforeEntry(void) {
    [[UIDevice currentDevice] setValue:@(UIDeviceOrientationPortrait) forKey:@"orientation"];
    if (@available(iOS 16.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowSceneGeometryPreferencesIOS *prefs =
                    [[UIWindowSceneGeometryPreferencesIOS alloc]
                        initWithInterfaceOrientations:UIInterfaceOrientationMaskAllButUpsideDown];
                [(UIWindowScene *)scene requestGeometryUpdateWithPreferences:prefs errorHandler:nil];
            }
        }
    }
}

// ===================== 【源头指定方向】=====================
// 目标：让「反向全屏」的旋转**一次就落到横屏右**，不再有我们事后补的第二段（老板说的"转圈"）。
//
// 原理：UIKit 决定"这次能转到哪些方向"要问两处 ——
//   ① app 的 `application:supportedInterfaceOrientationsForWindow:`（delegate mask）
//   ② 目标 VC 的 `supportedInterfaceOrientations`
//   两者取交集后唯一可行方向就是最终落点。所以只要在"进屏前"把这两处都收窄成【只允许横屏右】，
//   抖音自己的旋转动画一开始就只有一个可选方向 → 直接落右，全程一段动画。
//
// ⚠️ 历史坑（v35 那次的教训）：当时只挂了 delegate、而且给的值是「横屏右(3)」——
//    那正好是抖音默认就落的那一侧，所以"看起来没用"其实可能是**测试本身无效**。这次两个都挂、且给「横屏左(4)」。
//
// 挂谁：不猜类名。运行时遍历所有类，只挂「自己在自己类里实现了 supportedInterfaceOrientations」的类；
//      调用时**先把原实现调一遍**，只有原返回值包含横屏的才覆盖 → 竖屏锁定的信息流 VC 天然被排除，不会误伤。
static BOOL gDYYYFSOrientForceLeft = NO;          // YES = 本次只允许「横屏右(LandscapeLeft)」
static BOOL gDYYYFSOrientHooked = NO;
static NSUInteger gDYYYFSOrientHookCount = 0;
static NSMutableDictionary<NSString *, NSValue *> *gDYYYFSOrientOrigIMPs = nil;   // "Class|sel" -> 原 IMP

static NSString *DYYYFSOrientKey(Class c, SEL s) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(c), NSStringFromSelector(s)];
}

// 沿继承链找本类注册过的原 IMP（self 的实际类可能比注册的更派生）
static IMP DYYYFSOrientOrigIMP(id self, SEL _cmd) {
    for (Class c = object_getClass(self); c; c = class_getSuperclass(c)) {
        NSValue *v = gDYYYFSOrientOrigIMPs[DYYYFSOrientKey(c, _cmd)];
        if (v) return (IMP)v.pointerValue;
    }
    return NULL;
}

static UIInterfaceOrientationMask DYYYFSSupportOrientSwizzled(id self, SEL _cmd) {
    IMP o = DYYYFSOrientOrigIMP(self, _cmd);
    UIInterfaceOrientationMask orig = o ? ((UIInterfaceOrientationMask (*)(id, SEL))o)(self, _cmd)
                                        : UIInterfaceOrientationMaskAllButUpsideDown;
    // 只覆盖"本来就允许横屏"的 VC；竖屏锁定的（信息流等）原样返回，绝不误伤
    if (gDYYYFSOrientForceLeft && (orig & UIInterfaceOrientationMaskLandscape)) {
        return UIInterfaceOrientationMaskLandscapeLeft;
    }
    return orig;
}

static UIInterfaceOrientation DYYYFSPreferredOrientSwizzled(id self, SEL _cmd) {
    IMP o = DYYYFSOrientOrigIMP(self, _cmd);
    UIInterfaceOrientation orig = o ? ((UIInterfaceOrientation (*)(id, SEL))o)(self, _cmd)
                                    : UIInterfaceOrientationPortrait;
    // 注意：这个方法的返回值是【单个方向】不是 mask，别拿它去按位与
    if (gDYYYFSOrientForceLeft &&
        (orig == UIInterfaceOrientationLandscapeLeft || orig == UIInterfaceOrientationLandscapeRight)) {
        return UIInterfaceOrientationLandscapeLeft;
    }
    return orig;
}

static UIInterfaceOrientationMask DYYYFSDelegateMaskSwizzled(id self, SEL _cmd, UIApplication *app, UIWindow *win) {
    if (gDYYYFSOrientForceLeft) return UIInterfaceOrientationMaskLandscapeLeft;
    IMP o = DYYYFSOrientOrigIMP(self, _cmd);
    return o ? ((UIInterfaceOrientationMask (*)(id, SEL, UIApplication *, UIWindow *))o)(self, _cmd, app, win)
             : UIInterfaceOrientationMaskAllButUpsideDown;
}

// 惰性安装（首次用到「反向全屏」时才做，无加载期开销）
static void DYYYFSInstallSourceOrientationHook(void) {
    if (gDYYYFSOrientHooked) return;
    gDYYYFSOrientHooked = YES;
    gDYYYFSOrientOrigIMPs = [NSMutableDictionary dictionary];

    // ① app delegate 的 mask
    SEL dsel = NSSelectorFromString(@"application:supportedInterfaceOrientationsForWindow:");
    id delegate = [UIApplication sharedApplication].delegate;
    Class ad = delegate ? object_getClass(delegate) : Nil;
    if (!ad) ad = objc_getClass("AppDelegate");
    if (ad) {
        Method m = class_getInstanceMethod(ad, dsel);
        if (m) {
            gDYYYFSOrientOrigIMPs[DYYYFSOrientKey(ad, dsel)] = [NSValue valueWithPointer:method_getImplementation(m)];
            if (!class_addMethod(ad, dsel, (IMP)DYYYFSDelegateMaskSwizzled, method_getTypeEncoding(m))) {
                method_setImplementation(m, (IMP)DYYYFSDelegateMaskSwizzled);
            }
            gDYYYFSOrientHookCount++;
        }
    }

    // ② 全类扫描：支持方向 / 首选方向
    int count = objc_getClassList(NULL, 0);
    if (count > 0) {
        Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
        if (classes) {
            count = objc_getClassList(classes, count);
            SEL sSupport = @selector(supportedInterfaceOrientations);
            SEL sPreferred = @selector(preferredInterfaceOrientationForPresentation);
            for (int i = 0; i < count; i++) {
                Class c = classes[i];
                if (!c) continue;
                unsigned int n = 0;
                Method *ms = class_copyMethodList(c, &n);
                if (!ms) continue;
                for (unsigned int j = 0; j < n; j++) {
                    SEL s = method_getName(ms[j]);
                    BOOL isSupport = (s == sSupport);
                    BOOL isPreferred = (s == sPreferred);
                    if (!isSupport && !isPreferred) continue;
                    IMP imp = method_getImplementation(ms[j]);
                    if (!imp || imp == (IMP)DYYYFSSupportOrientSwizzled || imp == (IMP)DYYYFSPreferredOrientSwizzled) continue;
                    NSString *k = DYYYFSOrientKey(c, s);
                    if (gDYYYFSOrientOrigIMPs[k]) continue;
                    gDYYYFSOrientOrigIMPs[k] = [NSValue valueWithPointer:imp];
                    method_setImplementation(ms[j], isSupport ? (IMP)DYYYFSSupportOrientSwizzled
                                                              : (IMP)DYYYFSPreferredOrientSwizzled);
                    gDYYYFSOrientHookCount++;
                }
                free(ms);
            }
            free(classes);
        }
    }
    DYYYFSDiag([NSString stringWithFormat:@"[fs-rev] 源头方向 hook 已装：%lu 处", (unsigned long)gDYYYFSOrientHookCount]);
}

// 读当前界面方向（iOS13+ 取前台活跃 windowScene；老系统回落 statusBarOrientation）
static UIInterfaceOrientation DYYYFSCurrentOrientation(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                return ((UIWindowScene *)scene).interfaceOrientation;
            }
        }
    }
    return [UIApplication sharedApplication].statusBarOrientation;
}

// 【兜底】强制界面旋转到指定方向 —— 三件套（geometry 请求 + KVC + attemptRotationToDeviceOrientation）。
// ⚠️ 这是带旋转动画的那一套（老板说的"转圈"），只在私有瞬时 API 不可用时才走。
// ⚠️ 第一次（v33）反向全屏真的能翻过去，靠的就是最后那句 attemptRotationToDeviceOrientation。
static void DYYYFSApplyOrientation(UIInterfaceOrientation target) {
    UIInterfaceOrientationMask mask = (target == UIInterfaceOrientationLandscapeLeft)
        ? UIInterfaceOrientationMaskLandscapeLeft : UIInterfaceOrientationMaskLandscapeRight;
    if (@available(iOS 16.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowSceneGeometryPreferencesIOS *prefs =
                    [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
                [(UIWindowScene *)scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
                    DYYYFSDiag([NSString stringWithFormat:@"[fs-rev] geometry 被拒 target=%ld err=%@",
                                (long)target, error.localizedDescription ?: @"-"]);
                }];
            }
        }
    }
    [[UIDevice currentDevice] setValue:@(target) forKey:@"orientation"];
    [UIViewController attemptRotationToDeviceOrientation];
}

// 反向全屏：进屏【前】把所有方向来源收窄成「只允许横屏右」→ 点抖音原生入口
// => UIKit 这次唯一可行方向就是右侧，抖音那一段旋转直接落右，**没有第二段旋转**（不转圈）。
// 收窄在进屏后 ~1.6s 关掉（正常路径此时按钮/播放器已完成布局，不再需要）。
// 只有入口没落右（说明抖音绕开了方向协商）时才事后补一次，属极端兜底。
static void DYYYFSEnterReverse(UIView *entryView) {
    if (!entryView) return;
    UIInterfaceOrientation target = DYYYFSReverseTarget();

    DYYYFSInstallSourceOrientationHook();
    gDYYYFSOrientForceLeft = YES;              // ⬅️ 关键：进屏前收窄为"仅横屏右"
    DYYYFSDiag(@"[fs-rev] 反向全屏：收窄为仅横屏右后进入");
    simulateTapOnEntryView(entryView);

    __block void (^poll)(NSInteger, NSInteger);
    poll = ^(NSInteger n, NSInteger stable) {
        UIInterfaceOrientation cur = DYYYFSCurrentOrientation();
        BOOL isLand = (cur == UIInterfaceOrientationLandscapeLeft || cur == UIInterfaceOrientationLandscapeRight);
        if (!isLand) {
            if (n < 14) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    poll(n + 1, 0);
                });
                return;
            }
            gDYYYFSOrientForceLeft = NO;
            DYYYFSDiag(@"[fs-rev] 2.1s 未进横屏，放弃");
            return;
        }
        // 连续两次读到同一个横屏方向 = 抖音的旋转动画已停稳（动画途中的瞬时读数不作数）
        if (stable < 2) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                poll(n + 1, stable + 1);
            });
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            gDYYYFSOrientForceLeft = NO;
        });
        if (cur == target) {
            DYYYFSDiag([NSString stringWithFormat:@"[fs-rev] ✅ 收窄生效：一次落到右侧 cur=%ld（无第二段旋转）", (long)cur]);
            return;
        }
        DYYYFSDiag([NSString stringWithFormat:@"[fs-rev] 收窄无效：入口落在 cur=%ld（目标%ld）→ 事后补一次", (long)cur, (long)target]);
        DYYYFSApplyOrientation(target);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIInterfaceOrientation b = DYYYFSCurrentOrientation();
            DYYYFSDiag([NSString stringWithFormat:@"[fs-rev] 0.8s 复核 cur=%ld (目标%ld)%@",
                        (long)b, (long)target, (b == target ? @" ✓" : @" ✗")]);
            if (b != target) DYYYFSApplyOrientation(target);
        });
    };
    poll(1, 0);
}

// 「反向全屏」菜单项开关：未设置过 = 默认显示（老板要求默认打开）
static BOOL DYYYFSReverseItemEnabled(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *key = @"DYYYLongPressFullScreenReverse";
    return [d objectForKey:key] == nil ? YES : [d boolForKey:key];
}

// 定时关闭：后台兜底检查定时器（解决 dispatch_after 在深度休眠时主队列不 drain 的问题）
static NSTimer *dyyyTimerCloseCheckTimer = nil;

static void DYYYStopTimerCloseCheck(void) {
    if (dyyyTimerCloseCheckTimer) {
        [dyyyTimerCloseCheckTimer invalidate];
        dyyyTimerCloseCheckTimer = nil;
    }
}

static void DYYYPerformTimerClose(void) {
    DYYYStopTimerCloseCheck();
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"DYYYTimerShutdownTime"];
    DYYYConfirmCloseView *confirmView = [[DYYYConfirmCloseView alloc] initWithTitle:@"定时关闭" message:@"定时关闭时间已到，是否关闭抖音？"];
    [confirmView show];
}

static void DYYYStartTimerCloseCheck(void) {
    DYYYStopTimerCloseCheck();
    dyyyTimerCloseCheckTimer = [NSTimer timerWithTimeInterval:60.00 repeats:YES block:^(NSTimer *timer) {
        NSNumber *shutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
        if (shutdownTime != nil && [shutdownTime doubleValue] <= [[NSDate date] timeIntervalSince1970]) {
            DYYYPerformTimerClose();
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:dyyyTimerCloseCheckTimer forMode:NSRunLoopCommonModes];
}

%hook AWELongPressPanelViewGroupModel
%property(nonatomic, assign) BOOL isDYYYCustomGroup;
%end

// Modern风格长按面板（新版UI）
%hook AWEModernLongPressPanelTableViewController
- (NSArray *)dataArray {
    // 检查是否开启精简模式
    BOOL simplifyPanel = DYYYGetBool(@"DYYYSimplifyLongPressPanel");

    NSArray *originalArray = %orig;
    if (!originalArray) {
        originalArray = @[];
    }

    // 如果开启精简模式，直接跳过原始面板处理，只返回自定义选项
    if (simplifyPanel) {
        originalArray = @[]; // 清空原始数组
    } else {
        // 获取需要隐藏的按钮设置（从文本输入框读取，逗号分隔）
        NSString *hidePanelItems = DYYYGetString(@"DYYYHidePanelItems");
        NSMutableSet<NSString *> *hideItemsLowerSet = [NSMutableSet set];

        if (hidePanelItems && hidePanelItems.length > 0) {
            // 支持中英文逗号分隔
            NSString *normalizedItems = [hidePanelItems stringByReplacingOccurrencesOfString:@"，" withString:@","];
            NSArray *items = [normalizedItems componentsSeparatedByString:@","];
            for (NSString *item in items) {
                NSString *trimmedItem = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmedItem.length > 0) {
                    [hideItemsLowerSet addObject:[trimmedItem lowercaseString]];
                }
            }
        }

        // 如果有需要隐藏的项目，才进行过滤
        if (hideItemsLowerSet.count > 0) {
            NSMutableArray *modifiedOriginalGroups = [NSMutableArray array];

            for (id group in originalArray) {
                if ([group isKindOfClass:%c(AWELongPressPanelViewGroupModel)]) {
                    AWELongPressPanelViewGroupModel *groupModel = (AWELongPressPanelViewGroupModel *)group;
                    NSMutableArray *filteredGroupArr = [NSMutableArray array];

                    for (id item in groupModel.groupArr) {
                        if ([item isKindOfClass:%c(AWELongPressPanelBaseViewModel)]) {
                            AWELongPressPanelBaseViewModel *viewModel = (AWELongPressPanelBaseViewModel *)item;
                            NSString *descString = viewModel.describeString;

                            BOOL shouldHide = NO;
                            if (descString && descString.length > 0) {
                                NSString *descLower = [descString lowercaseString];

                                // 精确匹配
                                if ([hideItemsLowerSet containsObject:descLower]) {
                                    shouldHide = YES;
                                } else {
                                    // 部分匹配
                                    for (NSString *hideItemLower in hideItemsLowerSet) {
                                        if ([descLower containsString:hideItemLower] || [hideItemLower containsString:descLower]) {
                                            shouldHide = YES;
                                            break;
                                        }
                                    }
                                }
                            }

                            if (!shouldHide) {
                                [filteredGroupArr addObject:item];
                            }
                        } else {
                            [filteredGroupArr addObject:item];
                        }
                    }

                    if (filteredGroupArr.count > 0) {
                        AWELongPressPanelViewGroupModel *filteredGroup = [[%c(AWELongPressPanelViewGroupModel) alloc] init];
                        filteredGroup.groupType = groupModel.groupType;
                        filteredGroup.isModern = groupModel.isModern;
                        filteredGroup.groupArr = filteredGroupArr;
                        [modifiedOriginalGroups addObject:filteredGroup];
                    }
                } else {
                    [modifiedOriginalGroups addObject:group];
                }
            }
            originalArray = modifiedOriginalGroups;
        }
    }

    // 检查是否启用了任意长按功能
    BOOL hasAnyFeatureEnabled = NO;
    // 检查各个单独的功能开关
    BOOL enableSaveVideo = DYYYGetBool(@"DYYYLongPressSaveVideo");
    BOOL enableSaveCover = DYYYGetBool(@"DYYYLongPressSaveCover");
    BOOL enableSaveAudio = DYYYGetBool(@"DYYYLongPressSaveAudio");
    BOOL enableSaveCurrentImage = DYYYGetBool(@"DYYYLongPressSaveCurrentImage");
    BOOL enableSaveAllImages = DYYYGetBool(@"DYYYLongPressSaveAllImages");
    BOOL enableCopyText = DYYYGetBool(@"DYYYLongPressCopyText");
    BOOL enableCopyLink = DYYYGetBool(@"DYYYLongPressCopyLink");
    BOOL enableApiDownload = DYYYGetBool(@"DYYYLongPressApiDownload");
    BOOL enableFilterUser = DYYYGetBool(@"DYYYLongPressFilterUser");
    BOOL enableFilterKeyword = DYYYGetBool(@"DYYYLongPressFilterTitle");
    BOOL enableTimerClose = DYYYGetBool(@"DYYYLongPressTimerClose");
    BOOL enableCreateVideo = DYYYGetBool(@"DYYYLongPressCreateVideo");

    // 检查是否有任何功能启用
    hasAnyFeatureEnabled = enableSaveVideo || enableSaveCover || enableSaveAudio || enableSaveCurrentImage || enableSaveAllImages || enableCopyText || enableCopyLink || enableApiDownload ||
                           enableFilterUser || enableFilterKeyword || enableTimerClose || enableCreateVideo;

    // 如果没有任何功能启用，仅使用官方按钮
    if (!hasAnyFeatureEnabled) {
        return originalArray;
    }

    // 创建自定义功能按钮
    NSMutableArray *viewModels = [NSMutableArray array];

    BOOL isNewLivePhoto = (self.awemeModel.video && self.awemeModel.animatedImageVideoInfo != nil);

    // 视频下载功能 (非实况照片才显示)
    if (enableSaveVideo && self.awemeModel.awemeType != 68 && !isNewLivePhoto) {
        AWELongPressPanelBaseViewModel *downloadViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        downloadViewModel.awemeModel = self.awemeModel;
        downloadViewModel.actionType = 666;
        downloadViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        downloadViewModel.describeString = @"保存视频";
        downloadViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          AWEVideoModel *videoModel = awemeModel.video;
          AWEMusicModel *musicModel = awemeModel.music;
          NSURL *audioURL = nil;
          if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
              audioURL = [NSURL URLWithString:musicModel.playURL.originURLList.firstObject];
          }

                  // 收集全部候选 URL（h264 优先，playURL 兜底），首个 CDN 失败自动切换
                  NSMutableArray<NSURL *> *videoURLs = [NSMutableArray array];
                  if (videoModel.h264URL && videoModel.h264URL.originURLList.count > 0) {
                      for (NSString *urlString in videoModel.h264URL.originURLList) {
                          NSURL *url = [NSURL URLWithString:urlString];
                          if (url) {
                              [videoURLs addObject:url];
                          }
                      }
                  }
                  if (videoModel.playURL && videoModel.playURL.originURLList.count > 0) {
                      for (NSString *urlString in videoModel.playURL.originURLList) {
                          NSURL *url = [NSURL URLWithString:urlString];
                          if (url && ![videoURLs containsObject:url]) {
                              [videoURLs addObject:url];
                          }
                      }
                  }

                  if (videoURLs.count > 0) {
                      [DYYYManager downloadMediaFromURLs:videoURLs
                                               mediaType:MediaTypeVideo
                                                   audio:audioURL
                                              completion:^(BOOL success){
                                              }];
                  } else {
                      [DYYYUtils showToast:@"没有找到可用的视频地址"];
                  }
              
          
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:downloadViewModel];
    }

    //  新版实况照片保存
    if (enableSaveVideo && self.awemeModel.awemeType != 68 && isNewLivePhoto) {
        AWELongPressPanelBaseViewModel *livePhotoViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        livePhotoViewModel.awemeModel = self.awemeModel;
        livePhotoViewModel.actionType = 679;
        livePhotoViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        livePhotoViewModel.describeString = @"保存实况";
        livePhotoViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          AWEVideoModel *videoModel = awemeModel.video;

          // 使用封面URL作为图片URL
          NSURL *imageURL = nil;
          if (videoModel.coverURL && videoModel.coverURL.originURLList.count > 0) {
              imageURL = [NSURL URLWithString:videoModel.coverURL.originURLList.firstObject];
          }

          // 视频URL从视频模型获取
          NSURL *videoURL = nil;
          if (videoModel && videoModel.playURL && videoModel.playURL.originURLList.count > 0) {
              videoURL = [NSURL URLWithString:videoModel.playURL.originURLList.firstObject];
          } else if (videoModel && videoModel.h264URL && videoModel.h264URL.originURLList.count > 0) {
              videoURL = [NSURL URLWithString:videoModel.h264URL.originURLList.firstObject];
          }

          // 下载实况照片
          if (imageURL && videoURL) {
              [DYYYManager downloadLivePhoto:imageURL
                                    videoURL:videoURL
                                  completion:^{
                                  }];
          }

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:livePhotoViewModel];
    }

    // 当前图片/实况下载功能
    if (enableSaveCurrentImage && self.awemeModel.awemeType == 68 && self.awemeModel.albumImages.count > 0) {
        AWELongPressPanelBaseViewModel *imageViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        imageViewModel.awemeModel = self.awemeModel;
        imageViewModel.actionType = 669;
        imageViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";

        if (self.awemeModel.albumImages.count == 1) {
            imageViewModel.describeString = @"保存图片";
        } else {
            imageViewModel.describeString = @"保存当前图片";
        }

        AWEImageAlbumImageModel *currimge = self.awemeModel.albumImages[self.awemeModel.currentImageIndex - 1];
        if (currimge.clipVideo != nil || self.awemeModel.isLivePhoto) {
            if (self.awemeModel.albumImages.count == 1) {
                imageViewModel.describeString = @"保存实况";
            } else {
                imageViewModel.describeString = @"保存当前实况";
            }
        }
        imageViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          AWEImageAlbumImageModel *currentImageModel = nil;
          if (awemeModel.currentImageIndex > 0 && awemeModel.currentImageIndex <= awemeModel.albumImages.count) {
              currentImageModel = awemeModel.albumImages[awemeModel.currentImageIndex - 1];
          } else {
              currentImageModel = awemeModel.albumImages.firstObject;
          }
          // 如果是实况的话
          // 查找非.image后缀的URL
          NSURL *downloadURL = nil;
          for (NSString *urlString in currentImageModel.urlList) {
              NSURL *url = [NSURL URLWithString:urlString];
              NSString *pathExtension = [url.path.lowercaseString pathExtension];
              if (![pathExtension isEqualToString:@"image"]) {
                  downloadURL = url;
                  break;
              }
          }

          if (currentImageModel.clipVideo != nil) {
              NSURL *videoURL = [currentImageModel.clipVideo.playURL getDYYYSrcURLDownload];
              [DYYYManager downloadLivePhoto:downloadURL
                                    videoURL:videoURL
                                  completion:^{
                                  }];
          } else if (currentImageModel && currentImageModel.urlList.count > 0) {
              if (downloadURL) {
                  [DYYYManager downloadMedia:downloadURL
                                   mediaType:MediaTypeImage
                                       audio:nil
                                  completion:^(BOOL success) {
                                    if (success) {
                                    } else {
                                        [DYYYUtils showToast:@"图片保存已取消"];
                                    }
                                  }];
              } else {
                  [DYYYUtils showToast:@"没有找到合适格式的图片"];
              }
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:imageViewModel];
    }

    // 保存所有图片/实况功能
    if (enableSaveAllImages && self.awemeModel.awemeType == 68 && self.awemeModel.albumImages.count > 1) {
        AWELongPressPanelBaseViewModel *allImagesViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        allImagesViewModel.awemeModel = self.awemeModel;
        allImagesViewModel.actionType = 670;
        allImagesViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        allImagesViewModel.describeString = @"保存所有图片";
        // 检查是否有实况照片并更改按钮文字
        BOOL hasLivePhoto = NO;
        for (AWEImageAlbumImageModel *imageModel in self.awemeModel.albumImages) {
            if (imageModel.clipVideo != nil) {
                hasLivePhoto = YES;
                break;
            }
        }
        if (hasLivePhoto) {
            allImagesViewModel.describeString = @"保存所有实况";
        }
        allImagesViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          NSMutableArray *imageURLs = [NSMutableArray array];
          NSMutableArray *livePhotos = [NSMutableArray array];

          for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
              if (imageModel.urlList.count > 0) {
                  // 查找非.image后缀的URL
                  NSURL *downloadURL = nil;
                  for (NSString *urlString in imageModel.urlList) {
                      NSURL *url = [NSURL URLWithString:urlString];
                      NSString *pathExtension = [url.path.lowercaseString pathExtension];
                      if (![pathExtension isEqualToString:@"image"]) {
                          downloadURL = url;
                          break;
                      }
                  }

                  if (!downloadURL && imageModel.urlList.count > 0) {
                      downloadURL = [NSURL URLWithString:imageModel.urlList.firstObject];
                  }

                  // 检查是否是实况照片
                  if (imageModel.clipVideo != nil) {
                      NSURL *videoURL = [imageModel.clipVideo.playURL getDYYYSrcURLDownload];
                      [livePhotos addObject:@{@"imageURL" : downloadURL.absoluteString, @"videoURL" : videoURL.absoluteString}];
                  } else {
                      [imageURLs addObject:downloadURL.absoluteString];
                  }
              }
          }

          // 分别处理普通图片和实况照片
          if (livePhotos.count > 0) {
              [DYYYManager downloadAllLivePhotos:livePhotos];
          }

          if (imageURLs.count > 0) {
              [DYYYManager downloadAllImages:imageURLs];
          }

          if (livePhotos.count == 0 && imageURLs.count == 0) {
              [DYYYUtils showToast:@"没有找到合适格式的图片"];
          }

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:allImagesViewModel];
    }

    // 接口保存功能
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYInterfaceDownload"];
    if (enableApiDownload && apiKey.length > 0) {
        AWELongPressPanelBaseViewModel *apiDownload = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        apiDownload.awemeModel = self.awemeModel;
        apiDownload.actionType = 673;
        apiDownload.duxIconName = @"ic_cloudarrowdown_outlined_20";
        apiDownload.describeString = @"接口保存";
        apiDownload.action = ^{
          NSString *shareLink = [self.awemeModel valueForKey:@"shareURL"];
          if (shareLink.length == 0) {
              [DYYYUtils showToast:@"无法获取分享链接"];
              return;
          }
          // 使用封装的方法进行解析下载
          [DYYYManager parseAndDownloadVideoWithShareLink:shareLink apiKey:apiKey];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:apiDownload];
    }

    // 封面下载功能
    if (enableSaveCover && self.awemeModel.awemeType != 68) {
        AWELongPressPanelBaseViewModel *coverViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        coverViewModel.awemeModel = self.awemeModel;
        coverViewModel.actionType = 667;
        coverViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        coverViewModel.describeString = @"保存封面";
        coverViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          AWEVideoModel *videoModel = awemeModel.video;
          NSMutableArray<NSURL *> *coverURLs = [NSMutableArray array];
          if (videoModel && videoModel.coverURL && videoModel.coverURL.originURLList.count > 0) {
              for (NSString *urlString in videoModel.coverURL.originURLList) {
                  NSURL *url = [NSURL URLWithString:urlString];
                  if (url) {
                      [coverURLs addObject:url];
                  }
              }
          }
          if (coverURLs.count > 0) {
              [DYYYManager downloadMediaFromURLs:coverURLs
                                       mediaType:MediaTypeImage
                                           audio:nil
                                      completion:^(BOOL success) {
                                        if (success) {
                                        } else {
                                            [DYYYUtils showToast:@"封面保存已取消"];
                                        }
                                      }];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:coverViewModel];
    }

    // 全屏观看功能（老代码原样保留：永远抖音原生方向、只转一次，不做任何方向干预）
    if (enableCopyText) {
        AWELongPressPanelBaseViewModel *fullScreen = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        fullScreen.awemeModel = self.awemeModel;
        fullScreen.actionType = 671;
        fullScreen.duxIconName = @"ic_fullscreen_outlined";
        fullScreen.describeString = @"全屏观看";
        fullScreen.action = ^{
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:^{
            UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
            UIView *entryView = findLandscapeEntryViewInView(keyWindow);
            simulateTapOnEntryView(entryView);
          }];
        };
        [viewModels addObject:fullScreen];

        // 反向全屏：与「全屏观看」方向相反。做法=动作期间临时收紧允许方向为「仅横屏右」，
        // 让抖音原生入口直接落右边（一次到位，不再"先进左边再翻"）。开关默认开启。
        if (DYYYFSReverseItemEnabled()) {
            AWELongPressPanelBaseViewModel *fullScreenRev = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
            fullScreenRev.awemeModel = self.awemeModel;
            fullScreenRev.actionType = 680;
            fullScreenRev.duxIconName = @"ic_fullscreen_outlined";
            fullScreenRev.describeString = @"反向全屏";
            fullScreenRev.action = ^{
              AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
              [panelManager dismissWithAnimation:YES completion:^{
                UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
                UIView *entryView = findLandscapeEntryViewInView(keyWindow);
                DYYYFSEnterReverse(entryView);
              }];
            };
            [viewModels addObject:fullScreenRev];
        }
    }

    // 音频下载功能
    if (enableSaveAudio) {
        AWELongPressPanelBaseViewModel *audioViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        audioViewModel.awemeModel = self.awemeModel;
        audioViewModel.actionType = 668;
        audioViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        audioViewModel.describeString = @"保存音频";
        audioViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          AWEMusicModel *musicModel = awemeModel.music;
          NSMutableArray<NSURL *> *audioURLs = [NSMutableArray array];
          if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
              for (NSString *urlString in musicModel.playURL.originURLList) {
                  NSURL *url = [NSURL URLWithString:urlString];
                  if (url) {
                      [audioURLs addObject:url];
                  }
              }
          }
          if (audioURLs.count > 0) {
              [DYYYManager downloadMediaFromURLs:audioURLs mediaType:MediaTypeAudio audio:nil completion:nil];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:audioViewModel];
    }

    // 创建视频功能
    if (enableCreateVideo && self.awemeModel.awemeType == 68) {
        AWELongPressPanelBaseViewModel *createVideoViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        createVideoViewModel.awemeModel = self.awemeModel;
        createVideoViewModel.actionType = 677;
        createVideoViewModel.duxIconName = @"ic_videosearch_outlined_20";
        createVideoViewModel.describeString = @"制作视频";
        createVideoViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;

          // 收集普通图片URL
          NSMutableArray *imageURLs = [NSMutableArray array];
          // 收集实况照片信息（图片URL+视频URL）
          NSMutableArray *livePhotos = [NSMutableArray array];

          // 获取背景音乐URL
          NSString *bgmURL = nil;
          if (awemeModel.music && awemeModel.music.playURL && awemeModel.music.playURL.originURLList.count > 0) {
              bgmURL = awemeModel.music.playURL.originURLList.firstObject;
          }

          // 处理所有图片和实况
          for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
              if (imageModel.urlList.count > 0) {
                  // 查找非.image后缀的URL
                  NSString *bestURL = nil;
                  for (NSString *urlString in imageModel.urlList) {
                      NSURL *url = [NSURL URLWithString:urlString];
                      NSString *pathExtension = [url.path.lowercaseString pathExtension];
                      if (![pathExtension isEqualToString:@"image"]) {
                          bestURL = urlString;
                          break;
                      }
                  }

                  if (!bestURL && imageModel.urlList.count > 0) {
                      bestURL = imageModel.urlList.firstObject;
                  }

                  // 如果是实况照片，需要收集图片和视频URL
                  if (imageModel.clipVideo != nil) {
                      NSURL *videoURL = [imageModel.clipVideo.playURL getDYYYSrcURLDownload];
                      if (videoURL) {
                          [livePhotos addObject:@{@"imageURL" : bestURL, @"videoURL" : videoURL.absoluteString}];
                      }
                  } else {
                      // 普通图片
                      [imageURLs addObject:bestURL];
                  }
              }
          }

          // 调用视频创建API
          [DYYYManager createVideoFromMedia:imageURLs
              livePhotos:livePhotos
              bgmURL:bgmURL
              progress:^(NSInteger current, NSInteger total, NSString *status) {
              }
              completion:^(BOOL success, NSString *message) {
                if (success) {
                } else {
                    [DYYYUtils showToast:[NSString stringWithFormat:@"视频制作失败: %@", message]];
                }
              }];

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:createVideoViewModel];
    }

    // 复制分享链接功能
    if (enableCopyLink) {
        AWELongPressPanelBaseViewModel *copyShareLink = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        copyShareLink.awemeModel = self.awemeModel;
        copyShareLink.actionType = 672;
        copyShareLink.duxIconName = @"ic_share_outlined";
        copyShareLink.describeString = @"复制链接";
        copyShareLink.action = ^{
          NSString *shareLink = [self.awemeModel valueForKey:@"shareURL"];
          NSString *cleanedURL = cleanShareURL(shareLink);
          [[UIPasteboard generalPasteboard] setString:cleanedURL];
          [DYYYToast showSuccessToastWithMessage:@"分享链接已复制"];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:copyShareLink];
    }

    // 过滤用户功能
    if (enableFilterUser) {
        AWELongPressPanelBaseViewModel *filterKeywords = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        filterKeywords.awemeModel = self.awemeModel;
        filterKeywords.actionType = 674;
        filterKeywords.duxIconName = @"ic_userban_outlined_20";
        filterKeywords.describeString = @"过滤用户";
        filterKeywords.action = ^{
          AWEUserModel *author = self.awemeModel.author;
          NSString *nickname = author.nickname ?: @"未知用户";
          NSString *shortId = author.shortID ?: @"";
          // 创建当前用户的过滤格式 "nickname-shortid"
          NSString *currentUserFilter = [NSString stringWithFormat:@"%@-%@", nickname, shortId];
          // 获取保存的过滤用户列表
          NSString *savedUsers = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterUsers"] ?: @"";
          NSArray *userArray = [savedUsers length] > 0 ? [savedUsers componentsSeparatedByString:@","] : @[];
          BOOL userExists = NO;
          for (NSString *userInfo in userArray) {
              NSArray *components = [userInfo componentsSeparatedByString:@"-"];
              if (components.count >= 2) {
                  NSString *userId = [components lastObject];
                  if ([userId isEqualToString:shortId] && shortId.length > 0) {
                      userExists = YES;
                      break;
                  }
              }
          }
          NSString *actionButtonText = userExists ? @"取消过滤" : @"添加过滤";
          [DYYYBottomAlertView showAlertWithTitle:@"过滤用户视频"
              message:[NSString stringWithFormat:@"用户: %@ (ID: %@)", nickname, shortId]
              avatarURL:nil
              cancelButtonText:@"管理过滤列表"
              confirmButtonText:actionButtonText
              cancelAction:^{
                DYYYKeywordListView *keywordListView = [[DYYYKeywordListView alloc] initWithTitle:@"过滤用户列表" keywords:userArray];
                keywordListView.onConfirm = ^(NSArray *users) {
                  NSString *userString = [users componentsJoinedByString:@","];
                  [[NSUserDefaults standardUserDefaults] setObject:userString forKey:@"DYYYFilterUsers"];
                  [DYYYUtils showToast:@"过滤用户列表已更新"];
                };
                [keywordListView show];
              }
              closeAction:nil
              confirmAction:^{
                // 添加或移除用户过滤
                NSMutableArray *updatedUsers = [NSMutableArray arrayWithArray:userArray];
                if (userExists) {
                    // 移除用户
                    NSMutableArray *toRemove = [NSMutableArray array];
                    for (NSString *userInfo in updatedUsers) {
                        NSArray *components = [userInfo componentsSeparatedByString:@"-"];
                        if (components.count >= 2) {
                            NSString *userId = [components lastObject];
                            if ([userId isEqualToString:shortId]) {
                                [toRemove addObject:userInfo];
                            }
                        }
                    }
                    [updatedUsers removeObjectsInArray:toRemove];
                    [DYYYUtils showToast:@"已从过滤列表中移除此用户"];
                } else {
                    // 添加用户
                    [updatedUsers addObject:currentUserFilter];
                    [DYYYUtils showToast:@"已添加此用户到过滤列表"];
                }
                // 保存更新后的列表
                NSString *updatedUserString = [updatedUsers componentsJoinedByString:@","];
                [[NSUserDefaults standardUserDefaults] setObject:updatedUserString forKey:@"DYYYFilterUsers"];
              }];
        };
        [viewModels addObject:filterKeywords];
    }

    // 过滤文案功能
    if (enableFilterKeyword) {
        AWELongPressPanelBaseViewModel *filterKeywords = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        filterKeywords.awemeModel = self.awemeModel;
        filterKeywords.actionType = 675;
        filterKeywords.duxIconName = @"ic_funnel_outlined_20";
        filterKeywords.describeString = @"过滤文案";
        filterKeywords.action = ^{
          NSString *descText = [self.awemeModel valueForKey:@"descriptionString"];
          NSString *propName = nil;
          if (self.awemeModel.propGuideV2) {
              propName = self.awemeModel.propGuideV2.propName;
          }
          DYYYFilterSettingsView *filterView = [[DYYYFilterSettingsView alloc] initWithTitle:@"过滤关键词调整" text:descText propName:propName];
          filterView.onConfirm = ^(NSString *selectedText) {
            if (selectedText.length > 0) {
                NSString *currentKeywords = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterKeywords"] ?: @"";
                NSString *newKeywords;
                if (currentKeywords.length > 0) {
                    newKeywords = [NSString stringWithFormat:@"%@,%@", currentKeywords, selectedText];
                } else {
                    newKeywords = selectedText;
                }
                [[NSUserDefaults standardUserDefaults] setObject:newKeywords forKey:@"DYYYFilterKeywords"];
                [DYYYUtils showToast:[NSString stringWithFormat:@"已添加过滤词: %@", selectedText]];
            }
          };
          // 设置过滤关键词按钮回调
          filterView.onKeywordFilterTap = ^{
            // 获取保存的关键词
            NSString *savedKeywords = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterKeywords"] ?: @"";
            NSArray *keywordArray = [savedKeywords length] > 0 ? [savedKeywords componentsSeparatedByString:@","] : @[];
            // 创建并显示关键词列表视图
            DYYYKeywordListView *keywordListView = [[DYYYKeywordListView alloc] initWithTitle:@"设置过滤关键词" keywords:keywordArray];
            // 设置确认回调
            keywordListView.onConfirm = ^(NSArray *keywords) {
              // 将关键词数组转换为逗号分隔的字符串
              NSString *keywordString = [keywords componentsJoinedByString:@","];
              // 保存到用户默认设置
              [[NSUserDefaults standardUserDefaults] setObject:keywordString forKey:@"DYYYFilterKeywords"];
              // 显示提示
              [DYYYUtils showToast:@"过滤关键词已更新"];
            };
            // 显示关键词列表视图
            [keywordListView show];
          };
          [filterView show];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:filterKeywords];
    }

    if (enableTimerClose) {
        AWELongPressPanelBaseViewModel *timerCloseViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        timerCloseViewModel.awemeModel = self.awemeModel;
        timerCloseViewModel.actionType = 676;
        timerCloseViewModel.duxIconName = @"ic_c_alarm_outlined";
        // 检查是否已有定时任务在运行
        NSNumber *shutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
        BOOL hasActiveTimer = shutdownTime != nil && [shutdownTime doubleValue] > [[NSDate date] timeIntervalSince1970];
        timerCloseViewModel.describeString = hasActiveTimer ? @"取消定时" : @"定时关闭";
        timerCloseViewModel.action = ^{
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          NSNumber *shutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
          BOOL hasActiveTimer = shutdownTime != nil && [shutdownTime doubleValue] > [[NSDate date] timeIntervalSince1970];
          if (hasActiveTimer) {
              [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"DYYYTimerShutdownTime"];
              DYYYStopTimerCloseCheck();
              [DYYYUtils showToast:@"已取消定时关闭任务"];
              return;
          }
          // 读取上次设置的时间
          NSInteger defaultMinutes = [[NSUserDefaults standardUserDefaults] integerForKey:@"DYYYTimerCloseMinutes"];
          if (defaultMinutes <= 0) {
              defaultMinutes = 5;
          }
          NSString *defaultText = [NSString stringWithFormat:@"%ld", (long)defaultMinutes];
          DYYYCustomInputView *inputView = [[DYYYCustomInputView alloc] initWithTitle:@"设置定时关闭时间" defaultText:defaultText placeholder:@"请输入关闭时间(单位:分钟)"];
          inputView.onConfirm = ^(NSString *inputText) {
            NSInteger minutes = [inputText integerValue];
            if (minutes <= 0) {
                minutes = 5;
            }
            // 保存用户设置的时间以供下次使用
            [[NSUserDefaults standardUserDefaults] setInteger:minutes forKey:@"DYYYTimerCloseMinutes"];
            NSInteger seconds = minutes * 60;
            NSTimeInterval shutdownTimeValue = [[NSDate date] timeIntervalSince1970] + seconds;
            [[NSUserDefaults standardUserDefaults] setObject:@(shutdownTimeValue) forKey:@"DYYYTimerShutdownTime"];
            [DYYYUtils showToast:[NSString stringWithFormat:@"抖音将在%ld分钟后关闭...", (long)minutes]];
            DYYYStartTimerCloseCheck();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              NSNumber *currentShutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
              if (currentShutdownTime != nil && [currentShutdownTime doubleValue] <= [[NSDate date] timeIntervalSince1970]) {
                  DYYYPerformTimerClose();
              }
            });
          };
          [inputView show];
        };
        [viewModels addObject:timerCloseViewModel];
    }

    // 创建自定义组
    NSMutableArray *customGroups = [NSMutableArray array];
    NSInteger totalButtons = viewModels.count;

    // 根据按钮总数确定每行的按钮数
    NSInteger firstRowCount = 0;
    NSInteger secondRowCount = 0;

    // 确定分配方式与原代码相同
    if (totalButtons <= 2) {
        firstRowCount = totalButtons;
    } else if (totalButtons <= 4) {
        firstRowCount = totalButtons / 2;
        secondRowCount = totalButtons - firstRowCount;
    } else if (totalButtons <= 5) {
        firstRowCount = 3;
        secondRowCount = totalButtons - firstRowCount;
    } else if (totalButtons <= 6) {
        firstRowCount = 4;
        secondRowCount = totalButtons - firstRowCount;
    } else if (totalButtons <= 8) {
        firstRowCount = 4;
        secondRowCount = totalButtons - firstRowCount;
    } else {
        firstRowCount = 5;
        secondRowCount = totalButtons - firstRowCount;
    }

    // 创建第一行
    if (firstRowCount > 0) {
        NSArray<AWELongPressPanelBaseViewModel *> *firstRowButtons = [viewModels subarrayWithRange:NSMakeRange(0, firstRowCount)];
        AWELongPressPanelViewGroupModel *firstRowGroup = [[%c(AWELongPressPanelViewGroupModel) alloc] init];
        firstRowGroup.isDYYYCustomGroup = YES;
        firstRowGroup.groupType = (firstRowCount <= 3) ? 11 : 12;
        firstRowGroup.isModern = YES;
        firstRowGroup.groupArr = firstRowButtons;
        [customGroups addObject:firstRowGroup];
    }

    // 创建第二行
    if (secondRowCount > 0) {
        NSArray<AWELongPressPanelBaseViewModel *> *secondRowButtons = [viewModels subarrayWithRange:NSMakeRange(firstRowCount, secondRowCount)];
        AWELongPressPanelViewGroupModel *secondRowGroup = [[%c(AWELongPressPanelViewGroupModel) alloc] init];
        secondRowGroup.isDYYYCustomGroup = YES;
        secondRowGroup.groupType = (secondRowCount <= 3) ? 11 : 12;
        secondRowGroup.isModern = YES;
        secondRowGroup.groupArr = secondRowButtons;
        [customGroups addObject:secondRowGroup];
    }

    return [customGroups arrayByAddingObjectsFromArray:originalArray];
}
%end

// 修复Modern风格长按面板水平设置单元格的大小计算
%hook AWEModernLongPressHorizontalSettingCell
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.longPressViewGroupModel && [self.longPressViewGroupModel isDYYYCustomGroup]) {
        if (self.dataArray && indexPath.item < self.dataArray.count) {
            CGFloat totalWidth = collectionView.bounds.size.width;
            NSInteger itemCount = self.dataArray.count;
            CGFloat itemWidth = totalWidth / itemCount;
            return CGSizeMake(itemWidth, 73);
        }
        return CGSizeMake(73, 73);
    }
    return %orig;
}
%end

// 修复Modern风格长按面板交互单元格的大小计算
%hook AWEModernLongPressInteractiveCell
- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.longPressViewGroupModel && [self.longPressViewGroupModel isDYYYCustomGroup]) {
        if (self.dataArray && indexPath.item < self.dataArray.count) {
            NSInteger itemCount = self.dataArray.count;
            CGFloat totalWidth = collectionView.bounds.size.width - 12 * (itemCount - 1);
            CGFloat itemWidth = totalWidth / itemCount;
            return CGSizeMake(itemWidth, 73);
        }
        return CGSizeMake(73, 73);
    }
    return %orig;
}
%end

// 经典风格长按面板
%hook AWELongPressPanelTableViewController
- (NSArray *)dataArray {
    NSArray *originalArray = %orig;
    if (!originalArray) {
        originalArray = @[];
    }
    if (!self.awemeModel.author.nickname) {
        return originalArray;
    }

    // 检查是否开启精简模式
    BOOL simplifyPanel = DYYYGetBool(@"DYYYSimplifyLongPressPanel");

    // 如果开启精简模式，直接跳过原始面板处理，只返回自定义选项
    if (simplifyPanel) {
        originalArray = @[]; // 清空原始数组
    } else {
        // 获取需要隐藏的按钮设置（从文本输入框读取，逗号分隔）
        NSString *hidePanelItems = DYYYGetString(@"DYYYHidePanelItems");
        NSMutableSet<NSString *> *hideItemsLowerSet = [NSMutableSet set];

        if (hidePanelItems && hidePanelItems.length > 0) {
            // 支持中英文逗号分隔
            NSString *normalizedItems = [hidePanelItems stringByReplacingOccurrencesOfString:@"，" withString:@","];
            NSArray *items = [normalizedItems componentsSeparatedByString:@","];
            for (NSString *item in items) {
                NSString *trimmedItem = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmedItem.length > 0) {
                    [hideItemsLowerSet addObject:[trimmedItem lowercaseString]];
                }
            }
        }

        // 如果有需要隐藏的项目，才进行过滤
        if (hideItemsLowerSet.count > 0) {
            NSMutableArray *modifiedOriginalGroups = [NSMutableArray array];

            for (id group in originalArray) {
                if ([group isKindOfClass:%c(AWELongPressPanelViewGroupModel)]) {
                    AWELongPressPanelViewGroupModel *groupModel = (AWELongPressPanelViewGroupModel *)group;
                    NSMutableArray *filteredGroupArr = [NSMutableArray array];

                    for (id item in groupModel.groupArr) {
                        if ([item isKindOfClass:%c(AWELongPressPanelBaseViewModel)]) {
                            AWELongPressPanelBaseViewModel *viewModel = (AWELongPressPanelBaseViewModel *)item;
                            NSString *descString = viewModel.describeString;

                            BOOL shouldHide = NO;
                            if (descString && descString.length > 0) {
                                NSString *descLower = [descString lowercaseString];

                                // 精确匹配
                                if ([hideItemsLowerSet containsObject:descLower]) {
                                    shouldHide = YES;
                                } else {
                                    // 部分匹配
                                    for (NSString *hideItemLower in hideItemsLowerSet) {
                                        if ([descLower containsString:hideItemLower] || [hideItemLower containsString:descLower]) {
                                            shouldHide = YES;
                                            break;
                                        }
                                    }
                                }
                            }

                            if (!shouldHide) {
                                [filteredGroupArr addObject:item];
                            }
                        } else {
                            [filteredGroupArr addObject:item];
                        }
                    }

                    if (filteredGroupArr.count > 0) {
                        AWELongPressPanelViewGroupModel *filteredGroup = [[%c(AWELongPressPanelViewGroupModel) alloc] init];
                        filteredGroup.groupType = groupModel.groupType;
                        filteredGroup.groupArr = filteredGroupArr;
                        [modifiedOriginalGroups addObject:filteredGroup];
                    }
                } else {
                    [modifiedOriginalGroups addObject:group];
                }
            }
            originalArray = modifiedOriginalGroups;
        }
    }

    // 检查是否启用了任意长按功能
    BOOL hasAnyFeatureEnabled = NO;

    // 检查各个单独的功能开关
    BOOL enableSaveVideo = DYYYGetBool(@"DYYYLongPressSaveVideo");
    BOOL enableSaveCover = DYYYGetBool(@"DYYYLongPressSaveCover");
    BOOL enableSaveAudio = DYYYGetBool(@"DYYYLongPressSaveAudio");
    BOOL enableSaveCurrentImage = DYYYGetBool(@"DYYYLongPressSaveCurrentImage");
    BOOL enableSaveAllImages = DYYYGetBool(@"DYYYLongPressSaveAllImages");
    BOOL enableCopyText = DYYYGetBool(@"DYYYLongPressCopyText");
    BOOL enableCopyLink = DYYYGetBool(@"DYYYLongPressCopyLink");
    BOOL enableApiDownload = DYYYGetBool(@"DYYYLongPressApiDownload");
    BOOL enableFilterUser = DYYYGetBool(@"DYYYLongPressFilterUser");
    BOOL enableFilterKeyword = DYYYGetBool(@"DYYYLongPressFilterTitle");
    BOOL enableTimerClose = DYYYGetBool(@"DYYYLongPressTimerClose");
    BOOL enableCreateVideo = DYYYGetBool(@"DYYYLongPressCreateVideo");

    // 检查是否有任何功能启用
    hasAnyFeatureEnabled = enableSaveVideo || enableSaveCover || enableSaveAudio || enableSaveCurrentImage || enableSaveAllImages || enableCopyText || enableCopyLink || enableApiDownload ||
                           enableFilterUser || enableFilterKeyword || enableTimerClose || enableCreateVideo;

    if (!hasAnyFeatureEnabled) {
        return originalArray;
    }

    // 创建自定义功能组
    AWELongPressPanelViewGroupModel *newGroupModel = [[%c(AWELongPressPanelViewGroupModel) alloc] init];
    newGroupModel.groupType = 0;
    NSMutableArray *viewModels = [NSMutableArray array];

    BOOL isNewLivePhoto = (self.awemeModel.video && self.awemeModel.animatedImageVideoInfo != nil);

    // 视频下载功能 (非实况照片才显示)
    if (enableSaveVideo && self.awemeModel.awemeType != 68 && !isNewLivePhoto) {
        AWELongPressPanelBaseViewModel *downloadViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        downloadViewModel.awemeModel = self.awemeModel;
        downloadViewModel.actionType = 666;
        downloadViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        downloadViewModel.describeString = @"保存视频";
        downloadViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          AWEVideoModel *videoModel = awemeModel.video;
          AWEMusicModel *musicModel = awemeModel.music;
          NSURL *audioURL = nil;
          if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
              audioURL = [NSURL URLWithString:musicModel.playURL.originURLList.firstObject];
          }

                  // 备用方法：直接使用h264URL，并收集全部候选 URL 自动切换
                  NSMutableArray<NSURL *> *videoURLs = [NSMutableArray array];
                  if (videoModel.h264URL && videoModel.h264URL.originURLList.count > 0) {
                      for (NSString *urlString in videoModel.h264URL.originURLList) {
                          NSURL *url = [NSURL URLWithString:urlString];
                          if (url) {
                              [videoURLs addObject:url];
                          }
                      }
                  }
                  if (videoModel.playURL && videoModel.playURL.originURLList.count > 0) {
                      for (NSString *urlString in videoModel.playURL.originURLList) {
                          NSURL *url = [NSURL URLWithString:urlString];
                          if (url && ![videoURLs containsObject:url]) {
                              [videoURLs addObject:url];
                          }
                      }
                  }

                  if (videoURLs.count > 0) {
                      [DYYYManager downloadMediaFromURLs:videoURLs
                                               mediaType:MediaTypeVideo
                                                   audio:audioURL
                                              completion:^(BOOL success){
                                              }];
                  } else {
                      [DYYYUtils showToast:@"没有找到可用的视频地址"];
                  }
              
          
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:downloadViewModel];
    }

    //  新版实况照片保存
    if (enableSaveVideo && self.awemeModel.awemeType != 68 && isNewLivePhoto) {
        AWELongPressPanelBaseViewModel *livePhotoViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        livePhotoViewModel.awemeModel = self.awemeModel;
        livePhotoViewModel.actionType = 679;
        livePhotoViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        livePhotoViewModel.describeString = @"保存实况";
        livePhotoViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          AWEVideoModel *videoModel = awemeModel.video;

          // 使用封面URL作为图片URL
          NSURL *imageURL = nil;
          if (videoModel.coverURL && videoModel.coverURL.originURLList.count > 0) {
              imageURL = [NSURL URLWithString:videoModel.coverURL.originURLList.firstObject];
          }

          // 视频URL从视频模型获取
          NSURL *videoURL = nil;
          if (videoModel && videoModel.playURL && videoModel.playURL.originURLList.count > 0) {
              videoURL = [NSURL URLWithString:videoModel.playURL.originURLList.firstObject];
          } else if (videoModel && videoModel.h264URL && videoModel.h264URL.originURLList.count > 0) {
              videoURL = [NSURL URLWithString:videoModel.h264URL.originURLList.firstObject];
          }

          // 下载实况照片
          if (imageURL && videoURL) {
              [DYYYManager downloadLivePhoto:imageURL
                                    videoURL:videoURL
                                  completion:^{
                                  }];
          }

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:livePhotoViewModel];
    }

    // 当前图片/实况下载功能
    if (enableSaveCurrentImage && self.awemeModel.awemeType == 68 && self.awemeModel.albumImages.count > 0) {
        AWELongPressPanelBaseViewModel *imageViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        imageViewModel.awemeModel = self.awemeModel;
        imageViewModel.actionType = 669;
        imageViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";

        if (self.awemeModel.albumImages.count == 1) {
            imageViewModel.describeString = @"保存图片";
        } else {
            imageViewModel.describeString = @"保存当前图片";
        }

        AWEImageAlbumImageModel *currimge = self.awemeModel.albumImages[self.awemeModel.currentImageIndex - 1];
        if (currimge.clipVideo != nil || self.awemeModel.isLivePhoto) {
            if (self.awemeModel.albumImages.count == 1) {
                imageViewModel.describeString = @"保存实况";
            } else {
                imageViewModel.describeString = @"保存当前实况";
            }
        }

        imageViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          AWEImageAlbumImageModel *currentImageModel = nil;
          if (awemeModel.currentImageIndex > 0 && awemeModel.currentImageIndex <= awemeModel.albumImages.count) {
              currentImageModel = awemeModel.albumImages[awemeModel.currentImageIndex - 1];
          } else {
              currentImageModel = awemeModel.albumImages.firstObject;
          }
          // 如果是实况的话
          // 查找非.image后缀的URL
          NSURL *downloadURL = nil;
          for (NSString *urlString in currentImageModel.urlList) {
              NSURL *url = [NSURL URLWithString:urlString];
              NSString *pathExtension = [url.path.lowercaseString pathExtension];
              if (![pathExtension isEqualToString:@"image"]) {
                  downloadURL = url;
                  break;
              }
          }

          if (currentImageModel.clipVideo != nil) {
              NSURL *videoURL = [currentImageModel.clipVideo.playURL getDYYYSrcURLDownload];
              [DYYYManager downloadLivePhoto:downloadURL
                                    videoURL:videoURL
                                  completion:^{
                                  }];
          } else if (currentImageModel && currentImageModel.urlList.count > 0) {
              if (downloadURL) {
                  [DYYYManager downloadMedia:downloadURL
                                   mediaType:MediaTypeImage
                                       audio:nil
                                  completion:^(BOOL success) {
                                    if (success) {
                                    } else {
                                        [DYYYUtils showToast:@"图片保存已取消"];
                                    }
                                  }];
              } else {
                  [DYYYUtils showToast:@"没有找到合适格式的图片"];
              }
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:imageViewModel];
    }

    // 保存所有图片/实况功能
    if (enableSaveAllImages && self.awemeModel.awemeType == 68 && self.awemeModel.albumImages.count > 1) {
        AWELongPressPanelBaseViewModel *allImagesViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        allImagesViewModel.awemeModel = self.awemeModel;
        allImagesViewModel.actionType = 670;
        allImagesViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        allImagesViewModel.describeString = @"保存所有图片";
        // 检查是否有实况照片并更改按钮文字
        BOOL hasLivePhoto = NO;
        for (AWEImageAlbumImageModel *imageModel in self.awemeModel.albumImages) {
            if (imageModel.clipVideo != nil) {
                hasLivePhoto = YES;
                break;
            }
        }
        if (hasLivePhoto) {
            allImagesViewModel.describeString = @"保存所有实况";
        }
        allImagesViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          NSMutableArray *imageURLs = [NSMutableArray array];
          NSMutableArray *livePhotos = [NSMutableArray array];

          for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
              if (imageModel.urlList.count > 0) {
                  // 查找非.image后缀的URL
                  NSURL *downloadURL = nil;
                  for (NSString *urlString in imageModel.urlList) {
                      NSURL *url = [NSURL URLWithString:urlString];
                      NSString *pathExtension = [url.path.lowercaseString pathExtension];
                      if (![pathExtension isEqualToString:@"image"]) {
                          downloadURL = url;
                          break;
                      }
                  }

                  if (!downloadURL && imageModel.urlList.count > 0) {
                      downloadURL = [NSURL URLWithString:imageModel.urlList.firstObject];
                  }

                  // 检查是否是实况照片
                  if (imageModel.clipVideo != nil) {
                      NSURL *videoURL = [imageModel.clipVideo.playURL getDYYYSrcURLDownload];
                      [livePhotos addObject:@{@"imageURL" : downloadURL.absoluteString, @"videoURL" : videoURL.absoluteString}];
                  } else {
                      [imageURLs addObject:downloadURL.absoluteString];
                  }
              }
          }

          // 分别处理普通图片和实况照片
          if (livePhotos.count > 0) {
              [DYYYManager downloadAllLivePhotos:livePhotos];
          }

          if (imageURLs.count > 0) {
              [DYYYManager downloadAllImages:imageURLs];
          }

          if (livePhotos.count == 0 && imageURLs.count == 0) {
              [DYYYUtils showToast:@"没有找到合适格式的图片"];
          }

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:allImagesViewModel];
    }

    // 接口保存功能
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYInterfaceDownload"];
    if (enableApiDownload && apiKey.length > 0) {
        AWELongPressPanelBaseViewModel *apiDownload = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        apiDownload.awemeModel = self.awemeModel;
        apiDownload.actionType = 673;
        apiDownload.duxIconName = @"ic_cloudarrowdown_outlined_20";
        apiDownload.describeString = @"接口保存";
        apiDownload.action = ^{
          NSString *shareLink = [self.awemeModel valueForKey:@"shareURL"];
          if (shareLink.length == 0) {
              [DYYYUtils showToast:@"无法获取分享链接"];
              return;
          }
          // 使用封装的方法进行解析下载
          [DYYYManager parseAndDownloadVideoWithShareLink:shareLink apiKey:apiKey];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:apiDownload];
    }

    // 封面下载功能
    if (enableSaveCover && self.awemeModel.awemeType != 68) {
        AWELongPressPanelBaseViewModel *coverViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        coverViewModel.awemeModel = self.awemeModel;
        coverViewModel.actionType = 667;
        coverViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        coverViewModel.describeString = @"保存封面";
        coverViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          AWEVideoModel *videoModel = awemeModel.video;
          NSMutableArray<NSURL *> *coverURLs = [NSMutableArray array];
          if (videoModel && videoModel.coverURL && videoModel.coverURL.originURLList.count > 0) {
              for (NSString *urlString in videoModel.coverURL.originURLList) {
                  NSURL *url = [NSURL URLWithString:urlString];
                  if (url) {
                      [coverURLs addObject:url];
                  }
              }
          }
          if (coverURLs.count > 0) {
              [DYYYManager downloadMediaFromURLs:coverURLs
                                       mediaType:MediaTypeImage
                                           audio:nil
                                      completion:^(BOOL success) {
                                        if (success) {
                                        } else {
                                            [DYYYUtils showToast:@"封面保存已取消"];
                                        }
                                      }];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:coverViewModel];
    }

    // 全屏观看功能（老代码原样保留：永远抖音原生方向、只转一次，不做任何方向干预）
    if (enableCopyText) {
        AWELongPressPanelBaseViewModel *fullScreen = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        fullScreen.awemeModel = self.awemeModel;
        fullScreen.actionType = 671;
        fullScreen.duxIconName = @"ic_fullscreen_outlined";
        fullScreen.describeString = @"全屏观看";
        fullScreen.action = ^{
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:^{
            UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
            UIView *entryView = findLandscapeEntryViewInView(keyWindow);
            simulateTapOnEntryView(entryView);
          }];
        };
        [viewModels addObject:fullScreen];

        // 反向全屏：与「全屏观看」方向相反。做法=动作期间临时收紧允许方向为「仅横屏右」，
        // 让抖音原生入口直接落右边（一次到位，不再"先进左边再翻"）。开关默认开启。
        if (DYYYFSReverseItemEnabled()) {
            AWELongPressPanelBaseViewModel *fullScreenRev = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
            fullScreenRev.awemeModel = self.awemeModel;
            fullScreenRev.actionType = 680;
            fullScreenRev.duxIconName = @"ic_fullscreen_outlined";
            fullScreenRev.describeString = @"反向全屏";
            fullScreenRev.action = ^{
              AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
              [panelManager dismissWithAnimation:YES completion:^{
                UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
                UIView *entryView = findLandscapeEntryViewInView(keyWindow);
                DYYYFSEnterReverse(entryView);
              }];
            };
            [viewModels addObject:fullScreenRev];
        }
    }

    // 音频下载功能
    if (enableSaveAudio) {
        AWELongPressPanelBaseViewModel *audioViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        audioViewModel.awemeModel = self.awemeModel;
        audioViewModel.actionType = 668;
        audioViewModel.duxIconName = @"ic_boxarrowdownhigh_outlined";
        audioViewModel.describeString = @"保存音频";
        audioViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;
          AWEMusicModel *musicModel = awemeModel.music;
          NSMutableArray<NSURL *> *audioURLs = [NSMutableArray array];
          if (musicModel && musicModel.playURL && musicModel.playURL.originURLList.count > 0) {
              for (NSString *urlString in musicModel.playURL.originURLList) {
                  NSURL *url = [NSURL URLWithString:urlString];
                  if (url) {
                      [audioURLs addObject:url];
                  }
              }
          }
          if (audioURLs.count > 0) {
              [DYYYManager downloadMediaFromURLs:audioURLs mediaType:MediaTypeAudio audio:nil completion:nil];
          }
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:audioViewModel];
    }

    // 创建视频功能
    if (enableCreateVideo && self.awemeModel.awemeType == 68) {
        AWELongPressPanelBaseViewModel *createVideoViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        createVideoViewModel.awemeModel = self.awemeModel;
        createVideoViewModel.actionType = 677;
        createVideoViewModel.duxIconName = @"ic_videosearch_outlined_20";
        createVideoViewModel.describeString = @"制作视频";
        createVideoViewModel.action = ^{
          AWEAwemeModel *awemeModel = self.awemeModel;

          // 收集普通图片URL
          NSMutableArray *imageURLs = [NSMutableArray array];
          // 收集实况照片信息（图片URL+视频URL）
          NSMutableArray *livePhotos = [NSMutableArray array];

          // 获取背景音乐URL
          NSString *bgmURL = nil;
          if (awemeModel.music && awemeModel.music.playURL && awemeModel.music.playURL.originURLList.count > 0) {
              bgmURL = awemeModel.music.playURL.originURLList.firstObject;
          }

          // 处理所有图片和实况
          for (AWEImageAlbumImageModel *imageModel in awemeModel.albumImages) {
              if (imageModel.urlList.count > 0) {
                  // 查找非.image后缀的URL
                  NSString *bestURL = nil;
                  for (NSString *urlString in imageModel.urlList) {
                      NSURL *url = [NSURL URLWithString:urlString];
                      NSString *pathExtension = [url.path.lowercaseString pathExtension];
                      if (![pathExtension isEqualToString:@"image"]) {
                          bestURL = urlString;
                          break;
                      }
                  }

                  if (!bestURL && imageModel.urlList.count > 0) {
                      bestURL = imageModel.urlList.firstObject;
                  }

                  // 如果是实况照片，需要收集图片和视频URL
                  if (imageModel.clipVideo != nil) {
                      NSURL *videoURL = [imageModel.clipVideo.playURL getDYYYSrcURLDownload];
                      if (videoURL) {
                          [livePhotos addObject:@{@"imageURL" : bestURL, @"videoURL" : videoURL.absoluteString}];
                      }
                  } else {
                      // 普通图片
                      [imageURLs addObject:bestURL];
                  }
              }
          }

          // 调用视频创建API
          [DYYYManager createVideoFromMedia:imageURLs
              livePhotos:livePhotos
              bgmURL:bgmURL
              progress:^(NSInteger current, NSInteger total, NSString *status) {
              }
              completion:^(BOOL success, NSString *message) {
                if (success) {
                } else {
                    [DYYYUtils showToast:[NSString stringWithFormat:@"视频制作失败: %@", message]];
                }
              }];

          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:createVideoViewModel];
    }

    // 复制分享链接功能
    if (enableCopyLink) {
        AWELongPressPanelBaseViewModel *copyShareLink = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        copyShareLink.awemeModel = self.awemeModel;
        copyShareLink.actionType = 672;
        copyShareLink.duxIconName = @"ic_share_outlined";
        copyShareLink.describeString = @"复制链接";
        copyShareLink.action = ^{
          NSString *shareLink = [self.awemeModel valueForKey:@"shareURL"];
          NSString *cleanedURL = cleanShareURL(shareLink);
          [[UIPasteboard generalPasteboard] setString:cleanedURL];
          [DYYYToast showSuccessToastWithMessage:@"分享链接已复制"];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:copyShareLink];
    }

    // 过滤用户功能
    if (enableFilterUser) {
        AWELongPressPanelBaseViewModel *filterKeywords = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        filterKeywords.awemeModel = self.awemeModel;
        filterKeywords.actionType = 674;
        filterKeywords.duxIconName = @"ic_userban_outlined_20";
        filterKeywords.describeString = @"过滤用户";
        filterKeywords.action = ^{
          AWEUserModel *author = self.awemeModel.author;
          NSString *nickname = author.nickname ?: @"未知用户";
          NSString *shortId = author.shortID ?: @"";
          // 创建当前用户的过滤格式 "nickname-shortid"
          NSString *currentUserFilter = [NSString stringWithFormat:@"%@-%@", nickname, shortId];
          // 获取保存的过滤用户列表
          NSString *savedUsers = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterUsers"] ?: @"";
          NSArray *userArray = [savedUsers length] > 0 ? [savedUsers componentsSeparatedByString:@","] : @[];
          BOOL userExists = NO;
          for (NSString *userInfo in userArray) {
              NSArray *components = [userInfo componentsSeparatedByString:@"-"];
              if (components.count >= 2) {
                  NSString *userId = [components lastObject];
                  if ([userId isEqualToString:shortId] && shortId.length > 0) {
                      userExists = YES;
                      break;
                  }
              }
          }
          NSString *actionButtonText = userExists ? @"取消过滤" : @"添加过滤";
          [DYYYBottomAlertView showAlertWithTitle:@"过滤用户视频"
              message:[NSString stringWithFormat:@"用户: %@ (ID: %@)", nickname, shortId]
              avatarURL:nil
              cancelButtonText:@"管理过滤列表"
              confirmButtonText:actionButtonText
              cancelAction:^{
                DYYYKeywordListView *keywordListView = [[DYYYKeywordListView alloc] initWithTitle:@"过滤用户列表" keywords:userArray];
                keywordListView.onConfirm = ^(NSArray *users) {
                  NSString *userString = [users componentsJoinedByString:@","];
                  [[NSUserDefaults standardUserDefaults] setObject:userString forKey:@"DYYYFilterUsers"];
                  [DYYYUtils showToast:@"过滤用户列表已更新"];
                };
                [keywordListView show];
              }
              closeAction:nil
              confirmAction:^{
                // 添加或移除用户过滤
                NSMutableArray *updatedUsers = [NSMutableArray arrayWithArray:userArray];
                if (userExists) {
                    // 移除用户
                    NSMutableArray *toRemove = [NSMutableArray array];
                    for (NSString *userInfo in updatedUsers) {
                        NSArray *components = [userInfo componentsSeparatedByString:@"-"];
                        if (components.count >= 2) {
                            NSString *userId = [components lastObject];
                            if ([userId isEqualToString:shortId]) {
                                [toRemove addObject:userInfo];
                            }
                        }
                    }
                    [updatedUsers removeObjectsInArray:toRemove];
                    [DYYYUtils showToast:@"已从过滤列表中移除此用户"];
                } else {
                    // 添加用户
                    [updatedUsers addObject:currentUserFilter];
                    [DYYYUtils showToast:@"已添加此用户到过滤列表"];
                }
                // 保存更新后的列表
                NSString *updatedUserString = [updatedUsers componentsJoinedByString:@","];
                [[NSUserDefaults standardUserDefaults] setObject:updatedUserString forKey:@"DYYYFilterUsers"];
              }];
        };
        [viewModels addObject:filterKeywords];
    }

    // 过滤文案功能
    if (enableFilterKeyword) {
        AWELongPressPanelBaseViewModel *filterKeywords = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        filterKeywords.awemeModel = self.awemeModel;
        filterKeywords.actionType = 675;
        filterKeywords.duxIconName = @"ic_funnel_outlined_20";
        filterKeywords.describeString = @"过滤文案";
        filterKeywords.action = ^{
          NSString *descText = [self.awemeModel valueForKey:@"descriptionString"];
          NSString *propName = nil;
          if (self.awemeModel.propGuideV2) {
              propName = self.awemeModel.propGuideV2.propName;
          }
          DYYYFilterSettingsView *filterView = [[DYYYFilterSettingsView alloc] initWithTitle:@"过滤关键词调整" text:descText propName:propName];
          filterView.onConfirm = ^(NSString *selectedText) {
            if (selectedText.length > 0) {
                NSString *currentKeywords = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterKeywords"] ?: @"";
                NSString *newKeywords;
                if (currentKeywords.length > 0) {
                    newKeywords = [NSString stringWithFormat:@"%@,%@", currentKeywords, selectedText];
                } else {
                    newKeywords = selectedText;
                }
                [[NSUserDefaults standardUserDefaults] setObject:newKeywords forKey:@"DYYYFilterKeywords"];
                [DYYYUtils showToast:[NSString stringWithFormat:@"已添加过滤词: %@", selectedText]];
            }
          };
          // 设置过滤关键词按钮回调
          filterView.onKeywordFilterTap = ^{
            // 获取保存的关键词
            NSString *savedKeywords = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYFilterKeywords"] ?: @"";
            NSArray *keywordArray = [savedKeywords length] > 0 ? [savedKeywords componentsSeparatedByString:@","] : @[];
            // 创建并显示关键词列表视图
            DYYYKeywordListView *keywordListView = [[DYYYKeywordListView alloc] initWithTitle:@"设置过滤关键词" keywords:keywordArray];
            // 设置确认回调
            keywordListView.onConfirm = ^(NSArray *keywords) {
              // 将关键词数组转换为逗号分隔的字符串
              NSString *keywordString = [keywords componentsJoinedByString:@","];
              // 保存到用户默认设置
              [[NSUserDefaults standardUserDefaults] setObject:keywordString forKey:@"DYYYFilterKeywords"];
              // 显示提示
              [DYYYUtils showToast:@"过滤关键词已更新"];
            };
            // 显示关键词列表视图
            [keywordListView show];
          };
          [filterView show];
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
        };
        [viewModels addObject:filterKeywords];
    }

    if (enableTimerClose) {
        AWELongPressPanelBaseViewModel *timerCloseViewModel = [[%c(AWELongPressPanelBaseViewModel) alloc] init];
        timerCloseViewModel.awemeModel = self.awemeModel;
        timerCloseViewModel.actionType = 676;
        timerCloseViewModel.duxIconName = @"ic_c_alarm_outlined";
        // 检查是否已有定时任务在运行
        NSNumber *shutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
        BOOL hasActiveTimer = shutdownTime != nil && [shutdownTime doubleValue] > [[NSDate date] timeIntervalSince1970];
        timerCloseViewModel.describeString = hasActiveTimer ? @"取消定时" : @"定时关闭";
        timerCloseViewModel.action = ^{
          AWELongPressPanelManager *panelManager = [%c(AWELongPressPanelManager) shareInstance];
          [panelManager dismissWithAnimation:YES completion:nil];
          NSNumber *shutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
          BOOL hasActiveTimer = shutdownTime != nil && [shutdownTime doubleValue] > [[NSDate date] timeIntervalSince1970];
          if (hasActiveTimer) {
              [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"DYYYTimerShutdownTime"];
              DYYYStopTimerCloseCheck();
              [DYYYUtils showToast:@"已取消定时关闭任务"];
              return;
          }
          // 读取上次设置的时间
          NSInteger defaultMinutes = [[NSUserDefaults standardUserDefaults] integerForKey:@"DYYYTimerCloseMinutes"];
          if (defaultMinutes <= 0) {
              defaultMinutes = 5;
          }
          NSString *defaultText = [NSString stringWithFormat:@"%ld", (long)defaultMinutes];
          DYYYCustomInputView *inputView = [[DYYYCustomInputView alloc] initWithTitle:@"设置定时关闭时间" defaultText:defaultText placeholder:@"请输入关闭时间(单位:分钟)"];
          inputView.onConfirm = ^(NSString *inputText) {
            NSInteger minutes = [inputText integerValue];
            if (minutes <= 0) {
                minutes = 5;
            }
            // 保存用户设置的时间以供下次使用
            [[NSUserDefaults standardUserDefaults] setInteger:minutes forKey:@"DYYYTimerCloseMinutes"];
            NSInteger seconds = minutes * 60;
            NSTimeInterval shutdownTimeValue = [[NSDate date] timeIntervalSince1970] + seconds;
            [[NSUserDefaults standardUserDefaults] setObject:@(shutdownTimeValue) forKey:@"DYYYTimerShutdownTime"];
            [DYYYUtils showToast:[NSString stringWithFormat:@"抖音将在%ld分钟后关闭...", (long)minutes]];
            DYYYStartTimerCloseCheck();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
              NSNumber *currentShutdownTime = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYTimerShutdownTime"];
              if (currentShutdownTime != nil && [currentShutdownTime doubleValue] <= [[NSDate date] timeIntervalSince1970]) {
                  DYYYPerformTimerClose();
              }
            });
          };
          [inputView show];
        };
        [viewModels addObject:timerCloseViewModel];
    }

    newGroupModel.groupArr = viewModels;

    // 返回自定义组+原始组的结果
    if (originalArray.count > 0) {
        NSMutableArray *resultArray = [originalArray mutableCopy];
        [resultArray insertObject:newGroupModel atIndex:0];
        return [resultArray copy];
    } else {
        return @[ newGroupModel ];
    }
}
%end

// 隐藏评论分享功能

%hook AWEIMCommentShareUserHorizontalCollectionViewCell

- (void)layoutSubviews {
    %orig;

    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentShareToFriends"]) {
        self.hidden = YES;
    } else {
        self.hidden = NO;
    }
}

%end

%hook AWEIMCommentShareUserHorizontalSectionController

- (CGSize)sizeForItemAtIndex:(NSInteger)index model:(id)model collectionViewSize:(CGSize)size {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentShareToFriends"]) {
        return CGSizeZero;
    }
    return %orig;
}

- (void)configCell:(id)cell index:(NSInteger)index model:(id)model {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentShareToFriends"]) {
        return;
    }
    %orig;
}

%end

%ctor {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYUserAgreementAccepted"]) {
        %init;
    }
}

%group DYYYFilterSetterGroup

%hook HOOK_TARGET_OWNER_CLASS

- (void)setModelsArray:(id)arg1 {
    if (![arg1 isKindOfClass:[NSArray class]]) {
        %orig(arg1);
        return;
    }

    NSArray *inputArray = (NSArray *)arg1;
    NSMutableArray *filteredArray = nil;

    for (id item in inputArray) {
        NSString *className = NSStringFromClass([item class]);

        BOOL shouldFilter = ([className isEqualToString:@"AWECommentIMSwiftImpl.CommentLongPressPanelForwardElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressDaily"]) ||

                            ([className isEqualToString:@"AWECommentLongPressPanelSwiftImpl.CommentLongPressPanelCopyElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressCopy"]) ||

                            ([className isEqualToString:@"AWECommentLongPressPanelSwiftImpl.CommentLongPressPanelSaveImageElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressSaveImage"]) ||

                            ([className isEqualToString:@"AWECommentLongPressPanelSwiftImpl.CommentLongPressPanelReportElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressReport"]) ||

                            ([className isEqualToString:@"AWECommentStudioSwiftImpl.CommentLongPressPanelVideoReplyElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressVideoReply"]) ||

                            ([className isEqualToString:@"AWECommentSearchSwiftImpl.CommentLongPressPanelPictureSearchElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressPictureSearch"]) ||

                            ([className isEqualToString:@"AWECommentSearchSwiftImpl.CommentLongPressPanelSearchElement"] &&
                             [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYHideCommentLongPressSearch"]);

        if (shouldFilter) {
            if (!filteredArray) {
                filteredArray = [NSMutableArray arrayWithCapacity:inputArray.count];
                for (id keepItem in inputArray) {
                    if (keepItem == item)
                        break;
                    [filteredArray addObject:keepItem];
                }
            }
            continue;
        }

        if (filteredArray) {
            [filteredArray addObject:item];
        }
    }

    if (filteredArray) {
        %orig([filteredArray copy]);
    } else {
        %orig(arg1);
    }
}

%end
%end

%ctor {
    Class ownerClass = objc_getClass("AWECommentLongPressPanelSwiftImpl.CommentLongPressPanelNormalSectionViewModel");
    if (ownerClass) {
        %init(DYYYFilterSetterGroup, HOOK_TARGET_OWNER_CLASS = ownerClass);
    }
}
