#import "NVBCommon.h"
#import <PhotosUI/PhotosUI.h>
#import <CoreFoundation/CFNotificationCenter.h>

// ============================================================
// 设置面板 (NVBPrefs.bundle, 仅加载进 系统"设置"/OneSettings)
//  - 总开关 + 7 类界面独立配置
//  - 每个功能分区内置"选择素材"(相册导入/选用/删除)
//  - 所有滑条带名称与实时数值
// ============================================================

#pragma mark - 素材管理页 (相册导入 / 选用 / 删除)

@interface NVBMaterialListController : UITableViewController <PHPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *contextKey;   // 目标界面
@property (nonatomic, copy) NSString *contextTitle; // 目标界面显示名
@end

@implementation NVBMaterialListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择素材";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(importFromLibrary)];
    self.tableView.backgroundColor = [UIColor systemBackgroundColor];
}

- (NSString *)footerText {
    return [NSString stringWithFormat:@"为「%@」管理背景素材：点按素材可选用或删除，打勾为当前使用。", self.contextTitle ?: @""];
}

- (NSInteger)materialCount {
    return (NSInteger)[[NVBManager shared] materialLibrary].count;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 1; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self materialCount] + 1; // +1: 从相册导入
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [self footerText];
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
        [[NVBManager shared] playerForContext:self.contextKey forceRebuild:YES];
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
        if (!url || error) return; // 临时文件回调结束后即删, 失败只能重选
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

#pragma mark - 主设置页 (总开关 + 7 类界面配置)

@interface NVBSettingsListController : UITableViewController
@end

@implementation NVBSettingsListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"备忘录视频背景";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self action:@selector(showHelp)];
    self.tableView.backgroundColor = [UIColor systemBackgroundColor];
}

- (void)showHelp {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"备忘录视频背景"
                         message:@"1. 打开上方总开关\n2. 在各界面分区打开「开启背景」\n3. 点「选择素材」从相册导入视频\n4. 用滑条调节模糊度 / 不透明度 / 音量\n\n改动即时生效，无需重启备忘录。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1 + NVBContextDefinitions().count; // 0: 总开关, 1..7: 各界面
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"总开关";
    return NVBContextDefinitions()[section - 1][1];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"关闭后所有界面背景停用。";
    return NVBContextDefinitions()[section - 1][2];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (section == 0) ? 1 : 5;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return 44.0;
    return (indexPath.row >= 2) ? 64.0 : 44.0;
}

