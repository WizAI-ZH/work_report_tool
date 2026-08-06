param(
  [ValidateSet("windows", "android", "macos", "all")]
  [string]$Target = "all"
)

$ErrorActionPreference = "Stop"
$ProjectName = "work_report_generator"
$IsWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
$IsMacOSHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)

function Ensure-FlutterProject([string]$Platforms) {
  foreach ($Platform in $Platforms.Split(",")) {
    if ($Platform -and !(Test-Path ".\$Platform")) {
      flutter create --project-name $ProjectName --platforms=$Platform .
    }
  }
  Ensure-PlatformPermissions
  flutter pub get
}

function Ensure-PlatformPermissions {
  $AndroidManifest = ".\android\app\src\main\AndroidManifest.xml"
  if (Test-Path $AndroidManifest) {
    $Content = Get-Content -LiteralPath $AndroidManifest -Raw
    if ($Content -notmatch "android.permission.INTERNET") {
      $Content = $Content -replace "<manifest([^>]*)>", "<manifest`$1>`n    <uses-permission android:name=`"android.permission.INTERNET`" />"
      Set-Content -LiteralPath $AndroidManifest -Value $Content -Encoding UTF8
    }
  }

  foreach ($Entitlement in @(".\macos\Runner\DebugProfile.entitlements", ".\macos\Runner\Release.entitlements")) {
    if (Test-Path $Entitlement) {
      $Content = Get-Content -LiteralPath $Entitlement -Raw
      if ($Content -notmatch "com.apple.security.network.client") {
        $Content = $Content -replace "</dict>", "    <key>com.apple.security.network.client</key>`n    <true/>`n</dict>"
        Set-Content -LiteralPath $Entitlement -Value $Content -Encoding UTF8
      }
    }
  }
}

function Build-Windows {
  flutter build windows --release
  # 打包企微发送助手为独立 exe（含 OCR 模型等所有 Python 依赖），
  # 用户的机器不需要安装 Python。产物复制到 Release/scripts/ 下，
  # NSIS 安装包会自动包含。
  $HelperScript = Join-Path $PSScriptRoot "build_wework_helper.ps1"
  if (Test-Path $HelperScript) {
    Write-Host "Building send_to_wework.exe (standalone, no Python required)..."
    & $HelperScript
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "send_to_wework.exe 打包失败，Windows 安装包将不含企微自动发送功能"
    }
  }
  flutter pub run msix:create
}

function Build-Android {
  flutter build apk --release
}

function Build-MacOS {
  flutter build macos --release
}

if ($Target -eq "all") {
  Ensure-FlutterProject "android"
  if ($IsWindowsHost) { Ensure-FlutterProject "windows" }
  if ($IsMacOSHost) { Ensure-FlutterProject "macos" }
} else {
  Ensure-FlutterProject $Target
}
flutter analyze
flutter test

switch ($Target) {
  "windows" { Build-Windows }
  "android" { Build-Android }
  "macos" { Build-MacOS }
  "all" {
    if ($IsWindowsHost) { Build-Windows }
    Build-Android
    if ($IsMacOSHost) { Build-MacOS }
  }
}
