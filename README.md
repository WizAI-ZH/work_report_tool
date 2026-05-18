# 威智工作汇报器

威智工作汇报器是一款用于快速生成每日工作汇报的跨平台应用，当前版本为 `1.1.9`。应用基于 Flutter 开发，目标支持 Windows、Android 和 macOS；仓库中仍保留旧版 Python/Tkinter 文件，作为功能迁移和对照参考。

## 功能特性

- 按姓名、部门、日期、今日完成情况、明日计划生成规范工作汇报。
- 支持一键复制汇报内容，并在 Windows 上尝试打开企业微信；Android 和 macOS 上保留复制和手动粘贴流程。
- 支持 AI 建议生成，可根据用户补充的不满意原因重新生成建议。
- 支持 AI 配置，包括 API Key、API URL、模型、获取模型和测试连接。
- 首次启动会引导配置 API Key，并提供免费 API Key 获取地址。
- 自动保存历史记录、草稿、任务追踪数据和模板配置。
- 启动时自动检查 GitHub Release 新版本，并在下载更新时显示进度。
- 内置中文日期选择和中文界面文案。
- 应用内显示软件名称和版本号，当前应用名为“威智工作汇报器”。

## 使用方法

1. 打开应用后，首次使用先在弹窗中填写 API Key。
2. 填写姓名、部门和汇报日期。
3. 在“今日工作完成情况”和“明日工作计划”中输入工作内容。
4. 点击“AI 建议”可让 AI 优化或补充内容。
5. 点击“生成汇报”生成正式汇报文本。
6. 点击“复制”或“发送到企微”完成发送前准备。
7. 在顶部“历史”中查看历史汇报，在“模板”中调整汇报模板，在“AI”中修改 AI 配置。

## 本地开发

请先安装 Flutter SDK，并确认开发环境可用：

```powershell
flutter doctor
flutter pub get
flutter analyze
flutter test
```

Windows 本地运行：

```powershell
flutter run -d windows
```

Android 调试运行：

```powershell
flutter devices
flutter run -d <device-id>
```

## 打包

单平台打包：

```powershell
.\scripts\package.ps1 -Target windows
.\scripts\package.ps1 -Target android
```

双击发布到 GitHub Release：

```text
一键打包并发布.bat
```

该脚本会读取 `pubspec.yaml` 中的版本号，构建 Windows 和 Android 安装包，并把产物上传到对应的 GitHub Release。Release 描述来自 `CHANGELOG.md` 中同版本的更新内容。

## Windows 安装说明

普通 Windows 用户建议优先下载 `WizWorkReport_<版本号>_windows_setup.exe`。这是 NSIS 安装包，不需要先安装 MSIX 证书，双击后按提示安装即可。安装器启动时会先选择显示语言，默认是简体中文；默认安装目录为 `C:\威智工作汇报器`。

Windows 的 `.msix` 安装包必须通过证书校验。当前项目使用本地自签名证书进行 MSIX 签名，因此如果选择 MSIX，需要首次安装前先信任同版本 Release 中附带的证书：

1. 在 GitHub Release 下载 `WizWorkReport_<版本号>_windows.cer`。
2. 下载并运行 `Install-WizWorkReport_<版本号>_Certificate.bat`，按系统提示允许管理员权限。
3. 再双击安装 `WizWorkReport_<版本号>_windows.msix`。

如果不想安装证书，也可以下载 `WizWorkReport_<版本号>_windows.zip`，解压后直接运行其中的 `work_report_generator.exe`。

正式对外分发时，建议改用受信任的代码签名证书或 Microsoft Trusted Signing，这样用户安装 MSIX 时就不需要手动信任自签名证书。

## 自动更新说明

应用启动时会自动检查 GitHub Release 最新版本，也可以点击右上角“更新”手动检查。Android 端发现新版本后会下载 APK 并打开系统安装确认页；受 Android 系统限制，普通应用不能静默安装更新，用户仍需手动确认安装。如果系统提示需要“安装未知应用”权限，请允许后回到应用重新点击更新。

## 版本发布流程

1. 在 `pubspec.yaml` 中更新 `version`，例如 `1.0.1+2`。
2. 同步更新 `pubspec.yaml` 的 `msix_config.msix_version`，例如 `1.0.1.0`。
3. 在 `CHANGELOG.md` 顶部新增对应版本的更新说明。
4. 提交代码并推送到 GitHub。
5. 双击 `一键打包并发布.bat`。

## 数据存储

应用数据保存到系统应用文档目录下的 `工作汇报记录`。首次启动时，如果当前运行目录存在旧版 `工作汇报记录`，会在新数据目录为空时尝试导入旧数据。

## 构建产物

发布脚本会把本地打包结果放在 `dist` 目录，例如：

- `WizWorkReport_1.1.9_android.apk`
- `WizWorkReport_1.1.9_windows_setup.exe`
- `WizWorkReport_1.1.9_windows.msix`
- `WizWorkReport_1.1.9_windows.cer`
- `Install-WizWorkReport_1.1.9_Certificate.bat`

## 许可

本仓库为内部工作流工具项目，使用和分发请遵循仓库所属组织的要求。
