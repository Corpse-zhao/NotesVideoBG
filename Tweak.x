#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <CoreFoundation/CFNotificationCenter.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// ============================================================
// 备忘录视频背景 (NotesVideoBG) - rootless / Dopamine / ElleKit
// 作者: 板栗仁
//
//  - 正文/编辑页、文件夹、笔记列表、画廊、搜索、最近删除
//    六类独立视频背景 + 内部浏览默认背景兜底
//  - 多素材库: 相册导入多个视频, 各界面自由选用
//  - 尺寸自适应 (AspectFill), 模糊度/不透明度/音量可调
//  - 内置设置页 + 系统"设置"(PreferenceLoader/OneSettings)入口
// ============================================================

#define NVB_SUITE @"com.nvb.notesvideobg"
#define NVB_DARWIN_NOTE "com.nvb.notesvideobg/prefs.changed"
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

// ---------- 完整类声明 (提前给出, 避免前向声明报错) ----------

@interface NVBVideoBackgroundView : UIView
@property (nonatomic, copy) NSString *contextKey;
@property (nonatomic, strong) AVPlayerLayer *videoLayer;
- (instancetype)initWithFrame:(CGRect)frame contextKey:(NSString *)key;
- (void)configure;
@end

@interface NVBMaterialListController : UITableViewController <PHPickerViewControllerDelegate>
@property (nonatomic, copy) NSString *contextKey; // 选择素材的目标界面
@end

@interface NVBSettingsListController : UITableViewController
@property (nonatomic, copy) NSString *pendingContext;
@end

@interface NVBManager : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVPlayer *> *players;
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVPlayerItem *> *items;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *playerPaths;
+ (instancetype)shared;
- (NSUserDefaults *)prefs;
- (BOOL)masterEnabled;
- (NSMutableDictionary *)settingsForContext:(NSString *)ctx;
- (void)saveSettings:(NSMutableDictionary *)s forContext:(NSString *)ctx;
- (NSString *)mediaDirectory;
- (NSArray<NSDictionary *> *)materialLibrary;
- (void)saveMaterialLibrary:(NSArray<NSDictionary *> *)lib;
- (NSDictionary *)materialWithId:(NSString *)mid;
- (NSString *)addMaterialFromFile:(NSURL *)srcURL name:(NSString *)name error:(NSError **)error;
- (void)removeMaterialWithId:(NSString *)mid;
- (AVPlayer *)playerForContext:(NSString *)ctx forceRebuild:(BOOL)force;
- (void)applyToViewController:(UIViewController *)vc context:(NSString *)ctx;
- (void)refreshVisibleBackgrounds;
- (void)openSettings:(id)sender;
@end

#pragma mark - 工具函数

// 可调模糊度: 私有 CAFilter gaussianBlur
static id NVBBlurFilter(CGFloat radius) {
    Class cls = objc_getClass("CAFilter");
    SEL sel = NSSelectorFromString(@"filterWithName:");
    if (!cls || ![(id)cls respondsToSelector:sel]) return nil;
    id filter = ((id (*)(id, SEL, id))objc_msgSend)((id)cls, sel, @"gaussianBlur");
    if (filter) {
        [filter setValue:@(radius) forKey:@"inputRadius"];
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

// 类名 -> 上下文映射 (备忘录私有框架 IC* 前缀)
static NSString *NVBContextForClassName(NSString *name) {
    if (!name || ![name hasPrefix:@"IC"]) return nil;
    if ([name isEqualToString:@"ICNoteBodyViewController"] ||
        [name isEqualToString:@"ICNoteEditViewController"] ||
        [name isEqualToString:@"ICFolderViewController"] ||
        [name isEqualToString:@"ICSettingsViewController"]) return nil;
    if ([name containsString:@"Gallery"])          return NVBContextGallery;
    if ([name containsString:@"Search"])           return NVBContextSearch;
    if ([name containsString:@"RecentlyDeleted"] ||
        [name containsString:@"Trash"])            return NVBContextRecent;
    if ([name containsString:@"NotesView"] ||
        [name containsString:@"NoteList"] ||
        [name containsString:@"Note"])             return NVBContextNotesList;
    return NVBContextInternal;
}

// Darwin 通知回调: 系统"设置"(OneSettings)里改了配置 -> 实时刷新
static void NVBPrefsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[NVBManager shared] refreshVisibleBackgrounds];
}

