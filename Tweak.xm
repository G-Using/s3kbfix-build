// S3TextKeyboardFix 1.7.0 —— 静默修复版
//
// ─────────────────────────────────────────────────────────────────────────
// 一、1.6.9 那张诊断截图把问题定死了
//
// 截图上的七行数据：
//     镜像=2份            本份=TweakInject/S3TextKeyboardFix.dylib
//     标注窗口=UIWindow lv=1001 key=1
//     输入框=UITextView tag=200 fr=1
//     键盘通知=0          层级已压=0
//     硬件键盘=0          探针=抢到焦点/键盘不出
//
// 逐条读：
//   1) 「键盘通知=0」是决定性的。如果键盘只是被标注窗口(lv=1001)盖住了，
//      系统一样会发 UIKeyboardWillShow —— 我们收不到，说明**键盘压根没被叫起来**。
//      所以「层级压住键盘」那条路可以直接判死，1.6.3 / 1.6.6 的做法本来就是错的。
//   2) 「输入框 fr=1」= 真输入框已经是第一响应者了，biaoji 自己的
//      ensureTextKeyboard（makeKeyWindow + becomeFirstResponder）没写错。
//   3) 「探针=抢到焦点/键盘不出」= 我们往同一个窗口里塞了一个全新的、干净的
//      UITextField，它抢到了焦点，键盘照样不出来 → **这个 UIWindow 本身托不住键盘**，
//      跟 biaoji 的输入框、跟调用时序都无关。
//   4) 「硬件键盘=0」= 不是「连了实体键盘所以系统不弹软键盘」那条分支。
//
// 结论：标注窗口能显示、能当 key window、能拿到第一响应者，但整个窗口拿不到系统键盘。
//       在 iOS 13+ 上这只有一个已知成因：**承载它的那个 UIWindowScene 不对**
//       （场景没附着、或者附到了一个不承载键盘的场景）。窗口层级(1001)与此无关。
//
//   注：biaoji 建窗口时是先 `[UIApplication sharedApplication].connectedScenes`
//       里找一个 `activationState == 0`（ForegroundActive）的 UIWindowScene，
//       找到才用 `initWithWindowScene:`，找不到就退化成 `initWithFrame:`
//       —— 而 iOS 13+ 的**无场景窗口永远拿不到软键盘**（也不会旋转）。
//       反汇编 biaoji.dylib 0x145d0~0x146bc 就是这段。
//
// ─────────────────────────────────────────────────────────────────────────
// 二、1.6.9 把你坑得更狠的地方（这一版全部删掉）
//
//   · 11 级重试阶梯、跨 7 秒，每一步都在 makeKeyWindow + becomeFirstResponder。
//     你点「取消」的瞬间，阶梯刚好把焦点抢回来 → 面板关不掉。这是我自己造的 bug。
//   · 诊断横幅另外开了一个 lv=1005 的全屏 UIWindow —— 又多一层窗口去掺和场景和
//     键盘判定，纯属自找麻烦。
//   · 探针（往窗口里插隐藏输入框、抢焦点、再还回去）—— 目的已经达到，删。
//
//   1.7.0 的横幅改成**贴在标注窗口上的一块 UILabel**（userInteractionEnabled=NO），
//   不新建窗口、不吃触摸，15 秒自动消失；重试缩到 4 步、2 秒内结束、只抢不回退。
//
// ─────────────────────────────────────────────────────────────────────────
// 三、1.7.0 实际做的四件事（按顺序，每一步都记日志）
//
//   第 0 步：体检 + 补场景。如果标注窗口的 windowScene 是空的，就把它挂到一个
//           「真正承载键盘」的场景上（优先：当前 key window 所在的场景 > 有
//           lv>=1000 状态栏窗口的场景 > 第一个 ForegroundActive 场景）。
//           这一步是唯一有可能**真正修好**的动作，且只在场景缺失时动手。
//   第 1 步：找键盘窗口（UITextEffectsWindow / UIRemoteKeyboardWindow / UIKeyboardWindow）。
//           找到 → 说明键盘真的起来了、只是被 lv=1001 的标注窗口压住，
//           此时把标注窗口降到「比键盘窗口低 0.5」——而不是瞎降到 10。
//   第 2 步：再没有 → 抬键盘窗口到标注窗口之上（双保险，两条路各试一次）。
//   第 3 步：还不行 → 给输入框挂一个 1pt 透明、不吃触摸的 inputAccessoryView
//           再 reloadInputViews。依据：1.6.2 那版挂了自定义键盘视图时，
//           原生键盘是跟着一起出来的 —— 挂上输入视图会让系统走一遍输入视图的
//           呈现流程，这是唯一一条「你亲口验证过键盘出现过」的线索。
//   第 4 步：2 秒后仍无键盘 → **所有改动全部回滚**（层级复位），屏幕上留一份
//           判定，日志写两份文件。
//
//   全程绝不 resignFirstResponder、绝不调用 sbreload/killall。
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
static NSString *const kS3Ver = @"1.7.0";

