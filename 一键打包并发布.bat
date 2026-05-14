@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\release.ps1"
set "EXIT_CODE=%ERRORLEVEL%"

echo.
if "%EXIT_CODE%"=="0" (
  echo Release completed.
) else (
  echo Release failed. Exit code: %EXIT_CODE%
)
pause
exit /b %EXIT_CODE%