#pragma mark - 管理器: 配置/素材库/播放

@implementation NVBManager

static NVBManager *_nvbSharedInstance = nil;

+ (instancetype)shared {
    if (!_nvbSharedInstance) {
        _nvbSharedInstance = [self new];
    }
    return _nvbSharedInstance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _players     = [NSMutableDictionary new];
        _items       = [NSMutableDictionary new];
        _playerPaths = [NSMutableDictionary new];
        // 播完自动回到开头, 循环播放
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerDidEnd:)
                                                     name:@"AVPlayerItemDidPlayToEndTime"
                                                   object:nil];
    }
    return self;
}

- (void)playerDidEnd:(NSNotification *)n {
    AVPlayerItem *item = n.object;
    for (NSString *k in self.players) {
        if (self.items[k] == item) {
            [self.players[k] seekToTime:kCMTimeZero];
            [self.players[k] play];
        }
    }
}

- (NSUserDefaults *)prefs {
    return [[NSUserDefaults alloc] initWithSuiteName:NVB_SUITE];
}

- (BOOL)masterEnabled {
    id v = [[self prefs] objectForKey:@"master_enabled"];
    return v ? [v boolValue] : YES; // 默认开
}

- (CGFloat)numForKey:(NSString *)k default:(CGFloat)d {
    id v = [[self prefs] objectForKey:k];
    return v ? [v doubleValue] : d;
}

// ---- 素材库 ----

- (NSString *)mediaDirectory {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/" NVB_MEDIA_DIR_NAME];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSArray<NSDictionary *> *)materialLibrary {
    NSArray *lib = [[self prefs] arrayForKey:@"materials"];
    return lib ?: @[];
}

- (void)saveMaterialLibrary:(NSArray<NSDictionary *> *)lib {
    [[self prefs] setObject:lib forKey:@"materials"];
    [[self prefs] synchronize];
}

- (NSDictionary *)materialWithId:(NSString *)mid {
    if (mid.length == 0) return nil;
    for (NSDictionary *m in [self materialLibrary]) {
        if ([m[@"id"] isEqualToString:mid]) return m;
    }
    return nil;
}

