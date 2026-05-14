param(
    [string]$DeviceId = "",
    [switch]$ReleaseInstall
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $ProjectRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$FlutterLog = Join-Path $LogDir "flutter_run_$Timestamp.log"
$LogcatLog = Join-Path $LogDir "adb_logcat_$Timestamp.log"
$EventsLog = Join-Path $LogDir "adb_getevent_$Timestamp.log"
$ScreenRecordDevice = "/sdcard/work_report_debug_$Timestamp.mp4"
$ScreenRecordLocal = Join-Path $LogDir "screenrecord_$Timestamp.mp4"
$SummaryLog = Join-Path $LogDir "debug_session_$Timestamp.txt"

if ([string]::IsNullOrWhiteSpace($DeviceId)) {
    $DeviceId = (adb devices | Select-String "device$" | ForEach-Object { ($_ -split "\s+")[0] } | Select-Object -First 1)
}

if ([string]::IsNullOrWhiteSpace($DeviceId)) {
    throw "No authorized Android device found. Run 'adb devices -l' and accept USB debugging on the phone."
}

Write-Host "Project: $ProjectRoot"
Write-Host "Device:  $DeviceId"
Write-Host "Flutter: $FlutterLog"
Write-Host "Logcat:  $LogcatLog"
Write-Host "Events:  $EventsLog"
Write-Host "Screen:  $ScreenRecordLocal"
Write-Host "Summary: $SummaryLog"
Write-Host ""
Write-Host "The app will start in debug mode. Reproduce the issue on the phone."
Write-Host "Press q in this terminal to quit flutter run."
Write-Host ""

"Project: $ProjectRoot" | Set-Content -LiteralPath $SummaryLog -Encoding UTF8
"Device:  $DeviceId" | Add-Content -LiteralPath $SummaryLog -Encoding UTF8
"Started: $(Get-Date -Format o)" | Add-Content -LiteralPath $SummaryLog -Encoding UTF8

adb -s $DeviceId wait-for-device
adb -s $DeviceId logcat -c

$LogcatProcess = Start-Process -FilePath "adb" `
    -ArgumentList @("-s", $DeviceId, "logcat", "-v", "time") `
    -RedirectStandardOutput $LogcatLog `
    -RedirectStandardError (Join-Path $LogDir "adb_logcat_$Timestamp.err.log") `
    -PassThru `
    -NoNewWindow

$EventsProcess = Start-Process -FilePath "adb" `
    -ArgumentList @("-s", $DeviceId, "shell", "getevent", "-lt") `
    -RedirectStandardOutput $EventsLog `
    -RedirectStandardError (Join-Path $LogDir "adb_getevent_$Timestamp.err.log") `
    -PassThru `
    -NoNewWindow

$ScreenRecordProcess = Start-Process -FilePath "adb" `
    -ArgumentList @("-s", $DeviceId, "shell", "screenrecord", "--bugreport", $ScreenRecordDevice) `
    -RedirectStandardOutput (Join-Path $LogDir "screenrecord_$Timestamp.out.log") `
    -RedirectStandardError (Join-Path $LogDir "screenrecord_$Timestamp.err.log") `
    -PassThru `
    -NoNewWindow

try {
    if ($ReleaseInstall) {
        flutter build apk --release 2>&1 | Tee-Object -FilePath $FlutterLog
        adb -s $DeviceId install -r (Join-Path $ProjectRoot "build\app\outputs\flutter-apk\app-release.apk") 2>&1 | Tee-Object -FilePath $FlutterLog -Append
        adb -s $DeviceId shell monkey -p com.example.work_report_generator 1 2>&1 | Tee-Object -FilePath $FlutterLog -Append
        Write-Host "Release APK installed. Reproduce the issue on the phone, then press Enter here."
        Read-Host | Out-Null
    }
    else {
        flutter run -d $DeviceId --debug --verbose 2>&1 | Tee-Object -FilePath $FlutterLog
    }
}
finally {
    if (-not $LogcatProcess.HasExited) {
        Stop-Process -Id $LogcatProcess.Id -Force
    }
    if (-not $EventsProcess.HasExited) {
        Stop-Process -Id $EventsProcess.Id -Force
    }
    if (-not $ScreenRecordProcess.HasExited) {
        Stop-Process -Id $ScreenRecordProcess.Id -Force
    }
    Start-Sleep -Seconds 1
    adb -s $DeviceId pull $ScreenRecordDevice $ScreenRecordLocal | Out-Null
    adb -s $DeviceId shell rm $ScreenRecordDevice | Out-Null
    "Finished: $(Get-Date -Format o)" | Add-Content -LiteralPath $SummaryLog -Encoding UTF8
    "FlutterLog: $FlutterLog" | Add-Content -LiteralPath $SummaryLog -Encoding UTF8
    "LogcatLog: $LogcatLog" | Add-Content -LiteralPath $SummaryLog -Encoding UTF8
    "EventsLog: $EventsLog" | Add-Content -LiteralPath $SummaryLog -Encoding UTF8
    "ScreenRecord: $ScreenRecordLocal" | Add-Content -LiteralPath $SummaryLog -Encoding UTF8
    Write-Host ""
    Write-Host "Logs saved:"
    Write-Host $FlutterLog
    Write-Host $LogcatLog
    Write-Host $EventsLog
    Write-Host $ScreenRecordLocal
    Write-Host $SummaryLog
}
