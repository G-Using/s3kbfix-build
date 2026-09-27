// S3TextKeyboardFix 1.6.9 —— 让「截图标记」的文字标注面板弹出系统原生键盘
//
// ─────────────────────────────────────────────────────────────────────────
// 一、这一版的核心变化：不再猜，把判定结果直接显示在屏幕上
//
// 前几轮的教训：每次都是"改了理论 → 用户装 → 还是不行 → 再猜"。原因是**拿不到运行时数据**。
// 所以 1.6.9 做了三件事：
//   1) 在屏幕上打一块诊断横幅（15 秒后自动消失），用户截个图就能看到全部关键状态；
//   2) 日志同时写两份，其中 /var/mobile/Media/ 是电脑上（爱思助手 / AFC）能直接取到的目录；
//   3) 用一个「隐藏探针输入框」把问题一刀切成两半（见下）。
//
// 二、问题的两种可能，用探针一次判定
//
//   「有光标但没键盘」只可能是两类原因：
//     A. 系统压根没让键盘出现（第一响应者/窗口不是 key/硬件键盘模式/场景不活跃）
//     B. 键盘其实出现了，只是被盖在标注窗口（level 1001）下面
//
//   判定方法：在标注窗口里插一个几乎不可见的 UITextField，让它成为第一响应者。
//     - 探针能弹键盘  → 该窗口能承载键盘 → 问题在原输入框或时序 → 属 A 的其他分支
//     - 探针弹不出键盘 → 窗口层面就承载不了 → 属 A
//   同时监听 UIKeyboardWillShow/DidShow：**系统一旦发出这两个通知，就说明键盘真的出现了，
//   此时若用户仍看不到，则必然是 B（被盖住）**。
//
//   于是 1.6.9 的处置是有依据的、二选一：
//     · 收到键盘通知（kb=1）→ 判定 B → 才去把标注窗口压到键盘之下（1.0）。
//       1.6.3 的错在于**不分情况**先压层级，还把窗口压到 10（正好和键盘窗口同层，同层按创建
//       顺序仍然压在上面），结果既没用又可能丢第一响应者。
//     · 收不到键盘通知（kb=0）→ 判定 A → **一律不动窗口层级**，把状态原样报出来。
//
// 三、输入框的事实（反汇编 biaoji.dylib 确认）
//   - 文字面板输入框是标准 UITextField，tag = 0xC8 = 200，没有自定义 inputView；
//   - 面板容器 tag = 999，在屏幕底部，键盘弹出会盖住「取消 / 确认」→ 需要 transform 上移；
//   - 标注窗口是标准 UIWindow（_OBJC_CLASS_$_UIWindow），windowLevel = _UIWindowLevelStatusBar + 1 = 1001，
//     创建时即 setHidden:NO + makeKeyWindow；resignKeyWindow 只在 closeAnimated / airDropTapped 里调用；
//   - biaoji 自己的 -ensureTextKeyboard（IMP 0xba70）是**标准且正确**的：先 makeKeyWindow，
//     再 dispatch_async 里 becomeFirstResponder；只是没有重试。
// ─────────────────────────────────────────────────────────────────────────

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <stdarg.h>
#include <unistd.h>

static NSString *const kLogPathDocuments = @"/var/mobile/Documents/S3TextKeyboardFix.log";
static NSString *const kLogPathMedia     = @"/var/mobile/Media/S3TextKeyboardFix.log";

static NSString *const kS3Ver = @"1.6.9";

// 判定为 B（键盘被盖住）之后，把标注窗口压到这个层级（严格低于键盘窗口）
static const CGFloat kAnnoLevelUnderKeyboard = 1.0;

// ───────────────────────────── 日志（双份） ─────────────────────────────
static void S3Append(NSString *path, NSString *line) {
    NSFileManager *fm = [NSFileManager defaultManager];
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
    NSString *line = [NSString stringWithFormat:@"[S3TextFix %@] %@\n", kS3Ver, s];
    S3Append(kLogPathDocuments, line);
    S3Append(kLogPathMedia, line);
}