static const CGFloat kMinSaneLevel = 1.0;   // 标注窗口最多降到这个层级，保证还在桌面图标之上

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
    NSString *line = [NSString stringWithFormat:@"[S3Fix %@] %@\n", kS3Ver, s];
    S3Append(kLogPathDocuments, line);
    S3Append(kLogPathMedia, line);
}

// ───────────────────── 自证身份：进程里都有谁 ─────────────────────
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

// 分开统计：补丁自己几份（>1 就是重复注入）+ biaoji 主体几份
static void S3ImageStats(int *fixCount, int *hostCount) {
    int fix = 0, host = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *f = [NSString stringWithUTF8String:nm];
        if (!f) continue;
        if ([f containsString:@"S3TextKeyboardFix.dylib"]) fix++;
        else if ([f containsString:@"biaoji.dylib"]) host++;
    }
    if (fixCount) *fixCount = fix;
    if (hostCount) *hostCount = host;
}

// ───────────────────────────── 状态 ─────────────────────────────
static __weak UIWindow *gAnnoWin = nil;
static __weak UIViewController *gVC = nil;
static BOOL gKbSeen = NO;
static int gGen = 0;
static double gStartAt = 0;
static int gHookState = 0;

static BOOL gAnnoLowered = NO;
static CGFloat gAnnoSavedLevel = 0;

static __weak UIWindow *gKbWinRaised = nil;
static CGFloat gKbSavedLevel = 0;

static NSString *gSceneVerdict = @"未检查";
static NSString *gTryDesc = @"无";

static UILabel *gTip = nil;
static __weak UIWindow *gTipWin = nil;
static NSTimer *gTipHide = nil;

// ───────────────────────── 屏幕提示（贴在标注窗口里，不吃触摸） ─────────────────────────
static void S3Tip(UIWindow *anno, NSString *text, double hideAfter) {
    if (!anno) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ S3Tip(anno, text, hideAfter); });
        return;
    }
    if (gTip && gTipWin == anno && gTip.superview == anno) {
        // 复用
    } else {
        gTip = nil;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 56, anno.bounds.size.width - 20, 10)];
        l.numberOfLines = 0;
        l.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        l.textColor = [UIColor whiteColor];
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
        l.layer.cornerRadius = 6;
        l.clipsToBounds = YES;
        l.userInteractionEnabled = NO;      // 关键：不吃触摸，面板照常能点
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [anno addSubview:l];
        gTip = l;
        gTipWin = anno;
    }
    [anno bringSubviewToFront:gTip];
    gTip.hidden = NO;
    gTip.text = [NSString stringWithFormat:@"\n%@\n", text];
    CGFloat w = anno.bounds.size.width - 20;
    CGSize sz = [gTip sizeThatFits:CGSizeMake(w, 900)];
    gTip.frame = CGRectMake(10, 56, w, sz.height + 2);

    [gTipHide invalidate];
    if (hideAfter > 0) {
        gTipHide = [NSTimer scheduledTimerWithTimeInterval:hideAfter repeats:NO block:^(NSTimer *t) {
            gTip.hidden = YES;
        }];
    }
}