// 导入素材: 复制进备忘录沙盒并登记, 返回素材 id
- (NSString *)addMaterialFromFile:(NSURL *)srcURL name:(NSString *)name error:(NSError **)error {
    NSString *mid = [[NSUUID UUID] UUIDString];
    NSString *ext = srcURL.pathExtension.length ? srcURL.pathExtension : @"mov";
    NSString *dest = [[self mediaDirectory]
                      stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", mid, ext]];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dest error:nil];
    if (![fm copyItemAtURL:srcURL toURL:[NSURL fileURLWithPath:dest] error:error]) return nil;

    NSMutableArray *lib = [[self materialLibrary] mutableCopy];
    [lib addObject:@{ @"id": mid,
                      @"name": (name.length ? name : [NSString stringWithFormat:@"素材%lu", (unsigned long)lib.count + 1]) }];
    [self saveMaterialLibrary:lib];
    return mid;
}

// 删除素材: 移除文件与登记, 并清掉引用它的界面配置
- (void)removeMaterialWithId:(NSString *)mid {
    NSMutableArray *lib = [[self materialLibrary] mutableCopy];
    NSString *path = nil;
    for (NSDictionary *m in lib) {
        if ([m[@"id"] isEqualToString:mid]) { path = m[@"path"]; [lib removeObject:m]; break; }
    }
    [self saveMaterialLibrary:lib];
    if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    for (NSString *ctx in @[NVBContextNote, NVBContextFolder, NVBContextNotesList,
                            NVBContextGallery, NVBContextSearch, NVBContextRecent, NVBContextInternal]) {
        if ([[[self prefs] stringForKey:[ctx stringByAppendingString:@"_material"]] isEqualToString:mid]) {
            [[self prefs] removeObjectForKey:[ctx stringByAppendingString:@"_material"]];
        }
    }
    [[self prefs] synchronize];
}

// ---- 各界面配置 (扁平键, 兼容系统设置/OneSettings 直写) ----

- (NSMutableDictionary *)settingsForContext:(NSString *)ctx {
    NSUserDefaults *p = [self prefs];
    NSString *mid = [p stringForKey:[ctx stringByAppendingString:@"_material"]] ?: @"";
    NSDictionary *mat = [self materialWithId:mid];
    return [@{ @"master":      @([self masterEnabled]),
               @"enabled":     @([p boolForKey:[ctx stringByAppendingString:@"_enabled"]]),
               @"materialId":  mid,
               @"materialName": mat[@"name"] ?: @"",
               @"path":        mat[@"path"] ?: @"",
               @"blur":        @([self numForKey:[ctx stringByAppendingString:@"_blur"] default:8.0]),
               @"alpha":       @([self numForKey:[ctx stringByAppendingString:@"_alpha"] default:0.65]),
               @"volume":      @([self numForKey:[ctx stringByAppendingString:@"_volume"] default:1.0]) }
            mutableCopy];
}

- (void)saveSettings:(NSMutableDictionary *)s forContext:(NSString *)ctx {
    NSUserDefaults *p = [self prefs];
    [p setBool:[s[@"enabled"] boolValue] forKey:[ctx stringByAppendingString:@"_enabled"]];
    [p setObject:(s[@"materialId"] ?: @"") forKey:[ctx stringByAppendingString:@"_material"]];
    [p setObject:@([s[@"blur"] doubleValue]) forKey:[ctx stringByAppendingString:@"_blur"]];
    [p setObject:@([s[@"alpha"] doubleValue]) forKey:[ctx stringByAppendingString:@"_alpha"]];
    [p setObject:@([s[@"volume"] doubleValue]) forKey:[ctx stringByAppendingString:@"_volume"]];
    [p synchronize];
}

// ---- 播放器 (每界面一个, 播完回开头循环) ----

- (AVPlayer *)playerForContext:(NSString *)ctx forceRebuild:(BOOL)force {
    NSDictionary *s = [self settingsForContext:ctx];
    NSString *path = s[@"path"];
    if (path.length == 0) return nil;

    AVPlayer *p = self.players[ctx];
    if (p && !force && [self.playerPaths[ctx] isEqualToString:path]) return p;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:@"AVPlayerItemDidPlayToEndTime"
                                                  object:self.items[ctx]];
    [p pause];
    [self.players removeObjectForKey:ctx];
    [self.items removeObjectForKey:ctx];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    p = [AVPlayer playerWithPlayerItem:item];
    self.players[ctx]     = p;
    self.items[ctx]       = item;
    self.playerPaths[ctx] = path;
    p.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    p.volume = [s[@"volume"] doubleValue];
    p.muted  = (p.volume <= 0.001);
    [p play];
    return p;
}

// ---- 背景应用 ----

