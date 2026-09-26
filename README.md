# NotesVideoBG — 苹果备忘录视频背景插件

rootless 越狱插件（Dopamine / ElleKit，iOS 16.x），为苹果「备忘录」的各个界面添加视频背景。

## 功能对应（与需求图一致）

| 界面 | 状态 | 说明 |
|---|---|---|
| 正文 / 编辑页 | ✅ 支持 | 独立开关、独立素材、独立参数 |
| 文件夹 | ✅ 支持 | 独立开关、独立素材、独立参数 |
| 笔记列表 | ✅ 支持 | 文件夹内的笔记列表页，独立配置 |
| 画廊 | ✅ 支持 | 画廊视图页面，独立配置（若与笔记列表共用同一控制器，两个开关均会生效） |
| 搜索 | ✅ 支持 | 搜索页面，独立配置 |
| 最近删除 | ✅ 支持 | 独立配置 |
| 内部浏览默认背景 | ✅ 支持 | 为未被识别的内部页兜底 |

每个界面均可配置：
- **页开开关**：开启/关闭该界面背景
- **已选素材**：在插件设置里直接从相册导入视频（PHPicker，不申请相册权限），素材复制进备忘录沙盒持久保存
- **模糊度**：0–30（CAFilter gaussianBlur）
- **不透明度**：0–1
- **音量**：0–100%，视频无缝循环播放

视频使用 `AspectFill` 尺寸自适应，任意分辨率素材自动铺满屏幕不变形；所有改动实时生效。

## 设置入口

打开「备忘录」→ 右上角 **设置** → 导航栏右侧 **视频背景** 按钮。

## Windows 下编译（WSL + Theos）

你在 Windows 环境，Theos 需在 WSL 中构建：

```bash
# 1. WSL 内安装依赖（Ubuntu）
sudo apt update && sudo apt install -y build-essential fakeroot perl git curl

# 2. 安装 Theos
export THEOS=~/theos
git clone --recursive https://github.com/theos/theos.git $THEOS

# 3. 安装 iOS SDK
curl -LO https://github.com/theos/sdks/archive/master.zip
unzip master.zip -d $THEO/targets 2>/dev/null || (mkdir -p $THEOS/sdks && unzip master.zip -d $THEOS/sdks && mv $THEOS/sdks/sdks-master/* $THEOS/sdks/)

# 4. 编译打包（本工程已写死 rootless 方案）
cd /mnt/c/Users/Administrator/WorkBuddy/2026-09-26-18-53-36/NotesVideoBG
make package THEOS_PACKAGE_SCHEME=rootless
```

产物为 `packages/com.nvb.notesvideobg_1.0.0_iphoneos-arm64.deb`。

## 安装到手机

1. 把 `.deb` 传到手机（AirDrop / Filza / `scp`）。
2. 用 Filza 点击安装，或 SSH 执行：
   ```bash
   dpkg -i /path/to/com.nvb.notesvideobg_1.0.0_iphoneos-arm64.deb
   killall MobileNotes
   ```
3. 重启「备忘录」后进入 设置 → 视频背景 配置。

## 已知限制 / 说明

- 备忘录是私有框架（`IC*` 类名），iOS 小版本间可能变动。若 `ICNoteBodyViewController` / `ICFolderViewController` 名称不匹配，对应界面会自动落入「内部浏览默认背景」兜底逻辑（因类名以 `IC` 开头仍会被识别），不会崩溃。
- 透明化处理会递归清掉表格/文本视图的背景色，个别单元格可能仍带系统底色，属正常现象。
- 视频有声音，建议在公开场合把音量调低或归零。
- 卸载插件不会删除已导入的素材；素材存放在备忘录沙盒 `Documents/NVBMedia/`。