static void S3TipHideNow(void) {
    [gTipHide invalidate];
    gTipHide = nil;
    if (gTip) gTip.hidden = YES;
}

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
    id appw = [[UIApplication sharedApplication] valueForKey:@"windows"];
    if ([appw isKindOfClass:[NSArray class]]) {
        for (UIWindow *w in (NSArray *)appw) {
            if (![all containsObject:w]) [all addObject:w];
        }
    }
    // 键盘窗口在 iOS 15+ 可能不在 UIApplication.windows 里，从各窗口的视图树里再捞一遍
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

// 找键盘窗口：含 [UIApplication sharedTextEffectsWindow] 这条私有入口
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
    if (cands.count == 0) {
        [ms appendString:@"键盘窗口=未找到"];
    } else {
        for (UIWindow *w in cands) {
            [ms appendFormat:@"键盘窗口=%@ lv=%.0f hidden=%d %.0fx%.0f  ",
             NSStringFromClass([w class]), w.windowLevel, (int)w.isHidden,
             w.frame.size.width, w.frame.size.height];
            if (!best || w.windowLevel > best.windowLevel) best = w;
        }
    }
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

static NSString *S3DescribeInput(UIResponder *r) {
    if (!r) return @"无";
    if (![r isKindOfClass:[UIView class]]) return NSStringFromClass([r class]);
    UIView *v = (UIView *)r;
    NSMutableString *s = [NSMutableString stringWithFormat:@"%@ tag=%ld fr=%d",
                          NSStringFromClass([v class]), (long)v.tag, (int)r.isFirstResponder];
    if ([v isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)v;
        [s appendFormat:@" editable=%d 交互=%d", (int)tv.isEditable, (int)tv.isUserInteractionEnabled];
    } else if ([v isKindOfClass:[UITextField class]]) {
        [s appendFormat:@" 交互=%d", (int)v.isUserInteractionEnabled];
    }
    return s;
}

static NSInteger S3HardwareKeyboardMode(void) {
    Class k = NSClassFromString(@"UIKeyboard");
    SEL s = NSSelectorFromString(@"isInHardwareKeyboardMode");
    if (!k || ![k respondsToSelector:s]) return -1;
    BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))[k methodForSelector:s];
    return fn(k, s) ? 1 : 0;
}

// ───────────────────────── 场景体检 ─────────────────────────
static NSString *S3ScenesReport(void) {
    NSMutableString *s = [NSMutableString string];
    UIApplication *app = [UIApplication sharedApplication];
    [s appendFormat:@"  应用状态=%ld（0=Active 1=Inactive 2=Background） 硬件键盘=%ld\n",
     (long)app.applicationState, (long)S3HardwareKeyboardMode()];
    int i = 0;
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) {
            [s appendFormat:@"  #%d %@（非窗口场景）act=%ld\n",
             i++, NSStringFromClass([sc class]), (long)sc.activationState];
            continue;
        }
        UIWindowScene *ws = (UIWindowScene *)sc;
        NSString *role = ws.session.role;
        if (![role isKindOfClass:[NSString class]]) role = @"?";
        [s appendFormat:@"  #%d UIWindowScene act=%ld（0=前台活跃）role=%@ 窗口=%lu\n",
         i++, (long)ws.activationState, role, (unsigned long)ws.windows.count];
        for (UIWindow *w in ws.windows) {
            [s appendFormat:@"       %@ lv=%.0f hidden=%d key=%d\n",
             NSStringFromClass([w class]), w.windowLevel, (int)w.isHidden, (int)w.isKeyWindow];
        }
    }
    return s;
}

