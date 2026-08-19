Unicode true

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "FileFunc.nsh"

!insertmacro GetParameters

!ifndef VERSION
  !define VERSION "0.0.0"
!endif

!ifndef SOURCE_DIR
  !error "SOURCE_DIR is required"
!endif

!ifndef OUT_FILE
  !define OUT_FILE "WizWorkReport_Setup.exe"
!endif

!define APP_NAME "威智工作汇报器"
!define APP_ID "WizWorkReportTool"
!define APP_EXE "work_report_generator.exe"
!define APP_PUBLISHER "Wiz"

Name "${APP_NAME}"
OutFile "${OUT_FILE}"
InstallDir "C:\${APP_NAME}"
InstallDirRegKey HKLM "Software\${APP_ID}" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma

!define MUI_ABORTWARNING
!define MUI_LANGDLL_ALWAYSSHOW
!ifdef ICON_PATH
  !define MUI_ICON "${ICON_PATH}"
  !define MUI_UNICON "${ICON_PATH}"
!endif

!define MUI_FINISHPAGE_RUN "$INSTDIR\${APP_EXE}"
!define MUI_FINISHPAGE_RUN_TEXT "启动 ${APP_NAME}"
!define MUI_FINISHPAGE_SHOWREADME "$INSTDIR\README.md"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "查看 README"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

!define MUI_LANGDLL_REGISTRY_ROOT "HKLM"
!define MUI_LANGDLL_REGISTRY_KEY "Software\${APP_ID}"
!define MUI_LANGDLL_REGISTRY_VALUENAME "Installer Language"

Function .onInit
  ${GetParameters} $1
  UserInfo::GetAccountType
  Pop $0
  ${If} $0 != "Admin"
    ExecShell "runas" "$EXEPATH" "$1"
    Quit
  ${EndIf}
  IfSilent skipLanguage
  !insertmacro MUI_LANGDLL_DISPLAY
skipLanguage:
FunctionEnd

Section "Install"
  SetShellVarContext all
  IfSilent 0 installFiles
    nsExec::ExecToLog 'taskkill /IM "${APP_EXE}" /F'
    ; 等待进程完全退出并释放文件句柄，否则 File /r 覆盖 exe/DLL 时会
    ; 因文件被占用而跳过，导致安装不完整、双击 exe 无反应。
    Sleep 2000

installFiles:
  ; 先清空旧目录（保留 Uninstall.exe），避免旧版本残留文件干扰
  ; 静默更新时尤为重要：旧 DLL 可能与新 exe 不兼容
  IfSilent 0 copyFiles
    Delete "$INSTDIR\${APP_EXE}"
    Delete "$INSTDIR\flutter_windows.dll"
    RMDir /r "$INSTDIR\data"
    RMDir /r "$INSTDIR\plugins"
    Delete "$INSTDIR\*.dll"

copyFiles:
  SetOutPath "$INSTDIR"
  File /r "${SOURCE_DIR}\*.*"

  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  WriteRegStr HKLM "Software\${APP_ID}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" "DisplayName" "${APP_NAME}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" "DisplayIcon" "$INSTDIR\${APP_EXE}"
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" "NoModify" 1
  WriteRegDWORD HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" "NoRepair" 1

  WriteUninstaller "$INSTDIR\Uninstall.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}" "UninstallString" "$\"$INSTDIR\Uninstall.exe$\""

  IfSilent 0 installDone
    ; 静默更新后用 ExecShell（而非 Exec）启动应用，确保在用户交互桌面显示
    ExecShell "" "$INSTDIR\${APP_EXE}"

installDone:
SectionEnd

Section "Uninstall"
  SetShellVarContext all
  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  RMDir "$SMPROGRAMS\${APP_NAME}"

  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_ID}"
  DeleteRegKey HKLM "Software\${APP_ID}"

  RMDir /r "$INSTDIR"
SectionEnd
