#import "NVBCommon.h"
#import <CoreFoundation/CFNotificationCenter.h>

// ============================================================
// 共享核心: 配置管理 / 素材库 / 播放器 / 背景视图
// ============================================================

NSString * const NVBContextNote      = @"note";
NSString * const NVBContextFolder    = @"folder";
NSString * const NVBContextNotesList = @"notesList";
NSString * const NVBContextGallery   = @"gallery";
NSString * const NVBContextSearch    = @"search";
NSString * const NVBContextRecent    = @"recent";
NSString * const NVBContextInternal  = @"internal";

NSArray<NSArray<NSString *> *> *NVBContextDefinitions(void) {
    return @[ @[NVBContextNote,      @"正文 / 编辑页",     @"笔记内容与编辑界面"],
              @[NVBContextFolder,    @"文件夹",            @"文件夹列表界面"],
              @[NVBContextNotesList, @"笔记列表",          @"文件夹内的笔记列表"],
              @[NVBContextGallery,   @"画廊",              @"画廊视图(可能与笔记列表共用界面)"],
              @[NVBContextSearch,    @"搜索",              @"搜索界面"],
              @[NVBContextRecent,    @"最近删除",          @"最近删除界面"],
              @[NVBContextInternal,  @"内部浏览默认背景",   @"未被识别的内部页兜底背景"] ];
}

static char NVBBGKey;

#pragma mark - 管理器

@interface NVBManager ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVPlayer *> *players;
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVPlayerItem *> *items;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *playerPaths;
@end

@implementation NVBManager

+ (instancetype)shared {
    static NVBManager *_nvbSharedInstance = nil;
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
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerDidEnd:)
                                                     name:@"AVPlayerItemDidPlayToEndTime"
                                                   object:nil];
    }
    return self;
}

- (void)playerDidEnd:(NSNotification *)n {
    @try {
        AVPlayerItem *item = n.object;
        for (NSString *k in self.players) {
            if (self.items[k] == item) {
                [self.players[k] seekToTime:kCMTimeZero];
                [self.players[k] play];
            }
        }
    } @catch (NSException *e) {}
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

- (void)postChangeNotification {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR(NVB_DARWIN_NOTE), NULL, NULL, YES);
}

// ---- 素材目录 (跨进程共享探测) ----