- (void)applyToViewController:(UIViewController *)vc context:(NSString *)ctx {
    if (!vc.isViewLoaded || !vc.view) return;
    if ([vc isKindOfClass:[NVBSettingsListController class]]) return;
    if ([vc isKindOfClass:[NVBMaterialListController class]]) return;
    if ([vc isKindOfClass:[PHPickerViewController class]]) return;

    NSDictionary *s = [self settingsForContext:ctx];
    BOOL on = [s[@"master"] boolValue] && [s[@"enabled"] boolValue] && [s[@"path"] length] > 0;

    NVBVideoBackgroundView *bg = objc_getAssociatedObject(vc, &NVBBGKey);
    if (!on) {
        if (bg) {
            [bg removeFromSuperview];
            objc_setAssociatedObject(vc, &NVBBGKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }

    if (!bg || ![bg.contextKey isEqualToString:ctx]) {
        // 新建, 或同一 VC 切换模式(如画廊/列表)时重建
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

- (void)refreshVisibleBackgrounds {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) [self refreshInView:w];
    }
    for (UIWindow *w in UIApplication.sharedApplication.windows) [self refreshInView:w];
}

- (void)refreshInView:(UIView *)view {
    if ([view isKindOfClass:[NVBVideoBackgroundView class]]) {
        [(NVBVideoBackgroundView *)view configure];
        return;
    }
    for (UIView *sub in view.subviews) [self refreshInView:sub];
}

- (void)openSettings:(id)sender {
    UIViewController *host = NVBTopViewController();
    if (!host) return;
    NVBSettingsListController *list = [[NVBSettingsListController alloc] initWithStyle:UITableViewStyleInsetGrouped];
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
        AVPlayerLayer *videoLayer = [AVPlayerLayer layer];
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
    BOOL on = [s[@"master"] boolValue] && [s[@"enabled"] boolValue] && [s[@"path"] length] > 0;
    self.hidden = !on;
    if (!on) {
        self.videoLayer.player = nil;
        self.videoLayer.filters = nil;
        return;
    }

    AVPlayer *p = [mgr playerForContext:self.contextKey forceRebuild:NO];
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
    self.videoLayer.opacity = (float)MAX(0.0, MIN(1.0, [s[@"alpha"] doubleValue]));

    // 音量
    if (p) {
        p.volume = [s[@"volume"] doubleValue];
        p.muted  = (p.volume <= 0.001);
        if (p.rate == 0.0) [p play];
    }
}

@end

#pragma mark - 素材库管理页 (相册导入 / 选用 / 删除)

@implementation NVBMaterialListController

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

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSArray<NSDictionary *> *lib = [[NVBManager shared] materialLibrary];
    NSDictionary *s = [[NVBManager shared] settingsForContext:self.contextKey];

    if (indexPath.row < (NSInteger)lib.count) { // 素材行
        UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"nvb-mat"];
        if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"nvb-mat"];
        NSDictionary *m = lib[indexPath.row];
        c.textLabel.text = m[@"name"];
        c.detailTextLabel.text = @"视频素材";
        c.accessoryType = [s[@"materialId"] isEqualToString:m[@"id"]]
                          ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        c.editingAccessoryType = UITableViewCellAccessoryDetailButton;
        return c;
    }
    // 导入行
    UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"nvb-import"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"nvb-import"];
    c.textLabel.text = @"从相册导入视频素材";
    c.textLabel.textColor = [UIColor systemBlueColor];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.row < [self materialCount]; // 仅素材行可删
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSArray<NSDictionary *> *lib = [[NVBManager shared] materialLibrary];
    if (indexPath.row >= (NSInteger)lib.count) return;
    [[NVBManager shared] removeMaterialWithId:lib[indexPath.row][@"id"]];
    [[NVBManager shared] refreshVisibleBackgrounds];
    [tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= [self materialCount]) {
        [self importFromLibrary];
        return;
    }
    // 选用该素材
    NSArray<NSDictionary *> *lib = [[NVBManager shared] materialLibrary];
    NSMutableDictionary *s = [[NVBManager shared] settingsForContext:self.contextKey];
    s[@"materialId"] = lib[indexPath.row][@"id"];
    [[NVBManager shared] saveSettings:s forContext:self.contextKey];
    [[NVBManager shared] playerForContext:self.contextKey forceRebuild:YES];
    [[NVBManager shared] refreshVisibleBackgrounds];
    [self.navigationController popViewControllerAnimated:YES];
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
        // 复制进备忘录沙盒并登记素材库
        [[NVBManager shared] addMaterialFromFile:url
                                            name:url.lastPathComponent.stringByDeletingPathExtension
                                           error:&copyError];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(wself) sself = wself;
            if (!sself) return;
            if (!copyError) {
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

#pragma mark - 内置设置页 (每界面: 开关/素材/模糊度/不透明度/音量)

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
    return @[ @[NVBContextNote,      @"正文 / 编辑页",    @""],
              @[NVBContextFolder,    @"文件夹",           @""],
              @[NVBContextNotesList, @"笔记列表",         @""],
              @[NVBContextGallery,   @"画廊",             @"若与笔记列表共用同一控制器, 两个开关均会生效"],
              @[NVBContextSearch,    @"搜索",             @""],
              @[NVBContextRecent,    @"最近删除",         @""],
              @[NVBContextInternal,  @"内部浏览默认背景",  @"为未被识别的内部页兜底; 关闭专用背景的页面可能回落到此处"] ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.contextDefs.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.contextDefs[section][1];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.contextDefs[section][2];
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
        case 0: { // 开关
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
        case 1: { // 选择素材
            UITableViewCell *c = [tableView dequeueReusableCellWithIdentifier:@"nvb-media"];
            if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"nvb-media"];
            c.textLabel.text = @"选择素材";
            NSString *name = s[@"materialName"];
            c.detailTextLabel.text = name.length ? name : @"未选择";
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
    if (indexPath.row != 1) return;
    NVBMaterialListController *ml = [[NVBMaterialListController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    ml.contextKey = [self contextKeyForSection:indexPath.section];
    [self.navigationController pushViewController:ml animated:YES];
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

@end

#pragma mark - 备忘录 Hook

// 类不存在时 Logos 仅打警告, 不影响运行
@interface ICNoteBodyViewController : UIViewController @end
@interface ICNoteEditViewController : UIViewController @end
@interface ICFolderViewController : UIViewController @end
@interface ICSettingsViewController : UIViewController @end

// 正文 / 编辑页
%hook ICNoteBodyViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[NVBManager shared] applyToViewController:self context:NVBContextNote];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[NVBManager shared] applyToViewController:self context:NVBContextNote];
}
%end

%hook ICNoteEditViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[NVBManager shared] applyToViewController:self context:NVBContextNote];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[NVBManager shared] applyToViewController:self context:NVBContextNote];
}
%end

