#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// ============================================================
// NotesVideoBG - 苹果备忘录视频背景插件 (rootless / iOS 16.x)
//
// 功能:
//  - 正文/编辑页、文件夹、笔记列表、画廊、搜索、最近删除 六类
//    独立视频背景 + 内部浏览默认背景兜底
//  - 视频尺寸自适应 (AspectFill)
//  - 模糊度 / 不透明度 / 音量 可调
//  - 插件内直接从相册上传素材 (PHPicker, 无需相册权限)
// ============================================================

#define NVB_SUITE @"com.nvb.notesvideobg"
#define NVB_MEDIA_DIR_NAME @"NVBMedia"

static NSString * const NVBContextNote      = @"note";        // 正文/编辑页
static NSString * const NVBContextFolder    = @"folder";      // 文件夹
static NSString * const NVBContextNotesList = @"notesList";   // 笔记列表
static NSString * const NVBContextGallery   = @"gallery";     // 画廊
static NSString * const NVBContextSearch    = @"search";      // 搜索
static NSString * const NVBContextRecent    = @"recent";      // 最近删除
static NSString * const NVBContextInternal  = @"internal";    // 内部浏览默认背景(兜底)

static char NVBBGKey; // VC 关联的背景视图

@class NVBManager;

// 前置声明
@interface NVBVideoBackgroundView : UIView
@property (nonatomic, copy) NSString *contextKey;
- (instancetype)initWithFrame:(CGRect)frame contextKey:(NSString *)key;
- (void)configure;
@end

@interface NVBSettingsListController : UITableViewController
@end

#pragma mark - 工具函数

// 高斯模糊 CAFilter (私有, iOS 全系统可用), 实现可调模糊度
static id NVBBlurFilter(CGFloat radius) {
    Class cls = objc_getClass("CAFilter");
    SEL sel = NSSelectorFromString(@"filterWithName:");
    if (!cls || ![(id)cls respondsToSelector:sel]) return nil;
    id filter = ((id (*)(id, SEL, id))objc_msgSend)((id)cls, sel, @"gaussianBlur");
    if (filter) {
        [filter setValue:@(radius) forKey:@"inputRadius"];
        // 模糊边缘不透明, 避免视频边缘发白
        if ([filter respondsToSelector:@selector(setInputOpaqueness:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(filter, @selector(setInputOpaqueness:), YES);
        }
    }
    return filter;
}

// 取当前栈顶 VC, 用于弹出设置页
static UIViewController *NVBTopViewController(void) {
    UIViewController *root = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { root = w.rootViewController; break; }
            }
        }
    }
    if (!root) root = UIApplication.sharedApplication.keyWindow.rootViewController;
    if (!root) return nil;
    while (root.presentedViewController) root = root.presentedViewController;
    while ([root isKindOfClass:[UINavigationController class]]) {
        UIViewController *top = ((UINavigationController *)root).topViewController;
        if (!top || top == root) break;
        root = top;
        if (root.presentedViewController) root = root.presentedViewController;
    }
    return root;
}

// 类名 -> 上下文映射：备忘录为私有框架(IC* 前缀)，按关键词识别各类页面
// 注意：命中顺序很重要，先排除精确类名，再按特征关键词匹配
static NSString *NVBContextForClassName(NSString *name) {
    if (!name || ![name hasPrefix:@"IC"]) return nil;
    // 精确类名：由专用 Hook 负责，兜底不再处理
    if ([name isEqualToString:@"ICNoteBodyViewController"] ||
        [name isEqualToString:@"ICNoteEditViewController"] ||
        [name isEqualToString:@"ICFolderViewController"]) return nil;
    if ([name isEqualToString:@"ICSettingsViewController"]) return nil;
    // 画廊 / 搜索 / 最近删除 (关键词在前，避免被通用 Note 规则误吞)
    if ([name containsString:@"Gallery"])          return NVBContextGallery;
    if ([name containsString:@"Search"])           return NVBContextSearch;
    if ([name containsString:@"RecentlyDeleted"] ||
        [name containsString:@"Trash"])            return NVBContextRecent;
    // 笔记列表：ICNotesViewController / *NoteList* 等 (Body/Edit 已在上面排除)
    if ([name containsString:@"NotesView"] ||
        [name containsString:@"NoteList"] ||
        [name containsString:@"Note"])             return NVBContextNotesList;
    return NVBContextInternal;
}

