// S3TextKeyboardFix 1.6.8 —— 让「截图标记」的文字标注面板能弹出系统原生键盘
//
// ─────────────────────────────────────────────────────────────────────────
// 一、结论先行：不要去动窗口层级
//
// 现场数据（1.6.2 / 1.6.3 两个包在真机上的表现）：
//
//   1.6.2：自绘键盘显示出来了，**原生键盘同时也弹出来了**（只是自绘键盘收不掉）。
//          biaoji 的标注窗口此时还是 UIWindowLevelStatusBar + 1 = 1001。
//   1.6.3：删掉自绘键盘，改成把标注窗口 setWindowLevel:10。
//          直接装 1.6.3 → 键盘不出来。
//
// 1.6.2 这条事实是决定性的：**标注窗口在 1001 的时候，原生键盘照样能显示。**
// 也就是说「层级 1001 把键盘压住了」这个假设是错的 —— 真正承载键盘的窗口层级远高于 1001，
// 标注窗口的层级对它没有影响。所以 1.6.3 花大力气把窗口压到 10，不但没用，还很可能是**致病的**：
//
//   运行中改 UIWindow.windowLevel 会让窗口在窗口列表里被重新排序/重建，
//   第一响应者可能被顺手丢掉（UIKit 上有名的坑），于是「刚 become 成功、马上又没了」，
//   表现出来就是——有光标，但键盘不出现。
//
// 所以 1.6.7 的主路径**完全不碰 windowLevel**：
//   只做「等 VC 进窗口 → 标注窗口 makeKeyWindow → 输入框 becomeFirstResponder」，
//   失败就重试，直到系统真的发出 UIKeyboardDidShow。
//   层级调整降级为**最后手段**：只有等到重试都打完、键盘仍然没出现时才做一次，
//   键盘一旦出现就不再动它，面板消失时还原。
//
// 二、输入框的情况（反汇编 biaoji.dylib 确认）
//   - 文字面板输入框是标准 UITextField，tag = 0xC8 = 200，**没有自定义 inputView**；
//   - 面板容器 tag = 999，在屏幕底部，键盘弹出正好会盖住「取消 / 确认」
//     → 需要对容器做 transform 上移，收起时复位；
//   - biaoji 自己的 -ensureTextKeyboard 只做两件事：
//         if (self.view.window && !self.view.window.isKeyWindow) [self.view.window makeKeyWindow];
//         dispatch_async(main, ^{ tf = [self.view viewWithTag:200]; [tf becomeFirstResponder]; });
//     关键缺陷：**只在 dispatch_async 里试一次，窗口/视图还没就位就直接失败**，没有重试。
//     1.6.7 补的就是这个：同样的事，但重复做、每次都验证键盘是否真的出现。
//
// 三、自证身份（RootHide 下排查「装了新包却在跑旧代码」）
//   RootHide 的 /usr/lib/TweakInject 与 Library/MobileSubstrate/DynamicLibraries 两边
//   都可能有同名 dylib，另有 *.roothidepatch 补丁缓存。所以启动时把
//   「本 dylib 的真实加载路径 + 版本 + 进程内所有相关镜像」写进日志，一看便知。
// ─────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <stdarg.h>

#define kLogPath @"/var/mobile/Documents/S3TextKeyboardFix.log"

static NSString *const kS3Ver = @"1.6.8";

// 最后手段才会用到的层级。正常路径完全不碰 windowLevel。
static const CGFloat kAnnoFallbackLevel = 1.0;