// 文件夹
%hook ICFolderViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    [[NVBManager shared] applyToViewController:self context:NVBContextFolder];
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[NVBManager shared] applyToViewController:self context:NVBContextFolder];
}
%end

// 设置页入口: 导航栏右侧 "视频背景" 按钮
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

// 兜底: IC* 类名关键词分发 笔记列表/画廊/搜索/最近删除/内部默认
%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @autoreleasepool {
        NSString *name = NSStringFromClass([self class]);
        NSString *ctx = NVBContextForClassName(name);
        if (!ctx) return; // 精确类名由上方专用 Hook 处理
        if ([name containsString:@"Keyboard"] || [name containsString:@"Picker"]) return;
        // 仅铺满屏幕(或接近全屏 sheet)的内部页才套用
        CGSize vs = self.view.bounds.size;
        CGSize ss = UIScreen.mainScreen.bounds.size;
        BOOL fit = (fabs(vs.width - ss.width) < 32 && fabs(vs.height - ss.height) < 32) ||
                   (fabs(vs.width - ss.height) < 32 && fabs(vs.height - ss.width) < 32);
        if (!fit) return;
        [[NVBManager shared] applyToViewController:self context:ctx];
    }
}
%end

// Darwin 通知: 系统"设置"/OneSettings 修改配置后实时刷新
%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    NVBPrefsChanged,
                                    CFSTR(NVB_DARWIN_NOTE),
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
