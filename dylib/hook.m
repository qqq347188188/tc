// hook.m —— 运行时补丁 dylib（通吃版：任意 Unity IL2CPP 游戏）
//
// 编译（macOS runner）：
//   SDK=$(xcrun --sdk iphoneos --show-sdk-path)
//   xcrun --sdk iphoneos clang -arch arm64 -dynamiclib -fobjc-arc -O2 \
//     -isysroot "$SDK" -miphoneos-version-min=14.0 -framework Foundation \
//     -install_name @executable_path/Frameworks/autopatch.dylib \
//     -o autopatch.dylib hook.m
//
// 与「预生成偏移」版本不同，这里不依赖任何偏移：注入后通过 IL2CPP 运行时
// 导出的 API 遍历所有方法，按名字匹配到函数指针，再把开头机器码改成
// 「恒真 / 置空 / 直接返回」，从而让同一个 dylib 通吃任意 Unity 游戏。
//
// 想换目标方法名：在 app bundle 里放一个 autopatch_targets.txt，每行：
//     true:get_IsBoughtFullVersion     # getter 恒真
//     kill:ShowPayWall                 # 入口置空（返回 0）
//     lock:get_IsLocked                # 锁状态恒假
//     ret:set_IsBoughtFullVersion      # 只 ret，禁止写回
// 若文件存在，则只使用文件里的目标（覆盖内置默认）。

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach/vm_page_size.h>
#import <libkern/OSCacheControl.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <stdarg.h>
#import <stdio.h>
#import <string.h>

#define AP_W_TRUE  { 0x52800020U, 0xd65f03c0U, 2 }   // mov w0,#1 ; ret
#define AP_W_KILL  { 0x52800000U, 0xd65f03c0U, 2 }   // mov w0,#0 ; ret
#define AP_W_RET   { 0xd65f03c0U, 0,          1 }    // ret

typedef struct {
    char name[160];
    unsigned int words[2];
    int nwords;
} Target;

static Target gTargets[1024];
static int gNTargets = 0;
static char gLogPath[1024];
static volatile int gApplied = 0;
static id gObserver = nil;

// ---------------- 日志 ----------------
static void APLog(const char *fmt, ...) {
    char msg[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    NSLog(@"[autopatch] %s", msg);
    if (gLogPath[0]) {
        FILE *f = fopen(gLogPath, "a");
        if (f) { fprintf(f, "%s\n", msg); fclose(f); }
    }
}

static void APLogOpen(void) {
    NSString *dir = NSTemporaryDirectory();
    if (!dir) return;
    snprintf(gLogPath, sizeof(gLogPath), "%s/autopatch.log", dir.UTF8String);
    FILE *f = fopen(gLogPath, "w");
    if (f) fclose(f);
}

// ---------------- 写入代码页 ----------------
static int APWriteCode(uintptr_t addr, const unsigned int *words, int n) {
    size_t len = (size_t)n * 4;
    uintptr_t ps = (uintptr_t)vm_page_size;
    if (ps == 0) ps = 0x4000;
    uintptr_t start = addr & ~(ps - 1);
    uintptr_t end = (addr + len + ps - 1) & ~(ps - 1);

    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)start,
                                  (vm_size_t)(end - start), false,
                                  VM_PROT_READ | VM_PROT_WRITE |
                                  VM_PROT_EXECUTE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        if (mprotect((void *)start, (size_t)(end - start),
                     PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
            APLog("开写权限失败 addr=0x%lx kr=%d", (unsigned long)start, (int)kr);
            return 0;
        }
    }
    memcpy((void *)addr, words, len);
    sys_icache_invalidate((void *)addr, len);
    return 1;
}

// ---------------- 目标列表 ----------------
static void APAddTarget(const char *kind, const char *name) {
    if (gNTargets >= 1024 || !name || !*name) return;
    unsigned int w0 = 0, w1 = 0; int n = 0;
    if (0 == strcmp(kind, "true"))            { w0 = 0x52800020U; w1 = 0xd65f03c0U; n = 2; }
    else if (0 == strcmp(kind, "kill") || 0 == strcmp(kind, "lock")) { w0 = 0x52800000U; w1 = 0xd65f03c0U; n = 2; }
    else if (0 == strcmp(kind, "ret"))        { w0 = 0xd65f03c0U; n = 1; }
    else { APLog("未知类型 '%s'（行 %s，已忽略）", kind, name); return; }

    Target *t = &gTargets[gNTargets++];
    strncpy(t->name, name, sizeof(t->name) - 1);
    t->name[sizeof(t->name) - 1] = 0;
    t->words[0] = w0; t->words[1] = w1; t->nwords = n;
}