// ───────────────────── 自证身份：本 dylib 到底是谁 ─────────────────────
static NSString *S3SelfPath(void) {
    Dl_info info;
    const char *p = "?";
    if (dladdr((void *)(uintptr_t)&S3Log, &info) && info.dli_fname) p = info.dli_fname;
    return [NSString stringWithUTF8String:p];
}

// 短路径：只留最后两段，横幅上用
static NSString *S3SelfShort(void) {
    NSArray *c = [S3SelfPath() componentsSeparatedByString:@"/"];
    if (c.count >= 2) return [NSString stringWithFormat:@"%@/%@", c[c.count - 2], c.lastObject];
    return S3SelfPath();
}

static NSArray<NSString *> *S3RelatedImages(void) {
    NSMutableArray *a = [NSMutableArray array];
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *f = [NSString stringWithUTF8String:nm];
        if (!f) continue;
        if ([f containsString:@"S3TextKeyboardFix"] || [f containsString:@"biaoji"]) [a addObject:f];
    }
    return a;
}

// ───────────────────────────── 状态 ─────────────────────────────
static __weak UIWindow *gAnnoWindow = nil;
static __weak UIViewController *gVC = nil;
static BOOL gKbSeen = NO;              // 系统是否已发出键盘显示通知（判定 A/B 的关键）
static BOOL gKbFrameLogged = NO;
static BOOL gLevelLowered = NO;
static CGFloat gAnnoSavedLevel = 0;
static NSMutableArray *gObservers = nil;
static int gGen = 0;                   // 每次打开面板递增，用来作废旧的重试链
static int gHookState = 0;             // 0 未装 1 已装
static NSInteger gProbeResult = 0;     // 0 未测 1 窗口能弹键盘 2 抢到焦点但无键盘 3 连焦点都抢不到

// ───────────────────────────── 横幅 ─────────────────────────────
@interface S3BannerWindow : UIWindow @end
@implementation S3BannerWindow
- (BOOL)canBecomeKeyWindow { return NO; }   // 绝不参与 key window 竞争，避免干扰键盘
@end

static S3BannerWindow *gBannerWin = nil;
static UILabel *gBannerLabel = nil;
static NSTimer *gBannerHide = nil;

static UIWindowScene *S3AnyWindowScene(void) {
    if (gAnnoWindow.windowScene) return gAnnoWindow.windowScene;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

static void S3Banner(NSString *text) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ S3Banner(text); });
        return;
    }
    if (!gBannerWin) {
        UIWindowScene *sc = S3AnyWindowScene();
        CGRect b = sc ? sc.coordinateSpace.bounds : [UIScreen mainScreen].bounds;
        gBannerWin = sc ? [[S3BannerWindow alloc] initWithWindowScene:sc]
                        : [[S3BannerWindow alloc] initWithFrame:b];
        gBannerWin.frame = b;
        gBannerWin.windowLevel = 1005.0;      // 在标注窗口(1001)之上，远低于键盘窗口
        gBannerWin.backgroundColor = [UIColor clearColor];
        gBannerWin.rootViewController = [UIViewController new];
        gBannerWin.rootViewController.view.backgroundColor = [UIColor clearColor];
        gBannerWin.rootViewController.view.userInteractionEnabled = NO;
        gBannerLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 60, b.size.width - 20, 10)];
        gBannerLabel.numberOfLines = 0;
        gBannerLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        gBannerLabel.textColor = [UIColor whiteColor];
        gBannerLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];
        gBannerLabel.layer.cornerRadius = 6;
        gBannerLabel.clipsToBounds = YES;
        [gBannerWin.rootViewController.view addSubview:gBannerLabel];
        gBannerWin.hidden = NO;
    }
    if (!gBannerLabel) return;
    gBannerLabel.text = [NSString stringWithFormat:@"\n%@\n", text];   // 上下留白
    CGFloat w = gBannerWin.frame.size.width - 20;
    CGSize sz = [gBannerLabel sizeThatFits:CGSizeMake(w, 900)];
    gBannerLabel.frame = CGRectMake(10, 60, w, sz.height + 4);
    gBannerLabel.hidden = NO;
    [gBannerHide invalidate];
    gBannerHide = [NSTimer scheduledTimerWithTimeInterval:15 repeats:NO block:^(NSTimer *t) {
        gBannerLabel.hidden = YES;
    }];
}