// ───────────────────────────── 日志 ─────────────────────────────
static void S3Log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[S3TextFix %@] %@\n", kS3Ver, s];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kLogPath]) {
        [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ───────────────────── 自证身份：本 dylib 到底是谁 ─────────────────────
static NSString *S3SelfPath(void) {
    Dl_info info;
    const char *p = "?";
    // 函数指针 → uintptr_t → void*：避免 C/C++ 下函数指针直接转对象指针的问题
    if (dladdr((void *)(uintptr_t)&S3Log, &info) && info.dli_fname) p = info.dli_fname;
    return [NSString stringWithUTF8String:p];
}

static NSString *S3LoadedImages(void) {
    NSMutableString *s = [NSMutableString string];
    uint32_t n = _dyld_image_count();
    int hits = 0;
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *f = [NSString stringWithUTF8String:nm];
        if (!f) continue;
        if ([f containsString:@"S3TextKeyboardFix"] || [f containsString:@"biaoji"]) {
            [s appendFormat:@"\n      %@", f];
            hits++;
        }
    }
    if (hits == 0) return @"（一个都没加载？）";
    return s;
}

// ───────────────────────────── 状态 ─────────────────────────────
static __weak UIWindow *gAnnoWindow = nil;
static __weak UIViewController *gVC = nil;
static CGFloat gAnnoSavedLevel = 0;
static BOOL gLevelChanged = NO;      // 只有走过最后手段才为 YES
static BOOL gKbSeen = NO;
static NSMutableArray *gObservers = nil;

// ───────────────────────────── 工具 ─────────────────────────────
static NSArray *S3AllWindows(void) {
    NSMutableArray *all = [NSMutableArray array];
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (![all containsObject:w]) [all addObject:w];
        }
    }
    id appw = [[UIApplication sharedApplication] valueForKey:@"windows"];
    if ([appw isKindOfClass:[NSArray class]]) {
        for (UIWindow *w in (NSArray *)appw) {
            if (![all containsObject:w]) [all addObject:w];
        }
    }
    return all;
}

static NSString *S3WindowDump(void) {
    NSMutableString *s = [NSMutableString string];
    for (UIWindow *w in S3AllWindows()) {
        [s appendFormat:@"\n      %@ level=%.0f hidden=%d key=%d",
         NSStringFromClass([w class]), w.windowLevel, (int)w.isHidden, (int)w.isKeyWindow];
    }
    return s;
}

static UIWindow *S3WindowForView(UIView *v) {
    if (!v) return nil;
    if (v.window) return v.window;
    for (UIWindow *w in S3AllWindows()) {
        if ([v isDescendantOfView:w]) return w;
    }
    return nil;
}

static UIView *S3FindEditable(UIView *v, int depth) {
    if (!v || depth > 14) return nil;
    if ([v isKindOfClass:[UITextField class]] || [v isKindOfClass:[UITextView class]]) return v;
    if (v.hidden) return nil;
    for (UIView *sub in v.subviews) {
        UIView *r = S3FindEditable(sub, depth + 1);
        if (r) return r;
    }
    return nil;
}

static UIResponder *S3InputIn(UIViewController *vc) {
    UIView *v = [vc.view viewWithTag:200];
    if ([v isKindOfClass:[UITextField class]] || [v isKindOfClass:[UITextView class]]) return (UIResponder *)v;
    return (UIResponder *)S3FindEditable(vc.view, 0);
}

// 只有「重试全打完、键盘还是没出现」时才调用一次
static void S3FallbackLowerLevel(UIWindow *anno) {
    if (!anno || gLevelChanged) return;
    gAnnoSavedLevel = anno.windowLevel;
    gAnnoWindow = anno;
    anno.windowLevel = kAnnoFallbackLevel;
    gLevelChanged = YES;
    S3Log(@"最后手段：标注窗口层级 %.0f -> %.0f",
          gAnnoSavedLevel, kAnnoFallbackLevel);
    S3Log(@"当前窗口：%@", S3WindowDump());
}