static void APInitTargets(void) {
    // 内置默认（与 scripts/autopatch.py 保持一致）
    static const struct { const char *k, *n; } builtin[] = {
        {"true", "get_IsBoughtFullVersion"}, {"true", "get_IsFullVersionOwned"},
        {"true", "IsProductActive"}, {"true", "get_IsSubscribed"},
        {"true", "get_HasSubscription"}, {"true", "get_IsPremium"},
        {"true", "get_HasFullVersion"}, {"true", "get_IsPurchased"},
        {"true", "get_HasPurchased"}, {"true", "get_IsUnlocked"},
        {"kill", "ShowPayWall"}, {"kill", "ShowPaywall"},
        {"kill", "ShowPaywallInternal"}, {"kill", "InstantiatePaywall"},
        {"kill", "TryShowPaywallAutomatically"}, {"kill", "TryShowAfterGamePaywall"},
        {"kill", "ShowLaunchPaywallAsync"}, {"kill", "RequestLaunchPaywall"},
        {"kill", "ShowSubscriptionPanel"}, {"kill", "ShowSubscription"},
        {"kill", "OpenPaywall"}, {"kill", "ShowPurchasePanel"},
        {"kill", "OpenSubscription"}, {"kill", "OnPurchaseClicked"},
        {"lock", "get_IsLocked"}, {"lock", "get_IsGameLocked"},
        {"ret",  "set_IsBoughtFullVersion"},
        {NULL, NULL}
    };
    for (int i = 0; builtin[i].n; i++) APAddTarget(builtin[i].k, builtin[i].n);

    // 若 app bundle 内有自定义清单，则只用文件内容
    NSString *p = [[NSBundle mainBundle] pathForResource:@"autopatch_targets" ofType:@"txt"];
    if (p && [[NSFileManager defaultManager] fileExistsAtPath:p]) {
        gNTargets = 0;
        FILE *f = fopen(p.UTF8String, "r");
        if (f) {
            char line[300];
            while (fgets(line, sizeof(line), f)) {
                char *nl = strchr(line, '\n'); if (nl) *nl = 0;
                char *cr = strchr(line, '\r'); if (cr) *cr = 0;
                if (!*line || *line == '#') continue;
                char k[32], nm[256];
                if (sscanf(line, "%31[^:]:%255s", k, nm) == 2)
                    APAddTarget(k, nm);
            }
            fclose(f);
            APLog("已从 bundle 的 autopatch_targets.txt 加载 %d 个目标", gNTargets);
        }
    }
}

// ---------------- 通过 IL2CPP 运行时 API 遍历 ----------------
static void APApplyViaIl2Cpp(void) {
    void *(*il2cpp_domain_get)(void) =
        (void *(*)(void))dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    void *(*il2cpp_domain_get_assemblies)(void *, size_t *) =
        (void *(*)(void *, size_t *))dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
    void *(*il2cpp_assembly_get_image)(void *) =
        (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
    int (*il2cpp_image_get_class_count)(void *) =
        (int (*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_image_get_class_count");
    void *(*il2cpp_image_get_class)(void *, int) =
        (void *(*)(void *, int))dlsym(RTLD_DEFAULT, "il2cpp_image_get_class");
    void *(*il2cpp_class_get_methods)(void *, void **) =
        (void *(*)(void *, void **))dlsym(RTLD_DEFAULT, "il2cpp_class_get_methods");
    const char *(*il2cpp_method_get_name)(void *) =
        (const char *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_method_get_name");
    void *(*il2cpp_method_get_pointer)(void *) =
        (void *(*)(void *))dlsym(RTLD_DEFAULT, "il2cpp_method_get_pointer");

    if (!il2cpp_domain_get || !il2cpp_domain_get_assemblies ||
        !il2cpp_assembly_get_image || !il2cpp_image_get_class_count ||
        !il2cpp_image_get_class || !il2cpp_class_get_methods ||
        !il2cpp_method_get_name || !il2cpp_method_get_pointer) {
        APLog("未找到 IL2CPP 运行时符号，本 dylib 需要游戏导出 il2cpp_* API");
        return;
    }

    void *domain = il2cpp_domain_get();
    if (!domain) { APLog("il2cpp_domain_get() 返回 NULL（il2cpp 尚未初始化）"); return; }

    size_t nasm = 0;
    void **asms = (void **)il2cpp_domain_get_assemblies(domain, &nasm);
    if (!asms || nasm == 0) { APLog("没有可用的 assembly"); return; }

    int patched = 0, scanned = 0;
    for (size_t a = 0; a < nasm; a++) {
        void *image = il2cpp_assembly_get_image(asms[a]);
        if (!image) continue;
        int cc = il2cpp_image_get_class_count(image);
        for (int c = 0; c < cc; c++) {
            void *klass = il2cpp_image_get_class(image, c);
            if (!klass) continue;
            void *iter = NULL;
            void *m;
            while ((m = il2cpp_class_get_methods(klass, &iter))) {
                const char *nm = il2cpp_method_get_name(m);
                if (!nm) continue;
                for (int t = 0; t < gNTargets; t++) {
                    if (strcmp(nm, gTargets[t].name) != 0) continue;
                    scanned++;
                    void *p = il2cpp_method_get_pointer(m);
                    if (!p) { APLog("跳过 %s（无函数指针）", nm); continue; }
                    if (APWriteCode((uintptr_t)p, gTargets[t].words, gTargets[t].nwords)) {
                        patched++;
                        APLog("已补丁 %s @ %p", nm, p);
                    } else {
                        APLog("写入失败 %s @ %p", nm, p);
                    }
                }
            }
        }
    }
    APLog("完成：扫描命中 %d 次，成功补丁 %d 处（目标总数 %d）",
          scanned, patched, gNTargets);
}

// ---------------- 触发 ----------------
static void APApplyAll(void) {
    if (gApplied) return;
    gApplied = 1;
    APInitTargets();
    APLog("开始按 %d 个目标名遍历 IL2CPP 方法表", gNTargets);
    APApplyViaIl2Cpp();
}

__attribute__((constructor))
static void APInit(void) {
    APLogOpen();
    APLog("autopatch 通吃版 dylib 已加载（IL2CPP API 遍历）");

    // il2cpp 必须在 app 启动后才会初始化，等 UIApplication 完成启动再动手
    // 注意：直接用字符串字面量，避免链接 UIKit 框架（通知名字符串与 UIKit 常量一致）
    gObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:@"UIApplicationDidFinishLaunchingNotification"
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) { (void)note; APApplyAll(); }];

    // 兜底：若通知未触发（极少数非标准入口），3 秒后强制执行
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3LL * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ APApplyAll(); });
}
