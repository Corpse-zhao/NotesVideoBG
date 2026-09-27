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
@end

#pragma mark - 设备端调试日志 (Filza 可直接查看)

static NSString *NVBLogPath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if ([[NSFileManager defaultManager] isWritableFileAtPath:@"/var/mobile/Documents"])
            p = @"/var/mobile/Documents/nvb_debug.log";
        else
            p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nvb_debug.log"];
    });
    return p;
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
        FILE *f = fopen(NVBLogPath().UTF8String, "a");
        if (f) { fputs(line.UTF8String, f); fclose(f); }
    } @catch (NSException *e) {}
}

// bundle 被 dlopen 的第一时刻
__attribute__((constructor)) static void NVBPrefsBundleLoaded(void) {
    NVBLog(@"=== NVBPrefs bundle loaded (v2.8) ===");
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

// 经典写法: 首次调用时从 Root.plist 加载并缓存到 _specifiers
- (NSArray *)specifiers {
    @try {
        Ivar iv = NVBSpecifiersIvar();
        id cur = iv ? object_getIvar(self, iv) : nil;
        if (cur) return cur;

        cur = [self loadSpecifiersFromPlistName:@"Root" target:self];
        NSUInteger n = [cur count];
        NVBLog(@"specifiers loaded: %lu entries", (unsigned long)n);
        if (n > 0) {
            if (iv) object_setIvar(self, iv, cur);
            return cur;
        }
        NVBLog(@"specifiers EMPTY -> fallback (Root.plist 未找到或解析为空)");
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
