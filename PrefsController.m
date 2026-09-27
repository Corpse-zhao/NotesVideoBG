#import "NVBCommon.h"
#import <dlfcn.h>
#import <objc/runtime.h>

// 注意: 本文件严禁 #import <PhotosUI/PhotosUI.h> 或任何静态 PHPicker 符号引用!
// 老工具链生成的 PHPickerViewControllerDelegate 协议元数据会在类注册 (readClass) 时
// 导致宿主进程崩溃 (v2.0 备忘录闪退 / v2.1 设置闪退均由此引起)。
// 因此 PHPicker 一律通过 dlopen + NSClassFromString + objc_msgSend 运行时调用,
// 代理回调只实现同名选择器, 不声明协议。

// ============================================================
// 设置面板 (NVBPrefs.bundle, 仅加载进 系统"设置"/OneSettings)
// 作者: 板栗仁
//
// v2.2 重构: 采用社区最经典的声明式方案
//  - 主面板: 标准 PSListController + Root.plist
//    (PSSwitchCell / PSSliderCell 原生控件, 直写 NSUserDefaults,
//     改动后 PostNotification 通知备忘录实时刷新)
//  - "选择素材": PSLinkCell detail 推入自管理页面 (相册导入/选用/删除)
//  - 不再手工模拟 PSListController 内部行为, 彻底规避设置闪退
// ============================================================

// 手工声明 Preferences 私有类 (SDK 未附带头文件)
@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
@end

@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)property forKey:(NSString *)key;
@end

#pragma mark - 设备端调试日志 (多通道必达: 偏好文件 + 多路径)