- (NSString *)contextKeyForSection:(NSInteger)section {
    NSArray<NSArray<NSString *> *> *defs = NVBContextDefinitions();
    if (section < 1 || section > (NSInteger)defs.count) return NVBContextNote;
    return defs[section - 1][0];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) { // 总开关
        UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"nvb-master"];
        if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"nvb-master"];
        c.textLabel.text = @"启用视频背景";
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [[NVBManager shared] masterEnabled];
        [sw addTarget:self action:@selector(masterChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        return c;
    }

    NSString *ctx = [self contextKeyForSection:indexPath.section];
    NSDictionary *s = [[NVBManager shared] settingsForContext:ctx];

    switch (indexPath.row) {
        case 0: { // 开启背景
            UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"nvb-toggle"];
            if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"nvb-toggle"];
            c.textLabel.text = @"开启背景";
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on  = [s[@"enabled"] boolValue];
            sw.tag = indexPath.section;
            [sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
        case 1: { // 选择素材 (每个功能分区内置)
            UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"nvb-media"];
            if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"nvb-media"];
            c.textLabel.text = @"选择素材";
            NSString *name = s[@"materialName"];
            c.detailTextLabel.text = name.length ? name : @"未选择(点此导入)";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        default: { // 2 模糊度 / 3 不透明度 / 4 音量
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            c.selectionStyle = UITableViewCellSelectionStyleNone;

            NSString *title; float value; float max; NSString *fmt;
            if (indexPath.row == 2)      { title = @"模糊度";   value = [s[@"blur"]   floatValue]; max = 30; fmt = @"%.0f";   }
            else if (indexPath.row == 3) { title = @"不透明度"; value = [s[@"alpha"]  floatValue]; max = 1;  fmt = @"%.2f";   }
            else                         { title = @"音量";     value = [s[@"volume"] floatValue]; max = 1;  fmt = @"%.0f%%"; }

            UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, 160, 20)];
            lb.font = [UIFont systemFontOfSize:15];
            lb.text = title;
            lb.tag = 998;
            [c.contentView addSubview:lb];

            UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(c.contentView.bounds.size.width - 90, 8, 74, 20)];
            val.font = [UIFont systemFontOfSize:13];
            val.textColor = [UIColor secondaryLabelColor];
            val.textAlignment = NSTextAlignmentRight;
            val.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            val.tag = 999;
            val.text = (indexPath.row == 4)
                ? [NSString stringWithFormat:fmt, value * 100]
                : [NSString stringWithFormat:fmt, value];
            [c.contentView addSubview:val];

            UISlider *sl = [[UISlider alloc] initWithFrame:CGRectMake(16, 32, c.contentView.bounds.size.width - 32, 30)];
            sl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            sl.minimumValue = 0;
            sl.maximumValue = max;
            sl.value = value;
            sl.tag = indexPath.section * 10 + indexPath.row;
            [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
            [c.contentView addSubview:sl];
            return c;
        }
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 || indexPath.row != 1) return;
    NVBMaterialListController *ml = [[NVBMaterialListController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    ml.contextKey   = [self contextKeyForSection:indexPath.section];
    ml.contextTitle = NVBContextDefinitions()[indexPath.section - 1][1];
    UINavigationController *nav = self.navigationController ?: self.parentViewController.navigationController;
    [nav pushViewController:ml animated:YES];
}

#pragma mark 控件回调

- (void)masterChanged:(UISwitch *)sw {
    NVBManager *mgr = [NVBManager shared];
    [[mgr prefs] setBool:sw.on forKey:@"master_enabled"];
    [[mgr prefs] synchronize];
    [mgr postChangeNotification];
    [mgr refreshVisibleBackgrounds];
}

- (void)toggleChanged:(UISwitch *)sw {
    NSString *ctx = [self contextKeyForSection:sw.tag];
    NSMutableDictionary *s = [[NVBManager shared] settingsForContext:ctx];
    s[@"enabled"] = @(sw.on);
    [[NVBManager shared] saveSettings:s forContext:ctx];
    [[NVBManager shared] refreshVisibleBackgrounds];
}

- (void)sliderChanged:(UISlider *)sl {
    NSInteger section = sl.tag / 10;
    NSInteger row = sl.tag % 10;
    NSString *ctx = [self contextKeyForSection:section];
    NSMutableDictionary *s = [[NVBManager shared] settingsForContext:ctx];

    if (row == 2)      s[@"blur"]   = @(sl.value);
    else if (row == 3) s[@"alpha"]  = @(sl.value);
    else               s[@"volume"] = @(sl.value);

    [[NVBManager shared] saveSettings:s forContext:ctx];
    [[NVBManager shared] refreshVisibleBackgrounds];

    UILabel *val = (UILabel *)[sl.superview viewWithTag:999];
    if (val) {
        if (row == 2)      val.text = [NSString stringWithFormat:@"%.0f", sl.value];
        else if (row == 3) val.text = [NSString stringWithFormat:@"%.2f", sl.value];
        else               val.text = [NSString stringWithFormat:@"%.0f%%", sl.value * 100];
    }
}

@end

#pragma mark - 设置入口 (PSListController, 供 PreferenceLoader/OneSettings 实例化)

// 手工声明, 不依赖 Preferences 头文件 (SDK 未附带)
@interface PSListController : UIViewController
- (NSArray *)specifiers;
@end

@interface NVBPrefsController : PSListController
@end

@implementation NVBPrefsController

- (NSArray *)specifiers {
    return @[]; // 内容由内嵌面板提供, 不使用 specifier 表
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"备忘录视频背景";

    NVBSettingsListController *list = [[NVBSettingsListController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    [self addChildViewController:list];
    list.view.frame = self.view.bounds;
    list.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:list.view];
    [list didMoveToParentViewController:self];
}

@end
