// S3TextKeyboardFix 1.7.1 —— 发布版
//
// 修复「截图标记」文字标注时系统键盘弹不出来（或弹出来被标注窗口压住看不见）的问题。
//
// ── 病因（1.6.9 的真机实测得出）───────────────────────────────────────────
//   打开文字面板时：输入框已经是第一响应者（fr=1），但系统从头到尾没发过一条
//   键盘通知（UIKeyboardWillShow 都收不到），往同一个窗口里插一个干净的探针输入框
//   抢到焦点后同样弹不出键盘。
//   → 说明不是「键盘起来了被 lv=1001 的标注窗口盖住」，而是**这个 UIWindow
//     本身拿不到系统键盘**。iOS 13+ 上这种窗口只有一个已知成因：
//     承载它的 UIWindowScene 不对（场景缺失或挂错场景）。
//
// ── 处置（本版实际做的）──────────────────────────────────────────────────
//   第 0 步  体检并纠正标注窗口的 windowScene：缺失就补挂到能承载键盘的场景；
//            若「另一个场景」里还有窗口在当 key window，说明挂错了场景，移过去。
//            抢焦点前先做这一步 —— 顺序关键。
//   第 1 步  找键盘窗口。找到 → 键盘其实起来了、只是被 lv=1001 的标注窗口压住，
//            就把标注窗口降到「键盘窗口层级 - 0.5」（不是瞎降到 10）。
//   第 2 步  没有 → 反过来抬键盘窗口到标注窗口之上；仍没有 → 给输入框挂一个
//            1pt 透明、不吃触摸的 inputAccessoryView 并 reloadInputViews。
//   第 3 步  reloadInputViews + 再抢一次焦点（只抢，不回退）。
//   第 4 步  2 秒内仍收不到键盘通知 → 所有层级改动全部回滚，保持原样。
//
//   全程绝不 resignFirstResponder、绝不自动注销 SpringBoard。
//   运行日志写在 /var/mobile/Documents/S3TextKeyboardFix.log（可选，仅排查用）。
// ─────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <stdarg.h>
#include <unistd.h>

static NSString *const kLogPath = @"/var/mobile/Documents/S3TextKeyboardFix.log";
static NSString *const kS3Ver   = @"1.7.1";

static const CGFloat kMinSaneLevel = 1.0;   // 标注窗口最低层级，保证仍在桌面图标之上
static const unsigned long long kLogMaxBytes = 256 * 1024;

// ───────────────────────────── 日志 ─────────────────────────────
static void S3Append(NSString *path, NSString *line) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
    if (attr && [attr fileSize] > kLogMaxBytes) {
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    if (![fm fileExistsAtPath:path]) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) return;
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

static void S3Log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    S3Append(kLogPath, [NSString stringWithFormat:@"[S3Fix %@] %@\n", kS3Ver, s]);
}

// ───────────────────── 自证身份：本份 dylib 从哪加载 ─────────────────────
static NSString *S3SelfPath(void) {
    Dl_info info;
    const char *p = "?";
    if (dladdr((void *)(uintptr_t)&S3Log, &info) && info.dli_fname) p = info.dli_fname;
    return [NSString stringWithUTF8String:p];
}

static NSString *S3SelfShort(void) {
    NSArray *c = [S3SelfPath() componentsSeparatedByString:@"/"];
    if (c.count >= 2) return [NSString stringWithFormat:@"%@/%@", c[c.count - 2], c.lastObject];
    return S3SelfPath();
}

// ───────────────────────────── 状态 ─────────────────────────────
static __weak UIWindow *gAnnoWin = nil;
static __weak UIViewController *gVC = nil;
static __weak UIWindow *gKbWinRaised = nil;
static BOOL gKbSeen = NO;
static BOOL gAnnoLowered = NO;
static BOOL gAccessoryAdded = NO;
static CGFloat gAnnoSavedLevel = 0;
static CGFloat gKbSavedLevel = 0;
static int gGen = 0;
static double gStartAt = 0;