// ───────────────────────────── 工具 ─────────────────────────────
static NSArray<UIWindow *> *S3AllWindows(void) {
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

static NSString *S3DescribeInput(UIResponder *r) {
    if (!r) return @"无";
    NSString *tag = [r isKindOfClass:[UIView class]] ? [NSString stringWithFormat:@" tag=%ld", (long)((UIView *)r).tag] : @"";
    return [NSString stringWithFormat:@"%@%@ fr=%d", NSStringFromClass([r class]), tag, (int)r.isFirstResponder];
}

// 硬件键盘模式：开着的话系统**永远不会**弹屏幕键盘，表现就是「有光标没键盘」
static NSInteger S3HardwareKeyboardMode(void) {
    Class k = NSClassFromString(@"UIKeyboard");
    SEL s = NSSelectorFromString(@"isInHardwareKeyboardMode");
    if (!k || ![k respondsToSelector:s]) return -1;
    BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))[k methodForSelector:s];
    return fn(k, s) ? 1 : 0;
}

static NSString *S3StatusLine(UIViewController *vc) {
    UIWindow *anno = S3WindowForView(vc.view);
    NSArray<NSString *> *imgs = S3RelatedImages();
    NSInteger hw = S3HardwareKeyboardMode();
    return [NSString stringWithFormat:
            @"S3TextFix %@  hook=%d  镜像=%lu份\n"
            @"本份=%@\n"
            @"标注窗口=%@ lv=%.0f key=%d\n"
            @"输入框=%@\n"
            @"键盘通知=%d  层级已压=%d\n"
            @"硬件键盘=%ld  探针=%@",
            kS3Ver, gHookState, (unsigned long)imgs.count,
            S3SelfShort(),
            anno ? NSStringFromClass([anno class]) : @"未找到",
            anno ? anno.windowLevel : 0,
            anno ? (int)anno.isKeyWindow : 0,
            S3DescribeInput(S3InputIn(vc)),
            (int)gKbSeen, (int)gLevelLowered,
            (long)hw,
            gProbeResult == 0 ? @"未测" : (gProbeResult == 1 ? @"能弹键盘" :
                              (gProbeResult == 2 ? @"抢到焦点/键盘不出" : @"连焦点都抢不到"))];
}

// ───────────────── 判定 B 的处置：把标注窗口压到键盘之下 ─────────────────
static void S3LowerIfCovering(void) {
    if (gLevelLowered) return;
    UIWindow *anno = gAnnoWindow;
    if (!anno) return;
    if (anno.windowLevel <= kAnnoLevelUnderKeyboard) return;
    gAnnoSavedLevel = anno.windowLevel;
    anno.windowLevel = kAnnoLevelUnderKeyboard;
    gLevelLowered = YES;
    S3Log(@"判定 B（键盘其实已弹出）→ 标注窗口层级 %.0f -> %.0f，让键盘不再被压住",
          gAnnoSavedLevel, kAnnoLevelUnderKeyboard);
    S3Log(@"当前窗口：%@", S3WindowDump());
}

