// S3TextKeyboardFix 1.6.7 —— 让「截图标记」的文字标注面板能弹出系统原生键盘
//
// ─────────────────────────────────────────────────────────────────────────
// 一、真正的病因（反汇编 biaoji.dylib 与 1.6.2 / 1.6.3 两个 fix dylib 得出）
//
// biaoji.dylib（1.6.2 与 1.6.3 两版字节完全相同）里创建标注窗口：
//
//     w = [[UIWindow alloc] initWithWindowScene:scene];
//     w.windowLevel = UIWindowLevelStatusBar + 1;      // = 1001   ← 罪魁
//     [w makeKeyWindow];
//
// 文字面板的输入框是标准 UITextField（tag = 200）、没有自定义 inputView，
// 所以「光标在闪但没有键盘」只可能是一个原因：键盘弹出来了，但被标注窗口盖住。
// 系统真正承载键盘的窗口是 UITextEffectsWindow，它的 windowLevel == 10。
//
//   1.6.2（自绘键盘版）：另开一个 UIWindow（同一个 windowScene），
//        windowLevel = 标注窗口.level + 2 = 1003，把自绘键盘塞进去
//        → 1003 > 10，看得见 → 能用（代价是要自绘键盘）。
//
//   1.6.3（原生键盘版）：把标注窗口 setWindowLevel:10。
//        反汇编确认就是 `fmov d0, #10.0` → setWindowLevel:。
//        **10 与 UITextEffectsWindow 撞层**。同层时 z 序按创建顺序决定，
//        而 UITextEffectsWindow 早就存在、标注窗口是新建的 → 标注窗口仍在上面
//        → 键盘继续被盖住 → 依旧是「有光标、没键盘」。
//
// 所以 1.6.3 / 1.6.4 / 1.6.5 都无效，根因是那个 10 定错了。
//
// 二、1.6.6 的修法
//   [1] 标注窗口层级压到 1.0（严格小于 10），而且必须在任何 becomeFirstResponder 之前；
//   [2] 不依赖「按类名枚举键盘窗口」—— iOS 16 起 UIRemoteKeyboardWindow 已不在
//       UIApplication.windows 里。改为：只把 level <= 1 的文字效果类窗口抬到 2，找不到不动手；
//   [3] 顺序修正：先压层级 → 再调原实现 → 再异步校验重试；
//   [4] 用 UIKeyboardWillShow / DidShow 通知反过来确认键盘到底有没有出现，
//       没出现就继续重试（resign + reloadInputViews + become）；
//   [5] 全程落盘日志 + 每次打印窗口层级快照；万一还不行，日志能直接定位；
//   [6] 面板消失 / VC 被销毁 → 还原标注窗口层级。
//   [7] 1.6.7 追加「自证身份」：日志开头打印本 dylib 的真实加载路径 + 版本，
//       并列出进程内所有 S3TextKeyboardFix / biaoji 相关镜像。
//       原因：RootHide 下 /usr/lib/TweakInject 与 Library/MobileSubstrate/DynamicLibraries
//       两边都可能有同名 dylib，且有 *.roothidepatch 补丁缓存，
//       「装了新包但跑的是旧代码」这种情况只能靠日志自证。
//
//   只用运行时按类名找 S3TextEditViewController，与 dylib 加载顺序无关。
// ─────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <stdarg.h>

#define kLogPath @"/var/mobile/Documents/S3TextKeyboardFix.log"

// 版本号 + 自证身份：RootHide 会缓存 dylib 的补丁副本（*.roothidepatch），
// 而且 /usr/lib/TweakInject 与 /Library/MobileSubstrate/DynamicLibraries 两边
// 都可能存在同名文件。所以启动时必须把「到底加载了哪一份、哪个版本」写进日志，
// 否则「装了新包但跑的是旧代码」这种情况根本看不出来。
static NSString *const kS3Ver = @"1.6.7";

// 必须严格小于 UITextEffectsWindow 的 10.0。
// 1.0 高于普通窗口(0)，保证标注 UI 仍盖在桌面/图标之上。
static const CGFloat kAnnoLowLevel = 1.0;
static const CGFloat kKbMinLevel  = 2.0;

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