// ───────────────────────────── 工具 ─────────────────────────────
static void S3CollectWindowsIn(UIView *v, NSMutableArray *out, int depth);

static NSArray<UIWindow *> *S3AllWindows(void) {
    NSMutableArray *all = [NSMutableArray array];
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (![all containsObject:w]) [all addObject:w];
        }
    }
    // iOS 16 起键盘窗口不一定在 UIApplication.windows 里，再兜一层
    id appw = [[UIApplication sharedApplication] valueForKey:@"windows"];
    if ([appw isKindOfClass:[NSArray class]]) {
        for (UIWindow *w in (NSArray *)appw) {
            if (![all containsObject:w]) [all addObject:w];
        }
    }
    for (UIWindow *w in [all copy]) {
        S3CollectWindowsIn(w, all, 0);
    }
    return all;
}

static void S3CollectWindowsIn(UIView *v, NSMutableArray *out, int depth) {
    if (!v || depth > 5) return;
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:[UIWindow class]] && ![out containsObject:(UIWindow *)sub]) {
            [out addObject:(UIWindow *)sub];
        }
        S3CollectWindowsIn(sub, out, depth + 1);
    }
}

static BOOL S3IsKeyboardWindow(UIWindow *w) {
    if (!w) return NO;
    NSString *n = NSStringFromClass([w class]);
    if ([n rangeOfString:@"TextEffects"].location != NSNotFound) return YES;
    if ([n rangeOfString:@"RemoteKeyboard"].location != NSNotFound) return YES;
    if ([n rangeOfString:@"KeyboardWindow"].location != NSNotFound) return YES;
    if ([n rangeOfString:@"UIKeyboard"].location != NSNotFound) return YES;
    return NO;
}

static UIWindow *S3FindKeyboardWindow(NSString **dump) {
    NSMutableString *ms = [NSMutableString string];
    UIWindow *best = nil;
    NSMutableArray *cands = [NSMutableArray array];
    for (UIWindow *w in S3AllWindows()) {
        if (S3IsKeyboardWindow(w)) [cands addObject:w];
    }
    UIApplication *app = [UIApplication sharedApplication];
    SEL sel  = NSSelectorFromString(@"sharedTextEffectsWindow");
    SEL sel2 = NSSelectorFromString(@"sharedTextEffectsWindowForWindowScene:");
    if ([app respondsToSelector:sel]) {
        IMP imp = [app methodForSelector:sel];
        id r = ((id (*)(id, SEL))imp)(app, sel);
        if ([r isKindOfClass:[UIWindow class]] && ![cands containsObject:r]) [cands addObject:r];
    }
    if ([app respondsToSelector:sel2] && gAnnoWin.windowScene) {
        IMP imp = [app methodForSelector:sel2];
        id r = ((id (*)(id, SEL, id))imp)(app, sel2, gAnnoWin.windowScene);
        if ([r isKindOfClass:[UIWindow class]] && ![cands containsObject:r]) [cands addObject:r];
    }
    for (UIWindow *w in cands) {
        [ms appendFormat:@"%@ lv=%.0f hidden=%d %.0fx%.0f  ",
         NSStringFromClass([w class]), w.windowLevel, (int)w.isHidden,
         w.frame.size.width, w.frame.size.height];
        if (!best || w.windowLevel > best.windowLevel) best = w;
    }
    if (cands.count == 0) [ms appendString:@"未找到"];
    if (dump) *dump = ms;
    return best;
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
    if (!vc || !vc.isViewLoaded) return nil;
    UIView *v = [vc.view viewWithTag:200];
    if ([v isKindOfClass:[UITextField class]] || [v isKindOfClass:[UITextView class]]) return (UIResponder *)v;
    return (UIResponder *)S3FindEditable(vc.view, 0);
}

