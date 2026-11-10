@echo off
setlocal DisableDelayedExpansion
set "CTQA_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if defined PROCESSOR_ARCHITEW6432 set "CTQA_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%CTQA_PS%" -NoLogo -NoProfile -STA -File "%~dp0App\ExportDiagnostics.ps1" %*
set "CTQA_EXIT=%ERRORLEVEL%"
pause
exit /b %CTQA_EXIT%