// ───────────────────────── 自证身份（排查"装了不生效"用） ─────────────────────────
// 打印本 dylib 自己的真实加载路径，以及进程里所有和本插件相关的已加载镜像。
// 若这里出现两份不同路径的 S3TextKeyboardFix.dylib，说明被注入了两次
// （RootHide 下 /usr/lib/TweakInject 与 Library/MobileSubstrate/DynamicLibraries 都有副本）。
static NSString *S3SelfPath(void) {
    Dl_info info;
    const char *p = "?";
    // 函数指针 → uintptr_t → void*，避免 C/C++ 下函数指针直接转对象指针的问题
    if (dladdr((void *)(uintptr_t)&S3Log, &info) && info.dli_fname) p = info.dli_fname;
    return [NSString stringWithUTF8String:p];
}

static NSString *S3LoadedImages(void) {
    NSMutableString *s = [NSMutableString string];
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *f = [NSString stringWithUTF8String:nm];
        if (!f) continue;
        if ([f containsString:@"S3TextKeyboardFix"] || [f containsString:@"biaoji"]) {
            [s appendFormat:@"\n      %@", f];
        }
    }
    if (s.length == 0) return @"（一个都没加载？）";
    return s;
}

// ───────────────────────────── 状态 ─────────────────────────────
static __weak UIWindow *gAnnoWindow = nil;
static __weak UIViewController *gVC = nil;
static CGFloat gAnnoSavedLevel = 0;
static BOOL gAnnoSaved = NO;
static BOOL gKbSeen = NO;
static NSMutableArray *gRaised = nil;
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
    // iOS 16 起这条拿不到键盘窗口，但拿得到应用自己的窗口，做兜底
    id appw = [[UIApplication sharedApplication] valueForKey:@"windows"];
    if ([appw isKindOfClass:[NSArray class]]) {
        for (UIWindow *w in (NSArray *)appw) {
            if (![all containsObject:w]) [all addObject:w];
        }
    }
    // 最可靠的一条：文字效果窗口（系统键盘真正所在）
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    Class tew = NSClassFromString(@"UITextEffectsWindow");
    if (tew && [tew respondsToSelector:@selector(sharedTextEffectsWindow)]) {
        id w = [(id)tew performSelector:@selector(sharedTextEffectsWindow)];
        if (w && ![all containsObject:w]) [all addObject:w];
    }
#pragma clang diagnostic pop
    return all;
}

