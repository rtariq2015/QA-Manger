@echo off
setlocal DisableDelayedExpansion
set "CTQA_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "CTQA_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%CTQA_PS%" goto no_powershell
set "CTQA_LOGDIR=%~dp0Logs"
if not exist "%CTQA_LOGDIR%" mkdir "%CTQA_LOGDIR%" 2>nul
if not exist "%CTQA_LOGDIR%" set "CTQA_LOGDIR=%TEMP%"
"%CTQA_PS%" -NoLogo -NoProfile -STA -File "%~dp0App\Start.ps1" -PortableLaunch > "%CTQA_LOGDIR%\Startup.log" 2>&1
if errorlevel 1 goto failed
exit /b 0
:no_powershell
echo CT QA Manager Pro needs the Windows PowerShell supplied with Windows.
echo Ask hospital IT to check this workstation. No administrator launch is required.
pause
exit /b 1
:failed
echo.
echo CT QA Manager Pro could not start or encountered an application error.
echo Please keep this window open and share the following details with hospital IT.
echo.
type "%CTQA_LOGDIR%\Startup.log"
echo.
echo If scripts are blocked, ask IT to approve or sign the application.
echo Do not change execution policy or disable endpoint protection.
echo Startup details: "%CTQA_LOGDIR%\Startup.log"
pause
exit /b 1
