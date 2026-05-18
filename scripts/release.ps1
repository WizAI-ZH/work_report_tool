param(
  [string]$Version = "",
  [string]$Remote = "",
  [switch]$SkipChecks,
  [switch]$AllowDirty,
  [switch]$Draft,
  [switch]$Prerelease
)

$ErrorActionPreference = "Stop"

function Resolve-ToolPath {
  $flutterHome = Join-Path $env:USERPROFILE "development\flutter\bin"
  $androidTools = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools"
  $jdkHome = "C:\Program Files\Eclipse Adoptium\jdk-17.0.19.10-hotspot"
  $jdkBin = Join-Path $jdkHome "bin"
  $ghProgramFiles = Join-Path $env:ProgramFiles "GitHub CLI"
  $ghLocalAppData = Join-Path $env:LOCALAPPDATA "Programs\GitHub CLI"
  $nsisProgramFiles = Join-Path ${env:ProgramFiles(x86)} "NSIS"
  $nsisProgramFiles64 = Join-Path $env:ProgramFiles "NSIS"

  foreach ($path in @($flutterHome, $androidTools, $jdkBin, $ghProgramFiles, $ghLocalAppData, $nsisProgramFiles, $nsisProgramFiles64)) {
    if ((Test-Path $path) -and ($env:Path -notlike "*$path*")) {
      $env:Path = "$path;$env:Path"
    }
  }

  if (-not $env:JAVA_HOME -and (Test-Path $jdkHome)) {
    $env:JAVA_HOME = $jdkHome
  }
  if (-not $env:ANDROID_HOME) {
    $env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA "Android\Sdk"
  }
  if (-not $env:ANDROID_SDK_ROOT) {
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
  }
}

function Require-Command([string]$Name, [string]$InstallHint) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing command: $Name. $InstallHint"
  }
}

function Ensure-NSIS {
  if (Get-Command "makensis" -ErrorAction SilentlyContinue) {
    return
  }

  if (Get-Command "winget" -ErrorAction SilentlyContinue) {
    Write-Host "NSIS was not found. Installing NSIS with winget..."
    winget install --id NSIS.NSIS --source winget --accept-package-agreements --accept-source-agreements --silent
    Assert-LastExitCode "winget install NSIS"
    Resolve-ToolPath
  }

  if (-not (Get-Command "makensis" -ErrorAction SilentlyContinue)) {
    throw "Missing command: makensis. Install NSIS from https://nsis.sourceforge.io/Download"
  }
}

function Assert-LastExitCode([string]$Step) {
  if ($LASTEXITCODE -ne 0) {
    throw "$Step failed with exit code $LASTEXITCODE."
  }
}

function Get-PubspecVersion {
  $content = Get-Content -LiteralPath "pubspec.yaml" -Raw -Encoding UTF8
  if ($content -notmatch "(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?\s*$") {
    throw "Cannot read version from pubspec.yaml."
  }
  [PSCustomObject]@{
    Version = $Matches[1]
    Build = $(if ($Matches[2]) { $Matches[2] } else { "1" })
  }
}

function Get-ChangelogSection([string]$ReleaseVersion) {
  if (-not (Test-Path "CHANGELOG.md")) {
    throw "Missing CHANGELOG.md."
  }
  $raw = Get-Content -LiteralPath "CHANGELOG.md" -Raw -Encoding UTF8
  $escaped = [regex]::Escape($ReleaseVersion)
  $pattern = "(?ms)^## \[$escaped\][^\r\n]*(?:\r?\n)(.*?)(?=^## \[|\z)"
  $match = [regex]::Match($raw, $pattern)
  if (-not $match.Success) {
    throw "CHANGELOG.md has no section for version $ReleaseVersion."
  }
  $body = $match.Groups[1].Value.Trim()
  if (-not $body) {
    throw "CHANGELOG.md section for version $ReleaseVersion is empty."
  }
  $body
}

function Get-ReleaseTitle([string]$ReleaseVersion) {
  $appName = -join ([char[]](0x5A01, 0x667A, 0x5DE5, 0x4F5C, 0x6C47, 0x62A5, 0x5668))
  "$appName $ReleaseVersion"
}

function Ensure-MsixSigningCertificate([string]$RootPath) {
  $certDir = Join-Path $RootPath "certs"
  New-Item -ItemType Directory -Path $certDir -Force | Out-Null

  $pfxPath = Join-Path $certDir "WizWorkReportTool-msix.pfx"
  $cerPath = Join-Path $certDir "WizWorkReportTool-msix.cer"
  $password = $env:WIZ_WORK_REPORT_CERT_PASSWORD
  if (-not $password) {
    $password = "WizWorkReportTool-Local-Signing"
  }

  if ((Test-Path $pfxPath) -and (Test-Path $cerPath)) {
    return [PSCustomObject]@{
      PfxPath = (Resolve-Path $pfxPath).Path
      CerPath = (Resolve-Path $cerPath).Path
      Password = $password
    }
  }

  $subject = "CN=Wiz Work Report Tool"
  $cert = New-SelfSignedCertificate `
    -Type Custom `
    -Subject $subject `
    -FriendlyName "Wiz Work Report Tool MSIX Signing" `
    -KeyAlgorithm RSA `
    -KeyLength 2048 `
    -KeyUsage DigitalSignature `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddYears(10) `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")

  $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
  Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $securePassword | Out-Null
  Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

  [PSCustomObject]@{
    PfxPath = (Resolve-Path $pfxPath).Path
    CerPath = (Resolve-Path $cerPath).Path
    Password = $password
  }
}