static BOOL S3IsKeyboardish(UIWindow *w) {
    NSString *n = NSStringFromClass([w class]);
    return [n containsString:@"TextEffects"] || [n containsString:@"Keyboard"] ||
           [n containsString:@"InputWindow"];
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

// 压标注窗口层级 + 键盘类窗口兜底抬升（幂等）
static void S3OrderWindows(UIWindow *anno, NSString *why) {
    if (!anno) return;

    if (!gAnnoSaved) {
        gAnnoSaved = YES;
        gAnnoSavedLevel = anno.windowLevel;
        gAnnoWindow = anno;
        S3Log(@"[%@] 记录标注窗口原层级 %.0f，压到 %.0f", why, gAnnoSavedLevel, kAnnoLowLevel);
    }
    if (anno.windowLevel != kAnnoLowLevel) {
        CGFloat old = anno.windowLevel;
        anno.windowLevel = kAnnoLowLevel;
        S3Log(@"[%@] 标注窗口层级 %.0f -> %.0f", why, old, kAnnoLowLevel);
    }

    if (!gRaised) gRaised = [NSMutableArray array];
    for (UIWindow *w in S3AllWindows()) {
        if (w == anno || !S3IsKeyboardish(w)) continue;
        if (w.windowLevel <= kAnnoLowLevel) {
            CGFloat old = w.windowLevel;
            [gRaised addObject:@[ [NSValue valueWithNonretainedObject:w], @(old) ]];
            w.windowLevel = kKbMinLevel;
            S3Log(@"[%@] 抬升 %@ 层级 %.0f -> %.0f",
                  why, NSStringFromClass([w class]), old, kKbMinLevel);
        }
        if (w.isHidden) {
            w.hidden = NO;
            S3Log(@"[%@] 取消隐藏 %@", why, NSStringFromClass([w class]));
        }
    }
    S3Log(@"[%@] 层级处理完毕，当前窗口：%@", why, S3WindowDump());
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
    if (gAnnoSaved) {
        UIWindow *w = gAnnoWindow;
        if (w) {
            S3Log(@"还原：标注窗口层级 %.0f -> %.0f", w.windowLevel, gAnnoSavedLevel);
            w.windowLevel = gAnnoSavedLevel;
        } else {
            S3Log(@"还原：标注窗口已不存在");
        }
    }
    for (NSArray *pair in gRaised) {
        UIWindow *w = [pair[0] nonretainedObjectValue];
        CGFloat old = [pair[1] doubleValue];
        if (w) {
            S3Log(@"还原：%@ 层级 %.0f -> %.0f",
                  NSStringFromClass([w class]), w.windowLevel, old);
            w.windowLevel = old;
        }
    }
    [gRaised removeAllObjects];
    gAnnoSaved = NO;
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
        S3Log(@"第 %d 次：标注窗口 makeKeyWindow", attempt);
    }

    NSString *why = [NSString stringWithFormat:@"第 %d 次", attempt];
    S3OrderWindows(anno, why);

    UITextField *tf = (UITextField *)[vc.view viewWithTag:200];
    if (![tf isKindOfClass:[UITextField class]]) tf = (UITextField *)S3FindEditable(vc.view, 0);

    if (!tf) {
        S3Log(@"第 %d 次：面板里没找到输入框", attempt);
        return;
    }

    if (tf.isFirstResponder) {
        S3Log(@"第 %d 次：输入框已是第一响应者（键盘是否出现过=%d）", attempt, (int)gKbSeen);
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

    // 键盘没出现就继续等；用通知回调置 gKbSeen，比猜时间可靠
    if (!gKbSeen && attempt < 8) {
        int64_t ns = (int64_t)(0.15 * (1 << (attempt > 4 ? 4 : attempt)) * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, ns), dispatch_get_main_queue(), ^{
            S3Attempt(vc, attempt + 1);
        });
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
    }
    if (up && CGAffineTransformIsIdentity(panel.transform) == NO) return;
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
            // [3] 先压层级，再交给原实现去 becomeFirstResponder
            UIWindow *anno = S3WindowForView(self.view);
            if (anno) S3OrderWindows(anno, @"调原实现前");
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
            S3Log(@"viewDidDisappear -> 还原层级");
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
            if (gAnnoWindow) S3OrderWindows(gAnnoWindow, @"键盘将显示");
            S3ShiftPanel(n, YES);
        }]];
        [gObservers addObject:[nc addObserverForName:UIKeyboardDidShowNotification
                                              object:nil
                                               queue:[NSOperationQueue mainQueue]
                                          usingBlock:^(NSNotification *n) {
            gKbSeen = YES;
            S3Log(@"UIKeyboardDidShow 到了：键盘确认可见");
            if (gAnnoWindow) S3OrderWindows(gAnnoWindow, @"键盘已显示");
            S3ShiftPanel(n, YES);
        }]];
        [gObservers addObject:[nc addObserverForName:UIKeyboardDidHideNotification
                                              object:nil
                                               queue:[NSOperationQueue mainQueue]
                                          usingBlock:^(NSNotification *n) {
            S3Log(@"UIKeyboardDidHide");
            S3ShiftPanel(n, NO);
        }]];

        // 兜底：VC 被直接 dealloc 时还原层级
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            if (!gAnnoSaved) return;
            UIViewController *vc = gVC;
            if (!vc || vc.isBeingDismissed || !vc.isViewLoaded || !vc.view.window) {
                S3Log(@"清理：文字面板已消失，还原层级");
                S3Restore();
            }
        }];
    });
}
