<#
.SYNOPSIS
  Build send_to_wework.py into a standalone exe with PyInstaller.
  Includes OCR models, onnxruntime DLLs and all Python deps.
  End users do NOT need Python installed.
#>
param(
  [string]$OutputDir = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$SourceScript = Join-Path $ScriptDir "send_to_wework.py"

if (-not (Test-Path $SourceScript)) {
  Write-Error "send_to_wework.py not found: $SourceScript"
  exit 1
}

if (-not $OutputDir) {
  $OutputDir = Join-Path $ProjectRoot "build\windows\x64\runner\Release\scripts"
}
Write-Host "OutputDir: $OutputDir"

$PyInstallerDist = Join-Path $ProjectRoot "build\pyinstaller"
$PyInstallerBuild = Join-Path $ProjectRoot "build\pyinstaller_build"
if (Test-Path $PyInstallerDist) { Remove-Item $PyInstallerDist -Recurse -Force }
if (Test-Path $PyInstallerBuild) { Remove-Item $PyInstallerBuild -Recurse -Force }

if (Test-Path $OutputDir) {
  Remove-Item (Join-Path $OutputDir "send_to_wework.exe") -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $OutputDir "_internal") -Recurse -Force -ErrorAction SilentlyContinue
} else {
  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "Building send_to_wework.exe with PyInstaller..."

# PyInstaller writes progress to stderr; relax error preference during build.
$PrevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
pyinstaller `
  --noconfirm `
  --clean `
  --onedir `
  --name send_to_wework `
  --distpath $PyInstallerDist `
  --workpath $PyInstallerBuild `
  --specpath $PyInstallerBuild `
  --collect-all rapidocr_onnxruntime `
  --collect-all onnxruntime `
  --hidden-import pyautogui `
  --hidden-import pygetwindow `
  --hidden-import pyperclip `
  --hidden-import mss `
  --hidden-import PIL `
  $SourceScript 2>&1
$PyExit = $LASTEXITCODE
$ErrorActionPreference = $PrevEAP

if ($PyExit -ne 0) {
  Write-Error "PyInstaller failed (exit code: $PyExit)"
  exit $PyExit
}

$BuiltDir = Join-Path $PyInstallerDist "send_to_wework"
if (-not (Test-Path $BuiltDir)) {
  Write-Error "PyInstaller output dir not found: $BuiltDir"
  exit 1
}

Write-Host "Copying build artifacts to $OutputDir..."
Copy-Item -Path "$BuiltDir\*" -Destination $OutputDir -Recurse -Force

$ExePath = Join-Path $OutputDir "send_to_wework.exe"
if (Test-Path $ExePath) {
  $Size = [math]::Round((Get-Item $ExePath).Length / 1MB, 1)
  Write-Host "OK: send_to_wework.exe ($Size MB) -> $ExePath"
} else {
  Write-Error "send_to_wework.exe not found"
  exit 1
}