// 挑一个「真的能承载键盘」的场景
static UIWindowScene *S3BestScene(void) {
    UIApplication *app = [UIApplication sharedApplication];
    UIWindowScene *fore = nil, *withBar = nil, *any = nil;
    for (UIScene *sc in app.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        if (!any) any = ws;
        if (ws.activationState == UISceneActivationStateForegroundActive) {
            if (!fore) fore = ws;
            for (UIWindow *w in ws.windows) {
                if (w != gAnnoWin && w.isKeyWindow) return ws;              // 最优先：有别人在当 key
                if (!withBar && w.windowLevel >= 1000 && !w.isHidden) withBar = ws;  // 其次：有状态栏窗口
            }
        }
    }
    if (withBar) return withBar;
    if (fore) return fore;
    return any;
}

// 第 0 步：补场景。只在确实有问题时动手，别去瞎折腾已经正常的窗口。
static NSString *S3RepairScene(UIWindow *anno) {
    if (!anno) return @"窗口=未找到";
    UIWindowScene *cur = anno.windowScene;

    // 关键信号：如果「另一个场景」里还有窗口在当 key window，说明这个进程里存在两个
    // 各自有 key window 的场景 —— 我们多半挂在了非主场景上，而键盘只认主场景。
    // （同一个场景里，标注窗口拿了 key 之后，别人就不可能是 key 了。）
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

    if (!cur) {
        UIWindowScene *best = S3BestScene();
        if (!best) return @"窗口场景=无（找不到任何可用场景！）";
        anno.windowScene = best;
        S3Log(@"★ 标注窗口原本没有 windowScene，已挂到 act=%ld 的场景（%d）",
              (long)best.activationState, (int)(anno.windowScene == best));
        return [NSString stringWithFormat:@"窗口场景=原来没有 → 已补挂 act=%ld", (long)best.activationState];
    }

    if (otherKeyScene) {
        CGFloat oldAct = (CGFloat)cur.activationState;
        anno.windowScene = otherKeyScene;
        BOOL ok = (anno.windowScene == otherKeyScene);
        S3Log(@"★ 标注窗口挂在 act=%.0f 的场景上，但另一个场景里 %@ 还是 key → 把标注窗口移过去（%d）",
              oldAct, NSStringFromClass([otherKeyWin class]), (int)ok);
        return [NSString stringWithFormat:@"窗口场景=挂错了，已移到 act=%ld 的场景（那边 %@ 是 key）",
                (long)otherKeyScene.activationState, NSStringFromClass([otherKeyWin class])];
    }

    return [NSString stringWithFormat:@"窗口场景=%@ act=%ld 窗口数=%lu（不动）",
            NSStringFromClass([cur class]), (long)cur.activationState, (unsigned long)cur.windows.count];
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
    S3Log(@"第1步：标注窗口 lv %.0f -> %.0f（键盘窗口 lv=%.0f，压到它下面 0.5）",
          gAnnoSavedLevel, target, kb.windowLevel);
}

static void S3RaiseKeyboardWindow(UIWindow *anno, UIWindow *kb) {
    if (gKbWinRaised || !anno || !kb) return;
    if (kb.windowLevel > anno.windowLevel) return;      // 已经在上面了
    gKbSavedLevel = kb.windowLevel;
    kb.windowLevel = anno.windowLevel + 1.0;
    gKbWinRaised = kb;
    S3Log(@"第2步：抬键盘窗口 %@ lv %.0f -> %.0f（标注窗口 lv=%.0f）",
          NSStringFromClass([kb class]), gKbSavedLevel, kb.windowLevel, anno.windowLevel);
}

static BOOL gAccessoryAdded = NO;

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
    S3Log(@"第3步：给输入框挂了一个 1pt 透明 inputAccessoryView 并 reloadInputViews");
}

// 只回滚层级，不碰 gVC —— 判定那张图还要留在屏幕上
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