static void S3Restore(void) {
    if (gVC) {
        UIView *panel = [gVC.view viewWithTag:999];
        if (panel && !CGAffineTransformIsIdentity(panel.transform)) {
            panel.transform = CGAffineTransformIdentity;
            S3Log(@"还原：文字面板位置复位");
        }
    }
    if (gLevelLowered) {
        UIWindow *w = gAnnoWindow;
        if (w) {
            S3Log(@"还原：标注窗口层级 %.0f -> %.0f", w.windowLevel, gAnnoSavedLevel);
            w.windowLevel = gAnnoSavedLevel;
        }
    }
    gLevelLowered = NO;
    gAnnoSavedLevel = 0;
    gAnnoWindow = nil;
    gVC = nil;
    gKbSeen = NO;
    gKbFrameLogged = NO;
    gProbeResult = 0;
    gGen++;                       // 作废旧的重试链
}

// 面板在屏幕底部，「取消/确认」就在最下面 —— 键盘弹出来正好盖住它俩。
// 只对面板做 transform，不动 biaoji 自己的布局。
static void S3ShiftPanel(NSNotification *n, BOOL up) {
    if (!gVC) return;
    UIView *panel = [gVC.view viewWithTag:999];
    if (!panel) return;
    CGFloat h = 0;
    if (up) {
        NSValue *v = n.userInfo[UIKeyboardFrameEndUserInfoKey];
        if ([v isKindOfClass:[NSValue class]]) h = CGRectGetHeight([v CGRectValue]);
        if (h <= 0 || h > 600) h = 336.0;
        if (!CGAffineTransformIsIdentity(panel.transform)) return;
    }
    [UIView animateWithDuration:0.25 animations:^{
        panel.transform = up ? CGAffineTransformMakeTranslation(0, -h)
                             : CGAffineTransformIdentity;
    }];
    S3Log(@"文字面板%@ %.0f", up ? @"随键盘上移" : @"复位", h);
}

// ───────────────────────── 隐藏探针 ─────────────────────────
static UITextField *gProbe = nil;

static void S3ProbeBegin(UIViewController *vc) {
    UIWindow *anno = S3WindowForView(vc.view);
    if (!anno) {
        S3Log(@"探针：找不到标注窗口，跳过");
        gProbeResult = 3;
        return;
    }
    if (!gProbe) {
        UITextField *f = [[UITextField alloc] initWithFrame:CGRectMake(1, 1, 2, 2)];
        f.backgroundColor = [UIColor clearColor];
        f.textColor = [UIColor clearColor];
        f.tintColor = [UIColor clearColor];
        f.opaque = NO;
        gProbe = f;
    }
    [anno addSubview:gProbe];
    BOOL ok = [gProbe becomeFirstResponder];
    S3Log(@"探针：在标注窗口插入隐藏输入框并抢焦点 -> %d（窗口 key=%d）", (int)ok, (int)anno.isKeyWindow);
}

static void S3ProbeJudge(UIViewController *vc) {
    if (gProbe) {
        BOOL became = gProbe.isFirstResponder;
        BOOL kb = gKbSeen;
        gProbeResult = kb ? 1 : (became ? 2 : 3);
        S3Log(@"探针结果：焦点=%d 键盘=%d → %@", (int)became, (int)kb,
              kb ? @"该窗口能承载键盘（问题在原输入框/时序）"
                 : (became ? @"抢到焦点但键盘不出（窗口或场景层面被拦）"
                           : @"连焦点都抢不到（另有第一响应者或场景不活跃）"));
        [gProbe resignFirstResponder];
        [gProbe removeFromSuperview];
        gProbe = nil;
    }
    UIResponder *tf = S3InputIn(vc);
    if (tf) [tf becomeFirstResponder];     // 把焦点还给真正的输入框
}