#pragma mark - 设置/播放管理器

@interface NVBManager : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVQueuePlayer *> *players;
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVPlayerLooper *> *loopers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *playerPaths;
+ (instancetype)shared;
- (NSUserDefaults *)prefs;
- (NSMutableDictionary *)settingsForContext:(NSString *)ctx;
- (void)saveSettings:(NSDictionary *)s forContext:(NSString *)ctx;
- (NSString *)mediaDirectory;
- (AVQueuePlayer *)playerForContext:(NSString *)ctx forceRebuild:(BOOL)force;
- (void)applyToViewController:(UIViewController *)vc context:(NSString *)ctx;
- (void)refreshVisibleBackgrounds;
- (void)openSettings:(id)sender;
@end

@implementation NVBManager

+ (instancetype)shared {
    static NVBManager *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [self new]; });
    return m;
}

- (instancetype)init {
    if ((self = [super init])) {
        _players     = [NSMutableDictionary new];
        _loopers     = [NSMutableDictionary new];
        _playerPaths = [NSMutableDictionary new];
    }
    return self;
}

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:NVB_SUITE];
}

- (NSDictionary *)defaultsForContext:(NSString *)ctx {
    return @{ @"enabled": @NO,    // 页开开关
              @"path":    @"",    // 已选素材路径
              @"blur":    @8.0,   // 模糊度 0-30
              @"alpha":   @0.65,  // 不透明度 0-1
              @"volume":  @1.0 }; // 音量 0-1
}

- (NSMutableDictionary *)settingsForContext:(NSString *)ctx {
    NSDictionary *stored = [[self prefs] dictionaryForKey:ctx] ?: @{};
    NSMutableDictionary *s = [[self defaultsForContext:ctx] mutableCopy];
    [s addEntriesFromDictionary:stored];
    return s;
}

- (void)saveSettings:(NSDictionary *)s forContext:(NSString *)ctx {
    [[self prefs] setObject:s forKey:ctx];
    [[self prefs] synchronize];
}

