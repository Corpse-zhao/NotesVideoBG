# 备忘录视频背景 (NotesVideoBG)

为苹果备忘录注入视频背景的 rootless 越狱插件。作者：**板栗仁**

- 设备：iPhone 14 Pro Max / iOS 16.5（兼容 16.0+）
- 架构：rootless（Dopamine 系），依赖 ElleKit

## 功能

| 界面 | 说明 |
|---|---|
| 正文 / 编辑页 | ✅ 独立背景 |
| 文件夹 | ✅ 独立背景 |
| 笔记列表 | ✅ 独立背景 |
| 画廊 | ✅ 独立背景（可能与笔记列表共用控制器，两个开关均生效） |
| 搜索 | ✅ 独立背景 |
| 最近删除 | ✅ 独立背景 |
| 内部浏览默认背景 | ✅ 未识别内部页的兜底背景 |

- **素材管理**：系统「设置」→「备忘录视频背景」→ 各界面分区的「选择素材」，从相册导入多个视频、点按选用/删除（无需相册权限）
- **参数调节**：每个界面独立的 模糊度 / 不透明度 / 音量 滑条（带名称与实时数值），改动即时生效
- **总开关**：一键启停
- **OneSettings**：设置页同时出现在 OneSettings 中

## 使用

1. 安装 deb 后注销
2. 打开 系统「设置」→「备忘录视频背景」
3. 开总开关 → 各界面分区开「开启背景」→「选择素材」从相册导入视频
4. 用滑条调整模糊度 / 不透明度 / 音量

素材存储于 `/var/jb/Library/NVBMedia`（备忘录与设置进程共享）。

## 构建

推送到 GitHub 后 Actions 自动编译（`.github/workflows/build.yml`），
或本地 WSL：`make package`（需 Theos + iPhoneOS14.5 SDK + sbingner 工具链）。

产物：`com.nvb.notesvideobg_*_iphoneos-arm64.deb`（内含主插件 dylib + NVBPrefs.bundle 设置面板）。

## 结构

- `Tweak.x` — 备忘录进程内 Hook（异常保护，不影响备忘录启动）
- `NVBCommon.h/m` — 共享核心：配置、素材库、播放器、背景视图
- `PrefsController.m` — 设置面板（NVBPrefs.bundle，加载进 设置/OneSettings）
- `layout/` — PreferenceLoader 条目、bundle 内置 plist、postinst（建共享素材目录）
