#import "NVBCommon.h"
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>

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

#pragma mark - 素材管理页 (相册导入 / 选用 / 删除)

@interface NVBMaterialListController : UITableViewController <PHPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *contextKey;   // 目标界面
@property (nonatomic, copy) NSString *contextTitle; // 目标界面显示名
- (instancetype)initWithSpecifier:(id)spec;         // PS detail 推入调用
@end

@implementation NVBMaterialListController

// PS 推入 detail 控制器时使用 initWithSpecifier:, 从 specifier 属性取目标界面
- (instancetype)initWithSpecifier:(PSSpecifier *)spec {
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

// 相册导入 (PHPicker, 无需相册权限)
- (void)importFromLibrary {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter videosFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *pc = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    pc.delegate = self;
    [self presentViewController:pc animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    PHPickerResult *res = results.firstObject;
    NSItemProvider *provider = res.itemProvider;
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
    Ivar iv = NVBSpecifiersIvar();
    if (iv) {
        id cur = object_getIvar(self, iv);
        if (cur) return cur;
        @try {
            cur = [self loadSpecifiersFromPlistName:@"Root" target:self];
            if (cur) object_setIvar(self, iv, cur);
            return cur ?: @[];
        } @catch (NSException *e) {
            return @[];
        }
    }
    return [self loadSpecifiersFromPlistName:@"Root" target:self] ?: @[];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    @try {
        self.title = @"备忘录视频背景";
    } @catch (NSException *e) {}
}

@end