// 素材存放目录: 备忘录沙盒 Documents/NVBMedia (进程内读取绝对可靠)
- (NSString *)mediaDirectory {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/" NVB_MEDIA_DIR_NAME];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

// 每个 context 一个 AVQueuePlayer + 无缝循环 (AVPlayerLooper)
- (AVQueuePlayer *)playerForContext:(NSString *)ctx forceRebuild:(BOOL)force {
    NSDictionary *s = [self settingsForContext:ctx];
    NSString *path = s[@"path"];
    if (path.length == 0) return nil;

    AVQueuePlayer *p = self.players[ctx];
    if (p && !force && [self.playerPaths[ctx] isEqualToString:path]) return p;

    [self.loopers[ctx] disableLooping];
    [p pause];
    [p removeAllItems];
    [self.players removeObjectForKey:ctx];
    [self.loopers removeObjectForKey:ctx];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    p = [AVQueuePlayer queuePlayerWithItems:@[item]];
    self.players[ctx]     = p;
    self.playerPaths[ctx] = path;
    self.loopers[ctx]     = [[AVPlayerLooper alloc] initWithPlayer:p templateItem:item];
    p.volume = [s[@"volume"] doubleValue];
    p.muted  = ([s[@"volume"] doubleValue] <= 0.001);
    [p play];
    return p;
}

// 把背景应用到某个 VC (幂等, 可反复调用以刷新配置)
- (void)applyToViewController:(UIViewController *)vc context:(NSString *)ctx {
    if (!vc.isViewLoaded || !vc.view) return;
    if ([vc isKindOfClass:NSClassFromString(@"NVBSettingsListController")]) return;
    if ([vc isKindOfClass:[PHPickerViewController class]]) return;

    NSDictionary *s = [self settingsForContext:ctx];
    BOOL on = [s[@"enabled"] boolValue] && [s[@"path"] length] > 0;

    NVBVideoBackgroundView *bg = objc_getAssociatedObject(vc, &NVBBGKey);
    if (!on) {
        if (bg) {
            [bg removeFromSuperview];
            objc_setAssociatedObject(vc, &NVBBGKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    if (!bg) {
        bg = [[NVBVideoBackgroundView alloc] initWithFrame:vc.view.bounds contextKey:ctx];
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [vc.view insertSubview:bg atIndex:0];
        objc_setAssociatedObject(vc, &NVBBGKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (![bg.contextKey isEqualToString:ctx]) {
        // 同一 VC 切换了模式 (如画廊/列表切换)，按新上下文重建背景
        [bg removeFromSuperview];
        bg = [[NVBVideoBackgroundView alloc] initWithFrame:vc.view.bounds contextKey:ctx];
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [vc.view insertSubview:bg atIndex:0];
        objc_setAssociatedObject(vc, &NVBBGKey, bg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [bg configure];

    vc.view.backgroundColor = [UIColor clearColor];
    [self clearBackgroundsOfView:vc.view depth:0];
}

// 递归清透明: 表格/集合/文本/单元格 背景设为透明, 让视频透出来
- (void)clearBackgroundsOfView:(UIView *)view depth:(NSInteger)depth {
    if (depth > 4) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UILabel class]] || [sub isKindOfClass:[UIButton class]]) continue;
        if ([sub isKindOfClass:[UIScrollView class]] ||
            [sub isKindOfClass:[UITextView class]]  ||
            [sub isKindOfClass:[UITableViewCell class]]) {
            sub.backgroundColor = [UIColor clearColor];
        }
        [self clearBackgroundsOfView:sub depth:depth + 1];
    }
    if ([view isKindOfClass:[UIScrollView class]] || [view isKindOfClass:[UITextView class]]) {
        view.backgroundColor = [UIColor clearColor];
    }
}

// 设置实时生效: 遍历窗口里所有背景视图重新 configure
- (void)refreshVisibleBackgrounds {
    NSArray<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) [self refreshInView:w];
    }
    NSArray<UIWindow *> *legacy = UIApplication.sharedApplication.windows;
    for (UIWindow *w in legacy) [self refreshInView:w];
}

- (void)refreshInView:(UIView *)view {
    if ([view isKindOfClass:[NVBVideoBackgroundView class]]) {
        [(NVBVideoBackgroundView *)view configure];
        return;
    }
    for (UIView *sub in view.subviews) [self refreshInView:sub];
}

// 设置页入口
- (void)openSettings:(id)sender {
    if (objc_getAssociatedObject(self, &NVBBGKey)) {} // no-op, 防 unused 警告
    UIViewController *host = NVBTopViewController();
    if (!host) return;
    NVBSettingsListController *list = [[NVBSettingsListController alloc] initWithStyle:UITableViewStyleInsettedGrouped];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:list];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [host presentViewController:nav animated:YES completion:nil];
}

@end

#pragma mark - 视频背景视图

@implementation NVBVideoBackgroundView

- (instancetype)initWithFrame:(CGRect)frame contextKey:(NSString *)key {
    if ((self = [super initWithFrame:frame])) {
        _contextKey = [key copy];
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO; // 不拦截触摸
        CALayer *videoLayer = [AVPlayerLayer layer];
        videoLayer.frame = self.bounds;
        videoLayer.videoGravity = AVLayerVideoGravityResizeAspectFill; // 尺寸自适应铺满
        videoLayer.masksToBounds = YES;
        [self.layer addSublayer:videoLayer];
        _videoLayer = videoLayer;
        [self configure];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.videoLayer.frame = self.bounds;
}

- (void)configure {
    NVBManager *mgr = [NVBManager shared];
    NSDictionary *s = [mgr settingsForContext:self.contextKey];
    BOOL on = [s[@"enabled"] boolValue] && [s[@"path"] length] > 0;
    self.hidden = !on;
    if (!on) {
        self.videoLayer.player = nil;
        self.videoLayer.filters = nil;
        return;
    }

    AVQueuePlayer *p = [mgr playerForContext:self.contextKey forceRebuild:NO];
    if (p && self.videoLayer.player != p) self.videoLayer.player = p;

    // 模糊度
    CGFloat blur = [s[@"blur"] doubleValue];
    if (blur > 0.01) {
        id f = NVBBlurFilter(blur);
        self.videoLayer.filters = f ? @[f] : nil;
    } else {
        self.videoLayer.filters = nil;
    }

    // 不透明度
    CGFloat alpha = [s[@"alpha"] doubleValue];
    self.videoLayer.opacity = (float)MAX(0.0, MIN(1.0, alpha));

    // 音量
    if (p) {
        p.volume = [s[@"volume"] doubleValue];
        p.muted  = (p.volume <= 0.001);
        if (p.rate == 0.0) [p play];
    }
}

@end

#pragma mark - 内置设置页 (含相册导入)

@interface NVBSettingsListController : UITableViewController <PHPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *pendingContext;
@end

@implementation NVBSettingsListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"备忘录视频背景";
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(close)];
    self.tableView.backgroundColor = [UIColor systemBackgroundColor];
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSArray<NSArray<NSString *> *> *)contextDefs {
    return @[ @[NVBContextNote,      @"正文 / 编辑页",    @"笔记编辑界面"],
              @[NVBContextFolder,    @"文件夹",           @"文件夹列表页"],
              @[NVBContextNotesList, @"笔记列表",         @"文件夹内的笔记列表页"],
              @[NVBContextGallery,   @"画廊",             @"画廊视图页面；若与笔记列表共用控制器，两个开关均会生效"],
              @[NVBContextSearch,    @"搜索",             @"搜索页面"],
              @[NVBContextRecent,    @"最近删除",         @"最近删除页面"],
              @[NVBContextInternal,  @"内部浏览默认背景",  @"为未被识别的内部页兜底；若某专用背景关闭，对应页面也可能回落到此处"] ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.contextDefs.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.contextDefs[section][1];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([self.contextDefs[section][0] isEqualToString:NVBContextInternal]) {
        return @"备忘录为私有框架，个别页面可能无法精确识别，将使用此默认背景兜底。";
    }
    return @"开启后需选择素材方可生效。";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 5;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return (indexPath.row >= 2) ? 64.0 : 44.0;
}

- (NSString *)contextKeyForSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.contextDefs.count) return NVBContextNote;
    return self.contextDefs[section][0];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *ctx = [self contextKeyForSection:indexPath.section];
    NSDictionary *s = [[NVBManager shared] settingsForContext:ctx];

    switch (indexPath.row) {
        case 0: { // 页开开关
            UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"nvb-toggle"];
            if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"nvb-toggle"];
            c.textLabel.text = @"页开开关";
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on  = [s[@"enabled"] boolValue];
            sw.tag = indexPath.section;
            [sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = sw;
            return c;
        }
        case 1: { // 已选素材 / 相册导入
            UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"nvb-media"];
            if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"nvb-media"];
            c.textLabel.text = @"选择素材（相册导入）";
            NSString *path = s[@"path"];
            c.detailTextLabel.text = path.length > 0 ? @"已选素材" : @"未选择";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        default: { // 2 模糊度 / 3 不透明度 / 4 音量
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            c.selectionStyle = UITableViewCellSelectionStyleNone;

            NSString *title; float value; float min = 0, max = 1; NSString *fmt;
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
            sl.minimumValue = min;
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
    if (indexPath.row != 1) return;
    NSString *ctx = [self contextKeyForSection:indexPath.section];
    self.pendingContext = ctx;

    // PHPicker 独立进程选择, 无需相册权限
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = [PHPickerFilter videosFilter];
    cfg.selectionLimit = 1;
    PHPickerViewController *pc = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    pc.delegate = self;
    [self presentViewController:pc animated:YES completion:nil];
}