static void NVBLogRaw(NSString *line) {
    // 通道 1: NSUserDefaults 套件 (PSSwitchCell 同款写入方式, 设置进程必然可写)
    // Filza 查看: /var/mobile/Library/Preferences/com.nvb.notesvideobg.plist -> nvb_debug_log
    @try {
        NSUserDefaults *ud = [[NSUserDefaults alloc] initWithSuiteName:@"com.nvb.notesvideobg"];
        NSString *old = [ud stringForKey:@"nvb_debug_log"] ?: @"";
        NSString *nu = [old stringByAppendingString:line];
        if (nu.length > 12000) nu = [nu substringFromIndex:nu.length - 12000];
        [ud setObject:nu forKey:@"nvb_debug_log"];
        [ud synchronize];
    } @catch (NSException *e) {}
    // 通道 2/3: 常见可写目录
    for (NSString *p in (@[@"/var/mobile/Documents/nvb_debug.log",
                           @"/var/mobile/Library/nvb_debug.log"])) {
        FILE *f = fopen(p.UTF8String, "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); }
    }
    FILE *tf2 = fopen([NSTemporaryDirectory() stringByAppendingPathComponent:@"nvb_debug.log"].UTF8String, "a");
    if (tf2) { fputs(line.UTF8String, tf2); fclose(tf2); }
}

static void NVBLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void NVBLog(NSString *fmt, ...) {
    @try {
        va_list args;
        va_start(args, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                          [NSDate date], msg];
        NVBLogRaw(line);
    } @catch (NSException *e) {}
}

// bundle 被 dlopen 的第一时刻
__attribute__((constructor)) static void NVBPrefsBundleLoaded(void) {
    NVBLogRaw([NSString stringWithFormat:@"[%@] === NVBPrefs bundle loaded (v2.9) ===\n", [NSDate date]]);
}

#pragma mark - 素材管理页 (相册导入 / 选用 / 删除)

@interface NVBMaterialListController : UITableViewController
@property (nonatomic, copy) NSString *contextKey;   // 目标界面
@property (nonatomic, copy) NSString *contextTitle; // 目标界面显示名
- (instancetype)initWithSpecifier:(id)spec;         // PS detail 推入调用
@end

@implementation NVBMaterialListController

// PS 推入 detail 控制器时使用 initWithSpecifier:, 从 specifier 属性取目标界面
- (instancetype)initWithSpecifier:(PSSpecifier *)spec {
    NVBLog(@"MaterialList initWithSpecifier: %@", spec);
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _contextKey    = NVBContextNote;
        _contextTitle  = @"";
        @try {
            NSString *k = [spec propertyForKey:@"context"];
            if (k.length) _contextKey = [k copy];
            NSString *t = [spec propertyForKey:@"contextTitle"];
            if (t.length) _contextTitle = [t copy];
        } @catch (NSException *e) {}
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择素材";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(importFromLibrary)];
    self.tableView.backgroundColor = [UIColor systemBackgroundColor];
}

- (NSInteger)materialCount {
    return (NSInteger)[[NVBManager shared] materialLibrary].count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self materialCount] + 1; // +1: 从相册导入
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"为「%@」管理背景素材：点按素材可选用或删除，打勾为当前使用。",
            self.contextTitle ?: @""];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSDictionary *> *lib = [[NVBManager shared] materialLibrary];
    NSDictionary *s = [[NVBManager shared] settingsForContext:self.contextKey];

    if (indexPath.row < (NSInteger)lib.count) { // 素材行
        UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"nvb-mat"];
        if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"nvb-mat"];
        NSDictionary *m = lib[indexPath.row];
        c.textLabel.text = [NSString stringWithFormat:@"%lu. %@", (unsigned long)indexPath.row + 1, m[@"name"]];
        c.detailTextLabel.text = @"视频素材";
        c.accessoryType = [s[@"materialId"] isEqualToString:m[@"id"]]
                          ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return c;
    }
    // 导入行
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"nvb-import"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"nvb-import"];
    c.textLabel.text = @"＋ 从相册导入视频素材";
    c.textLabel.textColor = [UIColor systemBlueColor];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= [self materialCount]) {
        [self importFromLibrary];
        return;
    }
    // 点按素材: 选用 / 删除 / 取消
    NSArray<NSDictionary *> *lib = [[NVBManager shared] materialLibrary];
    NSDictionary *m = lib[indexPath.row];
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:m[@"name"]
                         message:@"选择操作"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"选用此素材" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSMutableDictionary *s = [[NVBManager shared] settingsForContext:self.contextKey];
        s[@"materialId"] = m[@"id"];
        [[NVBManager shared] saveSettings:s forContext:self.contextKey];
        [[NVBManager shared] refreshVisibleBackgrounds];
        [self.tableView reloadData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"删除此素材" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [[NVBManager shared] removeMaterialWithId:m[@"id"]];
        [[NVBManager shared] refreshVisibleBackgrounds];
        [self.tableView reloadData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// 相册导入 (PHPicker 运行时调用, 不静态引用 PhotosUI; 无需相册权限)
- (void)importFromLibrary {
    // 设置进程默认不加载 PhotosUI, 先 dlopen 确保可用
    void *h = dlopen("/System/Library/Frameworks/PhotosUI.framework/PhotosUI", RTLD_LAZY);
    Class pickerCls = h ? NSClassFromString(@"PHPickerViewController") : nil;
    Class cfgCls    = h ? NSClassFromString(@"PHPickerConfiguration") : nil;
    if (!pickerCls || !cfgCls) {
        UIAlertController *ac = [UIAlertController
            alertControllerWithTitle:@"暂不可用"
                             message:@"当前环境无法调起相册选择器"
                      preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:ac animated:YES completion:nil];
        return;
    }

    id cfg = [[cfgCls alloc] init];
    Class filterCls = NSClassFromString(@"PHPickerFilter");
    if (filterCls) {
        id filter = ((id (*)(id, SEL))objc_msgSend)(filterCls, @selector(videosFilter));
        ((void (*)(id, SEL, id))objc_msgSend)(cfg, @selector(setFilter:), filter);
    }
    ((void (*)(id, SEL, long))objc_msgSend)(cfg, @selector(setSelectionLimit:), (long)1);

    id pc = ((id (*)(id, SEL))objc_msgSend)(pickerCls, @selector(alloc));
    pc    = ((id (*)(id, SEL, id))objc_msgSend)(pc, @selector(initWithConfiguration:), cfg);
    ((void (*)(id, SEL, id))objc_msgSend)(pc, @selector(setDelegate:), self);
    [self presentViewController:pc animated:YES completion:nil];
}

// PHPicker 代理回调 (运行时实现选择器, 不声明协议)
- (void)picker:(id)picker didFinishPicking:(NSArray *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    id res = results.firstObject;
    NSItemProvider *provider = ((NSItemProvider *(*)(id, SEL))objc_msgSend)(res, @selector(itemProvider));
    __weak typeof(self) wself = self;

    [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
                                    completionHandler:^(NSURL *url, NSError *error) {
        if (!url || error) return;
        NSError *copyError = nil;
        [[NVBManager shared] addMaterialFromFile:url
                                            name:url.lastPathComponent.stringByDeletingPathExtension
                                           error:&copyError];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself) return;
            if (!copyError) {
                [sself.tableView reloadData];
            } else {
                UIAlertController *ac = [UIAlertController
                    alertControllerWithTitle:@"导入失败"
                                     message:(copyError.localizedDescription ?: @"无法复制所选视频")
                              preferredStyle:UIAlertControllerStyleAlert];
                [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                [sself presentViewController:ac animated:YES completion:nil];
            }
        });
    }];
}