// ───────────────────── 核心：一次尝试 ─────────────────────
static void S3Attempt(UIViewController *vc, int attempt) {
    if (!vc) return;

    UIWindow *anno = S3WindowForView(vc.view);
    if (!anno) {
        S3Log(@"第 %d 次：还找不到 vc 所在窗口 %@", attempt, vc);
        return;
    }
    gAnnoWindow = anno;

    if (!anno.isKeyWindow) {
        [anno makeKeyWindow];
        S3Log(@"第 %d 次：标注窗口 makeKeyWindow → key=%d", attempt, (int)anno.isKeyWindow);
    }

    UIResponder *tf = S3InputIn(vc);
    if (!tf) {
        S3Log(@"第 %d 次：面板里没找到输入框", attempt);
        return;
    }

    if (tf.isFirstResponder) {
        S3Log(@"第 %d 次：输入框已是第一响应者（键盘=%d）", attempt, (int)gKbSeen);
    } else {
        BOOL ok = [tf becomeFirstResponder];
        S3Log(@"第 %d 次：becomeFirstResponder -> %d", attempt, (int)ok);
        if (!ok) {
            [tf resignFirstResponder];
            [tf reloadInputViews];
            ok = [tf becomeFirstResponder];
            S3Log(@"第 %d 次：resign/reload 后重试 -> %d", attempt, (int)ok);
        }
    }
}

// 固定节奏的重试阶梯（秒），到点执行对应动作，键盘一出现就立刻收工
static const double kStepGap[] = {0, 0.15, 0.25, 0.35, 0.5, 0.6, 0.8, 0.8, 1.0, 1.5, 1.5};
#define kNumSteps ((int)(sizeof(kStepGap) / sizeof(kStepGap[0])))

static void S3Step(UIViewController *vc, int step, int gen);

static void S3Schedule(UIViewController *vc, int step, int gen) {
    double gap = (step + 1 < kNumSteps) ? kStepGap[step + 1] : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gap * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ S3Step(vc, step + 1, gen); });
}

static void S3Step(UIViewController *vc, int step, int gen) {
    if (gen != gGen || !vc) return;

    // 键盘出现 → 收工。系统都发了通知还看不到键盘，那就是被标注窗口压住了（判定 B）
    if (gKbSeen && step > 0) {
        S3LowerIfCovering();
        S3Log(@"键盘已确认出现（第 %d 步）", step);
        S3Banner([NSString stringWithFormat:@"%@\n\n✔ 键盘已弹出（系统已确认）", S3StatusLine(vc)]);
        return;
    }

    if (step >= kNumSteps) {
        S3Log(@"阶梯走完：键盘始终没出现（来自 %@）", S3SelfShort());
        S3Log(@"最终窗口：%@", S3WindowDump());
        NSString *verdict = [NSString stringWithFormat:
            @"%@\n\n✘ 键盘没弹出\n判定=%@\n→ 请把这块截图发给作者",
            S3StatusLine(vc),
            gProbeResult == 1 ? @"窗口正常，原输入框/时序问题"
                              : (gProbeResult == 2 ? @"窗口抢到焦点但键盘不出"
                                                   : (gProbeResult == 3 ? @"连焦点都抢不到"
                                                                        : @"未知（探针没跑到）"))];
        S3Banner(verdict);
        return;
    }

    switch (step) {
        case 0: {
            gAnnoWindow = S3WindowForView(vc.view);
            S3Log(@"──── 开始尝试（来自 %@）", S3SelfShort());
            S3Log(@"硬件键盘模式=%ld（1 = 系统永远不会弹屏幕键盘）", (long)S3HardwareKeyboardMode());
            S3Log(@"窗口清单：%@", S3WindowDump());
            S3Log(@"输入框：%@", S3DescribeInput(S3InputIn(vc)));
            S3Banner(S3StatusLine(vc));
            S3Attempt(vc, 0);
            break;
        }
        case 7:
            S3ProbeBegin(vc);
            break;
        case 8:
            S3ProbeJudge(vc);
            S3Banner(S3StatusLine(vc));
            break;
        default:
            S3Attempt(vc, step);
            break;
    }
    S3Schedule(vc, step, gen);
}