function Write-CertificateInstallFiles(
  [string]$DistPath,
  [string]$ReleaseVersion,
  [string]$CertificatePath
) {
  $cerName = "WizWorkReport_${ReleaseVersion}_windows.cer"
  $cerOut = Join-Path $DistPath $cerName
  Copy-Item -LiteralPath $CertificatePath -Destination $cerOut -Force

  $ps1Name = "Install-WizWorkReport_${ReleaseVersion}_Certificate.ps1"
  $ps1Path = Join-Path $DistPath $ps1Name
  $ps1Content = @"
`$ErrorActionPreference = "Stop"
`$certPath = Join-Path `$PSScriptRoot "$cerName"
if (-not (Test-Path `$certPath)) {
  throw "Certificate file not found: `$certPath"
}
Import-Certificate -FilePath `$certPath -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
Write-Host "Certificate installed. You can now install the MSIX package."
Read-Host "Press Enter to close"
"@
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($ps1Path, $ps1Content, $utf8NoBom)

  $batName = "Install-WizWorkReport_${ReleaseVersion}_Certificate.bat"
  $batPath = Join-Path $DistPath $batName
  $batContent = @"
@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%~dp0$ps1Name""'"
"@
  [System.IO.File]::WriteAllText($batPath, $batContent, $utf8NoBom)

  [PSCustomObject]@{
    Certificate = (Get-Item -LiteralPath $cerOut).FullName
    PowerShell = (Get-Item -LiteralPath $ps1Path).FullName
    Batch = (Get-Item -LiteralPath $batPath).FullName
  }
}

function Invoke-RobocopyMirror([string]$Source, [string]$Destination) {
  if (Test-Path $Destination) {
    Remove-Item -LiteralPath $Destination -Recurse -Force
  }
  New-Item -ItemType Directory -Path $Destination | Out-Null

  robocopy $Source $Destination /MIR `
    /XD .git .dart_tool build dist logs releases .idea ephemeral .plugin_symlinks `
    /XF local.properties | Out-Null

  if ($LASTEXITCODE -ge 8) {
    throw "Failed to copy temporary build directory. robocopy exit code: $LASTEXITCODE"
  }
}

function Copy-ReleaseArtifact([string]$Source, [string]$Destination) {
  if (-not (Test-Path $Source)) {
    throw "Build artifact not found: $Source"
  }
  Copy-Item -LiteralPath $Source -Destination $Destination -Force
  Get-Item -LiteralPath $Destination
}

function Build-NSISInstaller(
  [string]$ScriptPath,
  [string]$SourceDir,
  [string]$IconPath,
  [string]$ReleaseVersion,
  [string]$OutputPath
) {
  Ensure-NSIS
  if (-not (Test-Path $ScriptPath)) {
    throw "NSIS script not found: $ScriptPath"
  }
  if (-not (Test-Path $SourceDir)) {
    throw "NSIS source directory not found: $SourceDir"
  }

  $args = @(
    "/V2",
    "/DVERSION=$ReleaseVersion",
    "/DSOURCE_DIR=$SourceDir",
    "/DOUT_FILE=$OutputPath"
  )
  if (Test-Path $IconPath) {
    $args += "/DICON_PATH=$IconPath"
  }
  $args += $ScriptPath

  & makensis @args
  Assert-LastExitCode "makensis"

  if (-not (Test-Path $OutputPath)) {
    throw "NSIS installer was not created: $OutputPath"
  }
  Get-Item -LiteralPath $OutputPath
}

function Assert-CleanWorktree {
  if ($AllowDirty) {
    return
  }
  $status = git status --porcelain
  if ($status) {
    throw "Working tree is not clean. Commit changes first, or rerun with -AllowDirty."
  }
}

function Ensure-GitHubRelease(
  [string]$Tag,
  [string]$ReleaseVersion,
  [string]$NotesFile,
  [string[]]$Assets
) {
  if (-not $Remote) {
    $script:Remote = (git remote | Select-Object -First 1)
  }
  if (-not $Remote) {
    throw "No Git remote configured."
  }

  git fetch $Remote --tags
  Assert-LastExitCode "git fetch"

  $existingTag = git tag --list $Tag
  if (-not $existingTag) {
    git tag -a $Tag -m "Release $Tag"
    Assert-LastExitCode "git tag"
  }

  git push $Remote HEAD
  Assert-LastExitCode "git push HEAD"
  git push $Remote $Tag
  Assert-LastExitCode "git push tag"

  cmd /c "gh release view $Tag >NUL 2>NUL"
  $releaseExists = $LASTEXITCODE -eq 0

  $title = Get-ReleaseTitle $ReleaseVersion
  if ($releaseExists) {
    gh release edit $Tag --title $title --notes-file $NotesFile
    Assert-LastExitCode "gh release edit"
    gh release upload $Tag $Assets --clobber
    Assert-LastExitCode "gh release upload"
  } else {
    $args = @(
      "release", "create", $Tag,
      "--title", $title,
      "--notes-file", $NotesFile
    )
    if ($Draft) { $args += "--draft" }
    if ($Prerelease) { $args += "--prerelease" }
    $args += $Assets
    gh @args
    Assert-LastExitCode "gh release create"
  }
}

Resolve-ToolPath
Require-Command "flutter" "Install Flutter and make sure it is available in PATH."
Require-Command "git" "Install Git."
Require-Command "gh" "Install GitHub CLI and run: gh auth login"

gh auth status

$versionInfo = Get-PubspecVersion
if (-not $Version) {
  $Version = $versionInfo.Version
}
$tag = "v$Version"
$releaseNotes = Get-ChangelogSection $Version
$projectRoot = (Resolve-Path ".").Path
$dist = Join-Path $projectRoot "dist"
$notesFile = Join-Path $dist "release-notes-$Version.md"
$temp = Join-Path $env:SystemDrive "wrg_release_publish_$($Version.Replace('.', '_'))_$(Get-Date -Format 'yyyyMMddHHmmss')"

Write-Host "Preparing release $tag"
Assert-CleanWorktree

New-Item -ItemType Directory -Path $dist -Force | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($notesFile, $releaseNotes, $utf8NoBom)
$certInfo = Ensure-MsixSigningCertificate $projectRoot
$certInstallFiles = Write-CertificateInstallFiles $dist $Version $certInfo.CerPath

Invoke-RobocopyMirror $projectRoot $temp

Push-Location $temp
try {
  flutter pub get
  Assert-LastExitCode "flutter pub get"
  if (-not $SkipChecks) {
    flutter analyze
    Assert-LastExitCode "flutter analyze"
    flutter test
    Assert-LastExitCode "flutter test"
  }

  flutter build apk --release
  Assert-LastExitCode "flutter build apk"
  $androidApk = Copy-ReleaseArtifact `
    (Join-Path $temp "build\app\outputs\flutter-apk\app-release.apk") `
    (Join-Path $dist "WizWorkReport_${Version}_android.apk")

  flutter build windows --release
  Assert-LastExitCode "flutter build windows"
  flutter pub run msix:create --build-windows false --install-certificate false --certificate-path $certInfo.PfxPath --certificate-password $certInfo.Password
  Assert-LastExitCode "msix create"

  $releaseDir = Join-Path $temp "build\windows\x64\runner\Release"
  $msix = Get-ChildItem -LiteralPath $releaseDir -Filter "*.msix" -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $msix) {
    throw "Windows build finished, but no .msix file was found."
  }

  $windowsMsix = Copy-ReleaseArtifact $msix.FullName (Join-Path $dist "WizWorkReport_${Version}_windows.msix")

  $windowsZipPath = Join-Path $dist "WizWorkReport_${Version}_windows.zip"
  if (Test-Path $windowsZipPath) {
    Remove-Item -LiteralPath $windowsZipPath -Force
  }
  Compress-Archive -Path (Join-Path $releaseDir "*") -DestinationPath $windowsZipPath -Force
  $windowsZip = Get-Item -LiteralPath $windowsZipPath

  $nsisScript = Join-Path $temp "installer\windows\nsis\wiz_work_report_tool.nsi"
  $nsisIcon = Join-Path $temp "windows\runner\resources\app_icon.ico"
  $windowsSetupPath = Join-Path $dist "WizWorkReport_${Version}_windows_setup.exe"
  if (Test-Path $windowsSetupPath) {
    Remove-Item -LiteralPath $windowsSetupPath -Force
  }
  $windowsSetup = Build-NSISInstaller $nsisScript $releaseDir $nsisIcon $Version $windowsSetupPath
} finally {
  Pop-Location
}

$assets = @(
  $androidApk.FullName,
  $windowsSetup.FullName,
  $windowsMsix.FullName,
  $certInstallFiles.Certificate,
  $certInstallFiles.PowerShell,
  $certInstallFiles.Batch
)
Ensure-GitHubRelease $tag $Version $notesFile $assets

Write-Host ""
Write-Host "Release completed: $tag"
Write-Host "Android APK: $($androidApk.FullName)"
Write-Host "Windows NSIS setup: $($windowsSetup.FullName)"
Write-Host "Windows MSIX: $($windowsMsix.FullName)"
Write-Host "Windows ZIP: $($windowsZip.FullName)"
Write-Host "Windows certificate: $($certInstallFiles.Certificate)"
Write-Host "Windows certificate installer: $($certInstallFiles.Batch)"