// ───────────────────────── 场景纠正 ─────────────────────────
// 优先挑「真的在承载键盘」的场景：有别的窗口在当 key > 有状态栏窗口 > 前台活跃场景
static UIWindowScene *S3BestScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindowScene *fore = nil, *withBar = nil, *any = nil;
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        if (!any) any = ws;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        if (!fore) fore = ws;
        for (UIWindow *w in ws.windows) {
            if (w != gAnnoWin && w.isKeyWindow) return ws;
            if (!withBar && w.windowLevel >= 1000 && !w.isHidden) withBar = ws;
        }
    }
    if (withBar) return withBar;
    if (fore) return fore;
    return any;
}

static void S3RepairScene(UIWindow *anno) {
    if (!anno) return;
    UIWindowScene *cur = anno.windowScene;

    if (!cur) {
        UIWindowScene *best = S3BestScene();
        if (!best) {
            S3Log(@"场景：找不到任何可用场景，放弃");
            return;
        }
        anno.windowScene = best;
        S3Log(@"★ 标注窗口原本没有 windowScene → 已挂到 act=%ld（%d）",
              (long)best.activationState, (int)(anno.windowScene == best));
        return;
    }

    // 同类窗口在同一个场景里，标注窗口拿了 key 之后别人不可能是 key。
    // 若「另一个场景」里还有窗口在当 key，说明我们挂错了场景。
    UIWindowScene *otherKeyScene = nil;
    UIWindow *otherKeyWin = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        if (ws == cur) continue;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow && !w.isHidden) { otherKeyScene = ws; otherKeyWin = w; break; }
        }
        if (otherKeyScene) break;
    }
    if (otherKeyScene) {
        anno.windowScene = otherKeyScene;
        S3Log(@"★ 标注窗口场景 act=%ld 挂错，另一个场景里 %@ 才是 key → 已移过去（%d）",
              (long)cur.activationState, NSStringFromClass([otherKeyWin class]),
              (int)(anno.windowScene == otherKeyScene));
    }
}

// ───────────────────────── 层级处置 ─────────────────────────
static void S3LowerAnnoUnderKeyboard(UIWindow *anno, UIWindow *kb) {
    if (gAnnoLowered || !anno || !kb) return;
    CGFloat target = kb.windowLevel - 0.5;
    if (target < kMinSaneLevel) target = kMinSaneLevel;
    if (anno.windowLevel <= target) return;
    gAnnoSavedLevel = anno.windowLevel;
    anno.windowLevel = target;
    gAnnoLowered = YES;
    S3Log(@"第1步：标注窗口 lv %.0f -> %.0f（键盘窗口 lv=%.0f）",
          gAnnoSavedLevel, target, kb.windowLevel);
}

static void S3RaiseKeyboardWindow(UIWindow *anno, UIWindow *kb) {
    if (gKbWinRaised || !anno || !kb) return;
    if (kb.windowLevel > anno.windowLevel) return;
    gKbSavedLevel = kb.windowLevel;
    kb.windowLevel = anno.windowLevel + 1.0;
    gKbWinRaised = kb;
    S3Log(@"第2步：抬键盘窗口 %@ lv %.0f -> %.0f",
          NSStringFromClass([kb class]), gKbSavedLevel, kb.windowLevel);
}

@protocol S3InputViewHost <NSObject>
@property (nullable, nonatomic, strong) UIView *inputAccessoryView;
@end

static void S3AttachAccessory(UIResponder *r) {
    if (gAccessoryAdded || !r) return;
    if (![r respondsToSelector:@selector(setInputAccessoryView:)]) return;
    id<S3InputViewHost> h = (id<S3InputViewHost>)r;
    UIView *old = [r respondsToSelector:@selector(inputAccessoryView)] ? h.inputAccessoryView : nil;
    if (old) { gAccessoryAdded = YES; return; }
    UIView *a = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 1)];
    a.backgroundColor = [UIColor clearColor];
    a.userInteractionEnabled = NO;
    h.inputAccessoryView = a;
    [r reloadInputViews];
    gAccessoryAdded = YES;
    S3Log(@"第2步：给输入框挂了 1pt 透明 inputAccessoryView 并 reloadInputViews");
}