// ───────────────────────── 屏幕上的那份判定 ─────────────────────────
static NSString *S3StatusLine(UIViewController *vc, NSString *verdict) {
    UIWindow *anno = S3WindowForView(vc.view);
    if (!anno) anno = gAnnoWin;
    int fix = 0, host = 0;
    S3ImageStats(&fix, &host);
    UIResponder *input = S3InputIn(vc);
    NSString *kbDump = nil;
    (void)S3FindKeyboardWindow(&kbDump);   // 结果只用来写文字，窗口本身不需要
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"S3Fix %@ hook=%d 补丁镜像=%d份%@\n", kS3Ver, gHookState, fix,
     fix > 1 ? @" ⚠️重复注入" : @""];
    [s appendFormat:@"%@\n", S3SelfShort()];
    [s appendFormat:@"窗口=%@ lv=%.0f key=%d\n",
     anno ? NSStringFromClass([anno class]) : @"无", anno ? anno.windowLevel : 0,
     anno ? (int)anno.isKeyWindow : 0];
    [s appendFormat:@"输入框=%@\n", S3DescribeInput(input)];
    [s appendFormat:@"键盘通知=%d %@\n", (int)gKbSeen, kbDump ? kbDump : @""];
    [s appendFormat:@"硬件键盘=%ld\n", (long)S3HardwareKeyboardMode()];
    [s appendFormat:@"场景: %@\n", gSceneVerdict];
    [s appendFormat:@"已试: %@\n", gTryDesc];
    [s appendFormat:@"%@\n", verdict];
    [s appendString:@"日志 /var/mobile/Media/S3TextKeyboardFix.log"];
    return s;
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

    // 键盘一出现就收工，不再动任何东西
    if (gKbSeen) {
        S3Log(@"✔ 键盘已确认出现（第 %d 步收工）", step);
        S3Tip(anno, S3StatusLine(vc, @"✔ 键盘已弹出（系统已确认）"), 3.0);
        return;
    }

    switch (step) {
        case 0: {
            gAnnoWin = anno;
            S3Log(@"──── 打开文字面板，开始（来自 %@）", S3SelfShort());
            S3Log(@"场景体检：\n%@", S3ScenesReport());
            gSceneVerdict = S3RepairScene(anno);
            if (anno && !anno.isKeyWindow) [anno makeKeyAndVisible];
            if (input && !input.isFirstResponder) {
                BOOL ok = [input becomeFirstResponder];
                S3Log(@"第0步：输入框抢焦点 -> %d", (int)ok);
            }
            NSMutableArray *tried = [NSMutableArray array];
            if ([gSceneVerdict rangeOfString:@"已补挂"].location != NSNotFound) [tried addObject:@"补场景"];
            gTryDesc = tried.count ? [tried componentsJoinedByString:@"+"] : @"补场景(无缺失)";
            S3Tip(anno, S3StatusLine(vc, @"…正在尝试呼出键盘"), 6.0);
            S3Schedule(vc, step, gen, 0.30);
            break;
        }
        case 1: {
            NSString *dump = nil;
            UIWindow *kb = S3FindKeyboardWindow(&dump);
            S3Log(@"第1步：%@", dump);
            if (kb) {
                S3LowerAnnoUnderKeyboard(anno, kb);
                gTryDesc = [gTryDesc stringByAppendingString:@"+降标注窗口"];
            } else {
                gTryDesc = [gTryDesc stringByAppendingString:@"+未找到键盘窗口"];
            }
            if (input && !input.isFirstResponder) [input becomeFirstResponder];
            S3Schedule(vc, step, gen, 0.60);
            break;
        }
        case 2: {
            NSString *dump = nil;
            UIWindow *kb = S3FindKeyboardWindow(&dump);
            if (kb) {
                S3RaiseKeyboardWindow(anno, kb);
                gTryDesc = [gTryDesc stringByAppendingString:@"+抬键盘窗口"];
            } else if (input) {
                S3AttachAccessory(input);
                [input becomeFirstResponder];
                gTryDesc = [gTryDesc stringByAppendingString:@"+输入附件"];
            }
            S3Schedule(vc, step, gen, 0.60);
            break;
        }
        case 3: {
            if (input) {
                [input reloadInputViews];
                BOOL ok = [input becomeFirstResponder];
                S3Log(@"第3步：reloadInputViews + 重新抢焦点 -> %d", (int)ok);
            }
            S3Schedule(vc, step, gen, 0.60);
            break;
        }
        default: {
            // 全部落空：回滚层级（判定那张图留在屏幕上给作者），gVC 不动，免得兜底定时器把图收走
            S3Log(@"✘ 两秒内没有任何键盘通知（第 %d 步），回滚层级", step);
            S3Log(@"最终场景清单：\n%@", S3ScenesReport());
            S3RollbackLevels();
            NSString *verdict = @"✘ 键盘没弹\n系统全程没发过键盘通知 →\n不是被窗口压住，是这个窗口拿不到键盘。\n请把这张图发给作者。";
            gTryDesc = [gTryDesc stringByAppendingString:@"+全落空"];
            UIWindow *show = gAnnoWin ? gAnnoWin : anno;
            if (show) S3Tip(show, S3StatusLine(vc, verdict), 0);
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
    if (gVC == vc && (now - gStartAt) < 2.0) return;   // 同一面板 2 秒内只启动一次，避免双重阶梯
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
            // 抢焦点之前先把场景补好 —— 顺序很关键
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
            S3Start(self);      // 双保险：ensureTextKeyboard 万一没被调，这里一定触发
        });
        method_setImplementation(mAppear, newAppear);
        S3Log(@"已 hook viewDidAppear:");
    }

    Method mDis = class_getInstanceMethod(cls, NSSelectorFromString(@"viewDidDisappear:"));
    if (mDis) {
        IMP origDis = method_getImplementation(mDis);
        IMP newDis = imp_implementationWithBlock(^(UIViewController *self, BOOL animated) {
            if (origDis) ((void (*)(id, SEL, BOOL))origDis)(self, @selector(viewDidDisappear:), animated);
            S3Log(@"面板消失 -> 回滚");
            S3TipHideNow();
            S3Restore();
        });
        method_setImplementation(mDis, newDis);
        S3Log(@"已 hook viewDidDisappear:");
    }

    gHookState = 1;
    S3Log(@"hook 安装完成（本份来自 %@）", S3SelfPath());
}