@end

#pragma mark - 设置入口 (标准 PSListController + 声明式 Root.plist)

// 拿到 PSListController 的 _specifiers 实例变量 (运行时, 不依赖头文件)
static Ivar NVBSpecifiersIvar(void) {
    static Ivar iv = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        iv = class_getInstanceVariable(objc_getClass("PSListController"), "_specifiers");
    });
    return iv;
}

@interface NVBPrefsController : PSListController
@end

@implementation NVBPrefsController

+ (void)load {
    // 本类随主插件 dylib 注入设置进程后立即记录 (证明注入成功)
    NVBLogRaw([NSString stringWithFormat:@"[%@] +load: NVBPrefsController registered (v3.0, in dylib)\n", [NSDate date]]);
}

// 纯代码构建 specifiers (彻底摆脱 plist 文件与 bundle 加载)
static void NVBSetProp(id spec, NSString *k, id v) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(spec, @selector(setProperty:forKey:), v, k);
}

static id NVBMakeSpec(NSString *label) {
    Class specCls = NSClassFromString(@"PSSpecifier");
    SEL pSel = NSSelectorFromString(@"preferenceSpecifierNamed:target:set:get:detail:cell:edit:");
    if (!specCls || !((BOOL (*)(id, SEL, SEL))objc_msgSend)(specCls, @selector(respondsToSelector:), pSel))
        return nil;
    return ((id (*)(id, SEL, NSString *, id, SEL, SEL, id, long, id))objc_msgSend)(
        specCls, pSel, label, nil, nil, nil, nil, (long)1, nil);
}

static id NVBGroupSpec(NSString *label, NSString *footer) {
    id g = NVBMakeSpec(label);
    if (!g) return nil;
    NVBSetProp(g, @"cell", @"PSGroupCell");
    if (footer) NVBSetProp(g, @"footerText", footer);
    return g;
}

static id NVBSwitchSpec(NSString *label, NSString *key, BOOL def) {
    id s = NVBMakeSpec(label);
    if (!s) return nil;
    NVBSetProp(s, @"cell", @"PSSwitchCell");
    NVBSetProp(s, @"defaults", @"com.nvb.notesvideobg");
    NVBSetProp(s, @"key", key);
    NVBSetProp(s, @"default", @(def));
    NVBSetProp(s, @"PostNotification", @"com.nvb.notesvideobg/prefs.changed");
    NVBSetProp(s, @"set", @"setPreferenceValue:specifier:");
    NVBSetProp(s, @"get", @"readPreferenceValue:");
    return s;
}

static id NVBSliderSpec(NSString *label, NSString *key, double minV, double maxV, double def) {
    id s = NVBMakeSpec(label);
    if (!s) return nil;
    NVBSetProp(s, @"cell", @"PSSliderCell");
    NVBSetProp(s, @"defaults", @"com.nvb.notesvideobg");
    NVBSetProp(s, @"key", key);
    NVBSetProp(s, @"min", @(minV));
    NVBSetProp(s, @"max", @(maxV));
    NVBSetProp(s, @"default", @(def));
    NVBSetProp(s, @"isContinuous", @(YES));
    NVBSetProp(s, @"PostNotification", @"com.nvb.notesvideobg/prefs.changed");
    NVBSetProp(s, @"set", @"setPreferenceValue:specifier:");
    NVBSetProp(s, @"get", @"readPreferenceValue:");
    return s;
}