static void S3RollbackLevels(void) {
    if (gAnnoLowered) {
        UIWindow *w = gAnnoWin;
        if (w) {
            S3Log(@"回滚：标注窗口 lv %.0f -> %.0f", w.windowLevel, gAnnoSavedLevel);
            w.windowLevel = gAnnoSavedLevel;
        }
    }
    if (gKbWinRaised) {
        S3Log(@"回滚：键盘窗口 lv %.0f -> %.0f", gKbWinRaised.windowLevel, gKbSavedLevel);
        gKbWinRaised.windowLevel = gKbSavedLevel;
    }
    gAnnoLowered = NO;
    gAnnoSavedLevel = 0;
    gKbWinRaised = nil;
    gKbSavedLevel = 0;
    gAccessoryAdded = NO;
}

static void S3Restore(void) {
    S3RollbackLevels();
    gKbSeen = NO;
    gVC = nil;
    gGen++;
}

// ───────────────────────── 分步执行 ─────────────────────────
static void S3Step(UIViewController *vc, int step, int gen);

static void S3Schedule(UIViewController *vc, int step, int gen, double gap) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ S3Step(vc, step + 1, gen); });
}

static void S3Step(UIViewController *vc, int step, int gen) {
    if (gen != gGen || !vc) return;
    UIWindow *anno = S3WindowForView(vc.view);
    if (!anno) anno = gAnnoWin;
    UIResponder *input = S3InputIn(vc);

    // 键盘一出现就收工，不再改任何东西
    if (gKbSeen) {
        S3Log(@"✔ 键盘已确认出现（第 %d 步收工）", step);
        return;
    }

    switch (step) {
        case 0: {
            gAnnoWin = anno;
            S3Log(@"──── 打开文字面板（本份来自 %@）", S3SelfShort());
            S3RepairScene(anno);
            if (anno && !anno.isKeyWindow) [anno makeKeyAndVisible];
            if (input && !input.isFirstResponder) {
                BOOL ok = [input becomeFirstResponder];
                S3Log(@"第0步：输入框抢焦点 -> %d", (int)ok);
            }
            S3Schedule(vc, step, gen, 0.30);
            break;
        }
        case 1: {
            NSString *dump = nil;
            UIWindow *kb = S3FindKeyboardWindow(&dump);
            S3Log(@"第1步：键盘窗口 %@", dump);
            if (kb) S3LowerAnnoUnderKeyboard(anno, kb);
            if (input && !input.isFirstResponder) [input becomeFirstResponder];
            S3Schedule(vc, step, gen, 0.60);
            break;
        }
        case 2: {
            NSString *dump = nil;
            UIWindow *kb = S3FindKeyboardWindow(&dump);
            if (kb) {
                S3RaiseKeyboardWindow(anno, kb);
            } else if (input) {
                S3AttachAccessory(input);
                [input becomeFirstResponder];
            }
            S3Schedule(vc, step, gen, 0.60);
            break;
        }
        case 3: {
            if (input) {
                [input reloadInputViews];
                BOOL ok = [input becomeFirstResponder];
                S3Log(@"第3步：reloadInputViews + 抢焦点 -> %d", (int)ok);
            }
            S3Schedule(vc, step, gen, 0.60);
            break;
        }
        default: {
            S3Log(@"✘ 两秒内没收到键盘通知，回滚全部层级改动");
            S3RollbackLevels();
            break;
        }
    }
}

static void S3Start(UIViewController *vc) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ S3Start(vc); });
        return;
    }
    if (!vc) return;
    double now = [NSDate date].timeIntervalSince1970;
    if (gVC == vc && (now - gStartAt) < 2.0) return;   // 同一面板 2 秒内只跑一轮
    gVC = vc;
    gStartAt = now;
    gKbSeen = NO;
    gAccessoryAdded = NO;
    int gen = ++gGen;
    S3Step(vc, 0, gen);
}

