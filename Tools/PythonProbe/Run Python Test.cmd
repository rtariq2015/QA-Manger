@echo off
setlocal DisableDelayedExpansion
title CT QA - Portable Python Test
if not exist "%~dp0runtime\python.exe" goto missing_runtime
if /i "%~1"=="--no-open" goto unattended
if /i "%~1"=="--pdf" goto explicit_pdf
if "%~1"=="" goto standard
"%~dp0runtime\python.exe" -I -B -S "%~dp0probe.py" --pdf "%~1"
goto finished
:explicit_pdf
"%~dp0runtime\python.exe" -I -B -S "%~dp0probe.py" --pdf "%~2"
goto finished
:standard
"%~dp0runtime\python.exe" -I -B -S "%~dp0probe.py"
:finished
set "CTQA_PROBE_EXIT=%ERRORLEVEL%"
echo.
if not "%CTQA_PROBE_EXIT%"=="0" echo A test failed. Open Results\ProbeResult.html if it was created.
pause
exit /b %CTQA_PROBE_EXIT%
:unattended
if /i "%~2"=="--pdf" goto unattended_pdf
"%~dp0runtime\python.exe" -I -B -S "%~dp0probe.py" --no-open
exit /b %ERRORLEVEL%
:unattended_pdf
"%~dp0runtime\python.exe" -I -B -S "%~dp0probe.py" --no-open --pdf "%~3"
exit /b %ERRORLEVEL%
:missing_runtime
echo The included Python runtime is missing. Extract the complete test ZIP again.
if /i "%~1"=="--no-open" exit /b 1
pause
exit /b 1
