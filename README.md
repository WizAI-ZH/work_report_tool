# 威智工作汇报器

当前版本：1.0.0

Flutter 跨端版本，目标支持 Windows、macOS 和 Android。旧版 Python/Tkinter 文件仍保留在仓库中，作为功能迁移参考。

## 本地开发

先安装 Flutter SDK，并确认：

```bash
flutter doctor
```

首次运行前生成当前平台工程并安装依赖：

```bash
flutter create --project-name work_report_generator --platforms=windows .
flutter pub get
```

运行桌面版：

```bash
flutter run -d windows
```

## 打包

Windows PowerShell：

```powershell
.\scripts\package.ps1 -Target windows
.\scripts\package.ps1 -Target android
```

macOS/Linux shell：

```bash
bash scripts/package.sh macos
bash scripts/package.sh android
```

CI 可在 GitHub Actions 中手动触发 `Flutter Release` 工作流，分别产出 Android APK、Windows MSIX/Release 目录和 macOS DMG。

## 数据

应用数据保存到系统应用文档目录下的 `工作汇报记录`。首次启动时，如果当前运行目录存在旧版 `工作汇报记录`，会在新数据目录为空时尝试导入。