static void S3Restore(void) {
    // 面板随键盘上移过的话，先复位
    if (gVC) {
        UIView *panel = [gVC.view viewWithTag:999];
        if (panel && !CGAffineTransformIsIdentity(panel.transform)) {
            panel.transform = CGAffineTransformIdentity;
            S3Log(@"还原：文字面板位置复位");
        }
    }
    if (gLevelChanged) {
        UIWindow *w = gAnnoWindow;
        if (w) {
            S3Log(@"还原：标注窗口层级 %.0f -> %.0f", w.windowLevel, gAnnoSavedLevel);
            w.windowLevel = gAnnoSavedLevel;
        } else {
            S3Log(@"还原：标注窗口已不存在");
        }
    }
    gLevelChanged = NO;
    gAnnoSavedLevel = 0;
    gAnnoWindow = nil;
    gVC = nil;
    gKbSeen = NO;
}

// ───────────────────── 核心：一次尝试 ─────────────────────
static void S3Attempt(UIViewController *vc, int attempt) {
    if (!vc) return;

    UIWindow *anno = S3WindowForView(vc.view);
    if (!anno) {
        S3Log(@"第 %d 次：还找不到 vc 所在窗口 %@", attempt, vc);
        if (attempt < 6) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(0.05 * (1 << attempt) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ S3Attempt(vc, attempt + 1); });
        }
        return;
    }

    if (!anno.isKeyWindow) {
        [anno makeKeyWindow];
        S3Log(@"第 %d 次：标注窗口 makeKeyWindow（level=%.0f）", attempt, anno.windowLevel);
    }

    UIResponder *tf = S3InputIn(vc);
    if (!tf) {
        S3Log(@"第 %d 次：面板里没找到输入框", attempt);
        return;
    }

    if (tf.isFirstResponder) {
        S3Log(@"第 %d 次：输入框已是第一响应者（键盘出现过=%d）", attempt, (int)gKbSeen);
    } else {
        BOOL ok = [tf becomeFirstResponder];
        S3Log(@"第 %d 次：becomeFirstResponder -> %d", attempt, (int)ok);
        if (!ok) {
            // 常见的坑：先 resign 再 reloadInputViews 再 become 能救回来
            [tf resignFirstResponder];
            [tf reloadInputViews];
            ok = [tf becomeFirstResponder];
            S3Log(@"第 %d 次：resign/reload 后重试 -> %d", attempt, (int)ok);
        }
    }

    // 键盘没出现就继续等；gKbSeen 由 UIKeyboardWill/DidShow 通知置位
    if (!gKbSeen && attempt < 8) {
        int64_t ns = (int64_t)(0.15 * (1 << (attempt > 4 ? 4 : attempt)) * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ns), dispatch_get_main_queue(), ^{
            S3Attempt(vc, attempt + 1);
        });
        return;
    }

    // 重试打完还没见到键盘：才动用最后手段（改层级），然后再试几次
    if (!gKbSeen && attempt == 8) {
        S3FallbackLowerLevel(anno);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ S3Attempt(vc, 9); });
    }
}

// 面板在屏幕底部，「取消/确认」就在最下面 —— 键盘弹出来会正好把它俩盖住。
// 这里只对面板做 transform（不影响 biaoji 自己的布局/autoresizing），键盘收起即复位。
static void S3ShiftPanel(NSNotification *n, BOOL up) {
    if (!gVC) return;
    UIView *panel = [gVC.view viewWithTag:999];
    if (!panel) return;
    CGFloat h = 0;
    if (up) {
        NSValue *v = n.userInfo[UIKeyboardFrameEndUserInfoKey];
        if ([v isKindOfClass:[NSValue class]]) h = CGRectGetHeight([v CGRectValue]);
        if (h <= 0 || h > 600) h = 336.0;
        if (!CGAffineTransformIsIdentity(panel.transform)) return;   // 已经抬过了
    }
    [UIView animateWithDuration:0.25 animations:^{
        panel.transform = up ? CGAffineTransformMakeTranslation(0, -h)
                             : CGAffineTransformIdentity;
    }];
    S3Log(@"文字面板%@ %.0f", up ? @"随键盘上移" : @"复位", h);
}

