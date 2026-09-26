#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// ============================================================
// 备忘录视频背景 (NotesVideoBG) - 共享核心
// 作者: 板栗仁 | rootless / Dopamine / ElleKit
// ============================================================

#define NVB_SUITE @"com.nvb.notesvideobg"
#define NVB_DARWIN_NOTE "com.nvb.notesvideobg/prefs.changed"
#define NVB_MEDIA_DIR_NAME @"NVBMedia"

extern NSString * const NVBContextNote;      // 正文/编辑页
extern NSString * const NVBContextFolder;    // 文件夹
extern NSString * const NVBContextNotesList; // 笔记列表
extern NSString * const NVBContextGallery;   // 画廊
extern NSString * const NVBContextSearch;    // 搜索
extern NSString * const NVBContextRecent;    // 最近删除
extern NSString * const NVBContextInternal;  // 内部浏览默认背景(兜底)

// 7 类界面定义: @[key, 标题, 说明]
NSArray<NSArray<NSString *> *> *NVBContextDefinitions(void);

@interface NVBManager : NSObject
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
- (void)postChangeNotification;
@end

@interface NVBVideoBackgroundView : UIView
@property (nonatomic, copy) NSString *contextKey;
@property (nonatomic, strong) AVPlayerLayer *videoLayer;
- (instancetype)initWithFrame:(CGRect)frame contextKey:(NSString *)key;
- (void)configure;
@end
