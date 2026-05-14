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

  foreach ($path in @($flutterHome, $androidTools, $jdkBin, $ghProgramFiles, $ghLocalAppData)) {
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

  $releaseExists = $true
  gh release view $Tag *> $null
  if ($LASTEXITCODE -ne 0) {
    $releaseExists = $false
  }

  $title = "Wiz Work Report Tool $ReleaseVersion"
  if ($releaseExists) {
    gh release edit $Tag --title $title --notes-file $NotesFile
    gh release upload $Tag $Assets --clobber
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
Set-Content -LiteralPath $notesFile -Value $releaseNotes -Encoding UTF8

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
  flutter pub run msix:create --build-windows false
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
} finally {
  Pop-Location
}

$assets = @($androidApk.FullName, $windowsMsix.FullName, $windowsZip.FullName)
Ensure-GitHubRelease $tag $Version $notesFile $assets

Write-Host ""
Write-Host "Release completed: $tag"
Write-Host "Android APK: $($androidApk.FullName)"
Write-Host "Windows MSIX: $($windowsMsix.FullName)"
Write-Host "Windows ZIP: $($windowsZip.FullName)"