__attribute__((constructor)) static void S3Init(void) {
    S3Log(@"===== v%@ 已加载 pid=%d =====", kS3Ver, getpid());
    S3Log(@"自身路径: %@", S3SelfPath());
    uint32_t n = _dyld_image_count();
    int fix = 0;
    NSMutableString *imgs = [NSMutableString string];
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (!nm) continue;
        NSString *f = [NSString stringWithUTF8String:nm];
        if (!f) continue;
        if ([f containsString:@"S3TextKeyboardFix"] || [f containsString:@"biaoji"]) {
            if ([f containsString:@"S3TextKeyboardFix.dylib"]) fix++;
            [imgs appendFormat:@"\n      %@", f];
        }
    }
    S3Log(@"进程内相关镜像（补丁 %d 份，>1 就是重复注入）:%@", fix, imgs);

    dispatch_async(dispatch_get_main_queue(), ^{
        S3InstallHook();

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        // block 版观察者返回的 token 必须自己持有，否则立刻释放、回调根本不触发
        static NSMutableArray *tokens = nil;
        tokens = [NSMutableArray array];
        [tokens addObject:[nc addObserverForName:UIKeyboardWillShowNotification
                                          object:nil queue:[NSOperationQueue mainQueue]
                                      usingBlock:^(NSNotification *note) {
            gKbSeen = YES;
            S3Log(@"UIKeyboardWillShow frame=%@", note.userInfo[UIKeyboardFrameEndUserInfoKey]);
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

        // 兜底：面板被直接销毁时回滚并收掉提示
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            if (!gVC && !gAnnoLowered && !gKbWinRaised) return;
            UIViewController *vc = gVC;
            if (!vc || vc.isBeingDismissed || !vc.isViewLoaded || !vc.view.window) {
                S3Log(@"清理：文字面板已消失");
                S3TipHideNow();
                S3Restore();
            }
        }];
    });
}