static id NVBLinkSpec(NSString *label, NSString *detailCls, NSString *ctx, NSString *ctxTitle) {
    id s = NVBMakeSpec(label);
    if (!s) return nil;
    NVBSetProp(s, @"cell", @"PSLinkCell");
    NVBSetProp(s, @"detail", detailCls);
    NVBSetProp(s, @"context", ctx);
    NVBSetProp(s, @"contextTitle", ctxTitle);
    return s;
}

- (NSArray *)NVBBuildSpecifiers {
    NSMutableArray *out_ = [NSMutableArray array];
    id g = NVBGroupSpec(@"总开关",
        @"关闭后所有界面的视频背景立即停用。素材需先在下方各功能的「选择素材」里从相册导入。");
    if (g) [out_ addObject:g];
    id sw = NVBSwitchSpec(@"启用视频背景", @"master_enabled", YES);
    if (sw) [out_ addObject:sw];

    for (NSArray<NSString *> *def in NVBContextDefinitions()) {
        NSString *k = def[0], *title = def[1], *desc = def[2];
        id gg = NVBGroupSpec(title, desc);
        if (gg) [out_ addObject:gg];
        id e = NVBSwitchSpec(@"开启背景", [k stringByAppendingString:@"_enabled"], NO);
        if (e) [out_ addObject:e];
        id l = NVBLinkSpec(@"选择素材", @"NVBMaterialListController", k, title);
        if (l) [out_ addObject:l];
        id b = NVBSliderSpec(@"模糊度", [k stringByAppendingString:@"_blur"], 0, 30, 8);
        if (b) [out_ addObject:b];
        id a = NVBSliderSpec(@"不透明度", [k stringByAppendingString:@"_alpha"], 0, 1, 0.65);
        if (a) [out_ addObject:a];
        id v = NVBSliderSpec(@"音量", [k stringByAppendingString:@"_volume"], 0, 1, 1);
        if (v) [out_ addObject:v];
    }
    NVBLog(@"specifiers built programmatically: %lu", (unsigned long)out_.count);
    return out_;
}

- (NSArray *)specifiers {
    @try {
        Ivar iv = NVBSpecifiersIvar();
        id cur = iv ? object_getIvar(self, iv) : nil;
        if (cur && [cur count] > 0) return cur;

        cur = [self NVBBuildSpecifiers];
        if ([cur count] > 0) {
            if (iv) object_setIvar(self, iv, cur);
            return cur;
        }
        NVBLog(@"specifiers EMPTY -> fallback");
    } @catch (NSException *e) {
        NVBLog(@"specifiers EXCEPTION: %@ / %@", e.name, e.reason);
    }
    return [self NVBFallbackSpecifiers];
}

// 兜底: 至少显示一行错误提示 + 日志路径, 不再白屏
- (NSArray *)NVBFallbackSpecifiers {
    NSMutableArray *out_ = [NSMutableArray array];
    Class specCls = NSClassFromString(@"PSSpecifier");
    if (specCls) {
        id group = ((id (*)(id, SEL, NSString *, id, id, id, id, long, id))objc_msgSend)(
            specCls, @selector(preferenceSpecifierNamed:target:set:get:detail:cell:edit:),
            @"设置加载失败", nil, nil, nil, nil, (long)1 /*PSGroupCell*/, nil);
        if (group) {
            ((void (*)(id, SEL, id, NSString *))objc_msgSend)(
                group, @selector(setProperty:forKey:),
                @"Root.plist 加载失败。请把 /var/mobile/Documents/nvb_debug.log 发给开发者。",
                @"footerText");
            [out_ addObject:group];
        }
    }
    NVBLog(@"fallback specifiers returned (%lu)", (unsigned long)out_.count);
    return out_;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NVBLog(@"PrefsController viewDidLoad, title=%@", self.title);
    @try {
        self.title = @"备忘录视频背景";
    } @catch (NSException *e) {}
}

@end

// 别名类: 若 Preferences 通过 CFBundlePrincipalClass / 类名 "NVBPrefs" 查找
// (theos 生成模板默认把主类名写成 bundle 名), 也能拿到一个可用的控制器。
@interface NVBPrefs : NVBPrefsController
@end
@implementation NVBPrefs
@end