- (NSString *)mediaDirectory {
    static NSString *resolved = nil;
    if (!resolved) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *candidates = @[ @"/var/jb/Library/NVBMedia",          // rootless 共享目录(postinst 预建)
                                 @"/var/mobile/Library/NVBMedia",      // 移动用户目录
                                 [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/" NVB_MEDIA_DIR_NAME] ];
        for (NSString *dir in candidates) {
            @try {
                [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *probe = [dir stringByAppendingPathComponent:@".nvb_probe"];
                if ([@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
                    [fm removeItemAtPath:probe error:nil];
                    resolved = [dir copy];
                    break;
                }
            } @catch (NSException *e) {}
        }
        if (!resolved) {
            resolved = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/" NVB_MEDIA_DIR_NAME];
        }
        [fm createDirectoryAtPath:resolved withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return resolved;
}

// ---- 素材库 ----

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

- (NSString *)addMaterialFromFile:(NSURL *)srcURL name:(NSString *)name error:(NSError **)error {
    @try {
        NSString *mid  = [[NSUUID UUID] UUIDString];
        NSString *ext  = srcURL.pathExtension.length ? srcURL.pathExtension : @"mov";
        NSString *dest = [[self mediaDirectory]
                          stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", mid, ext]];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:dest error:nil];
        if (![fm copyItemAtURL:srcURL toURL:[NSURL fileURLWithPath:dest] error:error]) return nil;

        NSMutableArray *lib = [[self materialLibrary] mutableCopy];
        [lib addObject:@{ @"id": mid,
                          @"name": (name.length ? name : [NSString stringWithFormat:@"素材%lu", (unsigned long)lib.count + 1]) }];
        [self saveMaterialLibrary:lib];
        [self postChangeNotification];
        return mid;
    } @catch (NSException *e) {
        return nil;
    }
}

- (void)removeMaterialWithId:(NSString *)mid {
    NSMutableArray *lib = [[self materialLibrary] mutableCopy];
    NSString *path = nil;
    for (NSDictionary *m in lib) {
        if ([m[@"id"] isEqualToString:mid]) { path = m[@"path"]; [lib removeObject:m]; break; }
    }
    [self saveMaterialLibrary:lib];
    if (path) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

    for (NSArray<NSString *> *def in NVBContextDefinitions()) {
        NSString *key = [def[0] stringByAppendingString:@"_material"];
        if ([[[self prefs] stringForKey:key] isEqualToString:mid]) {
            [[self prefs] removeObjectForKey:key];
        }
    }
    [[self prefs] synchronize];
    [self postChangeNotification];
}

// ---- 各界面配置 (扁平键, 兼容系统设置/OneSettings 直写) ----

- (NSMutableDictionary *)settingsForContext:(NSString *)ctx {
    NSUserDefaults *p = [self prefs];
    NSString *mid  = [p stringForKey:[ctx stringByAppendingString:@"_material"]] ?: @"";
    NSDictionary *mat = [self materialWithId:mid];
    NSString *path = mat[@"path"] ?: @"";
    if (path.length > 0 && ![[NSFileManager defaultManager] fileExistsAtPath:path]) path = @""; // 文件丢失时优雅降级
    return [@{ @"master":       @([self masterEnabled]),
               @"enabled":      @([p boolForKey:[ctx stringByAppendingString:@"_enabled"]]),
               @"materialId":   mid,
               @"materialName": mat[@"name"] ?: @"",
               @"path":         path,
               @"blur":         @([self numForKey:[ctx stringByAppendingString:@"_blur"] default:8.0]),
               @"alpha":        @([self numForKey:[ctx stringByAppendingString:@"_alpha"] default:0.65]),
               @"volume":       @([self numForKey:[ctx stringByAppendingString:@"_volume"] default:1.0]) }
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
    [self postChangeNotification];
}

// ---- 播放器 (每界面一个, 播完回开头循环) ----

- (AVPlayer *)playerForContext:(NSString *)ctx forceRebuild:(BOOL)force {
    @try {
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
    } @catch (NSException *e) {
        return nil;
    }
}

// ---- 背景应用 ----

- (void)applyToViewController:(UIViewController *)vc context:(NSString *)ctx {
    @try {
        if (!vc.isViewLoaded || !vc.view) return;

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
    } @catch (NSException *e) {
        // 任何异常都不允许导致备忘录崩溃
    }
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
    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) [self refreshInView:w];
        }
        for (UIWindow *w in UIApplication.sharedApplication.windows) [self refreshInView:w];
    } @catch (NSException *e) {}
}

- (void)refreshInView:(UIView *)view {
    if ([view isKindOfClass:[NVBVideoBackgroundView class]]) {
        [(NVBVideoBackgroundView *)view configure];
        return;
    }
    for (UIView *sub in view.subviews) [self refreshInView:sub];
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
    @try {
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

        // 模糊度 (私有 CAFilter gaussianBlur)
        CGFloat blur = [s[@"blur"] doubleValue];
        if (blur > 0.01) {
            Class cls = objc_getClass("CAFilter");
            SEL sel = NSSelectorFromString(@"filterWithName:");
            id f = nil;
            if (cls && [(id)cls respondsToSelector:sel]) {
                f = ((id (*)(id, SEL, id))objc_msgSend)((id)cls, sel, @"gaussianBlur");
                if (f) [f setValue:@(blur) forKey:@"inputRadius"];
            }
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
    } @catch (NSException *e) {}
}

@end