// ───────────────────── hook 安装 ─────────────────────
static void S3InstallHook(void) {
    static int tries = 0;
    Class cls = NSClassFromString(@"S3TextEditViewController");
    if (!cls) {
        if (++tries < 600) {
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
            // 抢焦点之前先把场景补好 —— 顺序关键
            if (anno && !anno.windowScene) {
                UIWindowScene *best = S3BestScene();
                if (best) anno.windowScene = best;
            }
            if (origEnsure) ((void (*)(id, SEL))origEnsure)(self, selEnsure);
            S3Start(self);
        });
        method_setImplementation(mEnsure, newImp);
        S3Log(@"已 hook ensureTextKeyboard");
    } else {
        S3Log(@"⚠️ 没有 ensureTextKeyboard，改走 viewDidAppear");
    }

    Method mAppear = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidAppear:"));
    if (mAppear) {
        IMP origAppear = method_getImplementation(mAppear);
        IMP newAppear = imp_implementationWithBlock(^(UIViewController *self, BOOL animated) {
            if (origAppear) ((void (*)(id, SEL, BOOL))origAppear)(self, @selector(viewDidAppear:), animated);
            S3Start(self);      // 双保险：ensureTextKeyboard 万一没被调，这里也一定触发
        });
        method_setImplementation(mAppear, newAppear);
        S3Log(@"已 hook viewDidAppear:");
    }

    Method mDis = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidDisappear:"));
    if (mDis) {
        IMP origDis = method_getImplementation(mDis);
        IMP newDis = imp_implementationWithBlock(^(UIViewController *self, BOOL animated) {
            if (origDis) ((void (*)(id, SEL, BOOL))origDis)(self, @selector(viewDidDisappear:), animated);
            S3Log(@"面板消失 → 回滚");
            S3Restore();
        });
        method_setImplementation(mDis, newDis);
        S3Log(@"已 hook viewDidDisappear:");
    }

    S3Log(@"hook 安装完成（本份来自 %@）", S3SelfShort());
}

__attribute__((constructor)) static void S3Init(void) {
    S3Log(@"===== v%@ 已加载 pid=%d =====", kS3Ver, getpid());

    dispatch_async(dispatch_get_main_queue(), ^{
        S3InstallHook();

        // block 版观察者返回的 token 必须自己持有，否则立刻释放、回调根本不触发
        static NSMutableArray *tokens = nil;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        tokens = [NSMutableArray array];
        [tokens addObject:[nc addObserverForName:UIKeyboardWillShowNotification
                                          object:nil queue:[NSOperationQueue mainQueue]
                                      usingBlock:^(NSNotification *note) {
            gKbSeen = YES;
            S3Log(@"UIKeyboardWillShow");
        }]];
        [tokens addObject:[nc addObserverForName:UIKeyboardDidShowNotification
                                          object:nil queue:[NSOperationQueue mainQueue]
                                      usingBlock:^(NSNotification *note) {
            gKbSeen = YES;
            S3Log(@"UIKeyboardDidShow 键盘确认出现");
        }]];
        [tokens addObject:[nc addObserverForName:UIKeyboardDidHideNotification
                                          object:nil queue:[NSOperationQueue mainQueue]
                                      usingBlock:^(NSNotification *note) {
            S3Log(@"UIKeyboardDidHide");
        }]];

        // 兜底：面板被直接销毁时回滚（文字面板不走 viewDidDisappear 的情况）
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            if (!gVC && !gAnnoLowered && !gKbWinRaised) return;
            UIViewController *vc = gVC;
            if (!vc || vc.isBeingDismissed || !vc.isViewLoaded || !vc.view.window) {
                S3Log(@"清理：文字面板已消失");
                S3Restore();
            }
        }];
    });
}
