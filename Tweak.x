#import "NVBCommon.h"
#import <CoreFoundation/CFNotificationCenter.h>

// ============================================================
// 备忘录视频背景 (NotesVideoBG) - 主插件 (注入 MobileNotes)
// 作者: 板栗仁 | rootless / Dopamine / ElleKit
//
//  - 正文/编辑页、文件夹、笔记列表、画廊、搜索、最近删除
//    六类独立视频背景 + 内部浏览默认背景兜底
//  - 素材管理在 系统"设置"/OneSettings 的"备忘录视频背景"面板
//  - 所有 Hook 均有异常保护, 不影响备忘录正常启动
// ============================================================

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

#pragma mark - 备忘录 Hook

// 类不存在时 Logos 仅打警告, 不影响运行
@interface ICNoteBodyViewController : UIViewController @end
@interface ICNoteEditViewController : UIViewController @end
@interface ICFolderViewController : UIViewController @end

#define NVB_SAFE_APPLY(ctx) @try { [[NVBManager shared] applyToViewController:self context:(ctx)]; } @catch (NSException *e) {}

// 正文 / 编辑页
%hook ICNoteBodyViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NVB_SAFE_APPLY(NVBContextNote)
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NVB_SAFE_APPLY(NVBContextNote)
}
%end

%hook ICNoteEditViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NVB_SAFE_APPLY(NVBContextNote)
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NVB_SAFE_APPLY(NVBContextNote)
}
%end

// 文件夹
%hook ICFolderViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    NVB_SAFE_APPLY(NVBContextFolder)
}
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NVB_SAFE_APPLY(NVBContextFolder)
}
%end

// 兜底: IC* 类名关键词分发 笔记列表/画廊/搜索/最近删除/内部默认
%hook UIViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    @try {
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
    } @catch (NSException *e) {
        // 保证不崩溃
    }
}
%end

// Darwin 通知: 系统"设置"/OneSettings 修改配置后实时刷新
%ctor {
    @try {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        NVBPrefsChanged,
                                        CFSTR(NVB_DARWIN_NOTE),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    } @catch (NSException *e) {}
}