static void S3Start(UIViewController *vc) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ S3Start(vc); });
        return;
    }
    if (!vc) return;
    gVC = vc;
    gKbSeen = NO;
    gKbFrameLogged = NO;
    gProbeResult = 0;
    gAnnoWindow = S3WindowForView(vc.view);
    int gen = ++gGen;
    S3Step(vc, 0, gen);
}

// ───────────────────── hook 安装 ─────────────────────
static void S3InstallHook(void) {
    static int tries = 0;
    Class cls = NSClassFromString(@"S3TextEditViewController");
    if (!cls) {
        if (tries % 25 == 0) S3Log(@"S3TextEditViewController 还没出现（重试 %d）", tries);
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
            if (anno && !anno.isKeyWindow) [anno makeKeyWindow];
            if (origEnsure) ((void (*)(id, SEL))origEnsure)(self, selEnsure);
            S3Start(self);
        });
        method_setImplementation(mEnsure, newImp);
        S3Log(@"已 hook ensureTextKeyboard");
    } else {
        S3Log(@"⚠️ 没有 ensureTextKeyboard 方法，改走 viewDidAppear");
    }

    SEL selAppear = NSSelectorFromString(@"viewDidAppear:");
    Method mAppear = class_getInstanceMethod(cls, selAppear);
    if (mAppear) {
        IMP origAppear = method_getImplementation(mAppear);
        IMP newAppear = imp_implementationWithBlock(^(UIViewController *self, BOOL animated) {
            if (origAppear) ((void (*)(id, SEL, BOOL))origAppear)(self, selAppear, animated);
            S3Start(self);       // 双保险：无论 ensureTextKeyboard 有没有被调，这里一定触发
        });
        method_setImplementation(mAppear, newAppear);
        S3Log(@"已 hook viewDidAppear:（双保险）");
    }

    Method mDis = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidDisappear:"));
    if (mDis) {
        IMP origDis = method_getImplementation(mDis);
        IMP newDis = imp_implementationWithBlock(^(UIViewController *self, BOOL animated) {
            if (origDis) ((void (*)(id, SEL, BOOL))origDis)(self, @selector(viewDidDisappear:), animated);
            S3Log(@"viewDidDisappear -> 还原");
            S3Restore();
        });
        method_setImplementation(mDis, newDis);
        S3Log(@"已 hook viewDidDisappear:");
    }

    gHookState = 1;
    S3Log(@"hook 安装完成 on S3TextEditViewController（本份来自 %@）", S3SelfPath());
}

__attribute__((constructor)) static void S3Init(void) {
    S3Log(@"===== v%@ 已加载 pid=%d =====", kS3Ver, getpid());
    S3Log(@"自身路径: %@", S3SelfPath());
    NSArray<NSString *> *imgs = S3RelatedImages();
    S3Log(@"进程内相关镜像（%lu 份，>1 就是被重复注入了）:", (unsigned long)imgs.count);
    for (NSString *p in imgs) S3Log(@"      %@", p);

    dispatch_async(dispatch_get_main_queue(), ^{
        S3InstallHook();

        gObservers = [NSMutableArray array];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        // block 版观察者返回的 token 必须自己持有，否则会被立刻释放、回调根本不触发
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
            if (!gKbFrameLogged) {
                gKbFrameLogged = YES;
                S3ShiftPanel(n, YES);
            }
        }]];
        [gObservers addObject:[nc addObserverForName:UIKeyboardDidHideNotification
                                              object:nil
                                               queue:[NSOperationQueue mainQueue]
                                          usingBlock:^(NSNotification *n) {
            S3Log(@"UIKeyboardDidHide");
            S3ShiftPanel(n, NO);
        }]];

        // 兜底：VC 被直接销毁时还原
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            if (!gVC && !gLevelLowered) return;
            UIViewController *vc = gVC;
            if (!vc || vc.isBeingDismissed || !vc.isViewLoaded || !vc.view.window) {
                S3Log(@"清理：文字面板已消失");
                S3Restore();
            }
        }];
    });
}