// ───────────────────── hook 安装 ─────────────────────
static void S3InstallHook(void) {
    static int tries = 0;
    Class cls = NSClassFromString(@"S3TextEditViewController");
    if (!cls) {
        if (tries % 10 == 0) S3Log(@"S3TextEditViewController 还没出现（重试 %d）", tries);
        if (++tries < 300) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ S3InstallHook(); });
        }
        return;
    }

    SEL selEnsure = NSSelectorFromString(@"ensureTextKeyboard");
    Method mEnsure = class_getInstanceMethod(cls, selEnsure);
    if (mEnsure) {
        IMP origEnsure = method_getImplementation(mEnsure);
        IMP newImp = imp_implementationWithBlock(^(UIViewController *self) {
            UIWindow *anno = S3WindowForView(self.view);
            if (anno && !anno.isKeyWindow) [anno makeKeyWindow];
            if (origEnsure) ((void (*)(id, SEL))origEnsure)(self, selEnsure);
            gVC = self;
            dispatch_async(dispatch_get_main_queue(), ^{ S3Attempt(self, 0); });
        });
        method_setImplementation(mEnsure, newImp);
        S3Log(@"已 hook ensureTextKeyboard");
    } else {
        S3Log(@"没有 ensureTextKeyboard 方法");
    }

    Method mDis = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidDisappear:"));
    if (mDis) {
        IMP origDis = method_getImplementation(mDis);
        IMP newDis = imp_implementationWithBlock(^(UIViewController *self, BOOL animated) {
            if (origDis) {
                ((void (*)(id, SEL, BOOL))origDis)(self, @selector(viewDidDisappear:), animated);
            }
            S3Log(@"viewDidDisappear -> 还原");
            S3Restore();
        });
        method_setImplementation(mDis, newDis);
        S3Log(@"已 hook viewDidDisappear:");
    }

    S3Log(@"hook 安装完成 on S3TextEditViewController（本份来自 %@）", S3SelfPath());
}

__attribute__((constructor)) static void S3Init(void) {
    S3Log(@"===== v%@ 已加载 pid=%d =====", kS3Ver, getpid());
    S3Log(@"自身路径: %@", S3SelfPath());
    S3Log(@"进程内相关镜像: %@", S3LoadedImages());
    dispatch_async(dispatch_get_main_queue(), ^{
        S3InstallHook();

        gObservers = [NSMutableArray array];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        // 注意：block 版通知观察者必须自己持有返回的 token，否则会被立即释放、回调不触发
        [gObservers addObject:[nc addObserverForName:UIKeyboardWillShowNotification
                                              object:nil
                                               queue:[NSOperationQueue mainQueue]
                                          usingBlock:^(NSNotification *n) {
            gKbSeen = YES;
            S3Log(@"UIKeyboardWillShow 到了 frame=%@", n.userInfo[UIKeyboardFrameEndUserInfoKey]);
            S3ShiftPanel(n, YES);
        }]];
        [gObservers addObject:[nc addObserverForName:UIKeyboardDidShowNotification
                                              object:nil
                                               queue:[NSOperationQueue mainQueue]
                                          usingBlock:^(NSNotification *n) {
            gKbSeen = YES;
            S3Log(@"UIKeyboardDidShow 到了：键盘确认出现");
            S3ShiftPanel(n, YES);
        }]];
        [gObservers addObject:[nc addObserverForName:UIKeyboardDidHideNotification
                                              object:nil
                                               queue:[NSOperationQueue mainQueue]
                                          usingBlock:^(NSNotification *n) {
            S3Log(@"UIKeyboardDidHide");
            S3ShiftPanel(n, NO);
        }]];

        // 兜底：VC 被直接 dealloc 时还原
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            if (!gVC && !gLevelChanged) return;
            UIViewController *vc = gVC;
            if (!vc || vc.isBeingDismissed || !vc.isViewLoaded || !vc.view.window) {
                S3Log(@"清理：文字面板已消失");
                S3Restore();
            }
        }];
    });
}