#pragma mark 控件回调

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

#pragma mark PHPickerDelegate - 相册视频导入

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    NSString *ctx = self.pendingContext;
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count || !ctx) return;
    PHPickerResult *res = results.firstObject;
    __weak typeof(self) wself = self;

    [res.provider loadFileRepresentationForTypeIdentifier:@"public.movie"
                                        completionHandler:^(NSURL *url, NSError *error) {
        if (!url || error) {
            return;
        }
        // 拷贝进备忘录沙盒 (loadFileRepresentation 的临时文件在回调结束后会被删除, 必须当场复制)
        NSString *ext = url.pathExtension.length ? url.pathExtension : @"mov";
        NSString *dest = [[[NVBManager shared] mediaDirectory]
                          stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", ctx, ext]];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:dest error:nil];
        NSError *copyError = nil;
        BOOL ok = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:dest] error:&copyError];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself) return;
            if (ok) {
                NSMutableDictionary *s = [[NVBManager shared] settingsForContext:ctx];
                s[@"path"] = dest;
                [[NVBManager shared] saveSettings:s forContext:ctx];
                [[NVBManager shared] playerForContext:ctx forceRebuild:YES];
                [[NVBManager shared] refreshVisibleBackgrounds];
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

#pragma mark - 备忘录 Hook

// 类不存在时 Logos 仅打警告, 不影响运行
@interface ICNoteBodyViewController : UIViewController @end
@interface ICNoteEditViewController : UIViewController @end
@interface ICFolderViewController : UIViewController @end
@interface ICSettingsViewController : UIViewController @end

// 正文 / 编辑页
%hook ICNoteBodyViewController
- (void)viewWillAppear:(BOOL)animated { %orig; [[NVBManager shared] applyToViewController:self context:NVBContextNote]; }
- (void)viewDidAppear:(BOOL)animated  { %orig; [[NVBManager shared] applyToViewController:self context:NVBContextNote]; }
%end

%hook ICNoteEditViewController
- (void)viewWillAppear:(BOOL)animated { %orig; [[NVBManager shared] applyToViewController:self context:NVBContextNote]; }
- (void)viewDidAppear:(BOOL)animated  { %orig; [[NVBManager shared] applyToViewController:self context:NVBContextNote]; }
%end

// 文件夹
%hook ICFolderViewController
- (void)viewWillAppear:(BOOL)animated { %orig; [[NVBManager shared] applyToViewController:self context:NVBContextFolder]; }
- (void)viewDidAppear:(BOOL)animated  { %orig; [[NVBManager shared] applyToViewController:self context:NVBContextFolder]; }
%end

// 设置页入口: 导航栏右侧加 "视频背景" 按钮
%hook ICSettingsViewController
- (void)viewDidLoad {
    %orig;
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:@"视频背景"
                                                             style:UIBarButtonItemStylePlain
                                                            target:[NVBManager shared]
                                                            action:@selector(openSettings:)];
    self.navigationItem.rightBarButtonItem = item;
}
%end

// 兜底: 按 IC* 类名关键词分发到 笔记列表/画廊/搜索/最近删除/内部默认 背景
%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @autoreleasepool {
        NSString *name = NSStringFromClass([self class]);
        NSString *ctx = NVBContextForClassName(name);
        if (!ctx) return; // 精确类名由上方专用 Hook 处理
        if ([name containsString:@"Keyboard"] || [name containsString:@"Picker"]) return;
        // 仅铺满屏幕(或接近全屏的 sheet)的内部页才套用背景
        CGSize vs = self.view.bounds.size;
        CGSize ss = UIScreen.mainScreen.bounds.size;
        BOOL fit = (fabs(vs.width - ss.width) < 32 && fabs(vs.height - ss.height) < 32) ||
                   (fabs(vs.width - ss.height) < 32 && fabs(vs.height - ss.width) < 32);
        if (!fit) return;
        [[NVBManager shared] applyToViewController:self context:ctx];
    }
}
%end
