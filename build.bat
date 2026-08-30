@echo off
rem Build fxshot with MSVC. Works from a plain prompt or a developer prompt.
setlocal enabledelayedexpansion
pushd "%~dp0"

rem A cl.exe on PATH is not enough: without the rest of the developer
rem environment it cannot find the headers or libraries.
if defined VCINSTALLDIR goto :compile

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :novs

for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH goto :novs

call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul
where cl.exe >nul 2>&1
if not %ERRORLEVEL%==0 goto :novs

:compile
cl /nologo /EHsc /O2 /std:c++17 src\fxshot.cpp /Fe:fxshot.exe /link /SUBSYSTEM:CONSOLE
set BUILD_RESULT=%ERRORLEVEL%
popd
exit /b %BUILD_RESULT%

:novs
echo Could not find the MSVC compiler.
echo Install Visual Studio with the "Desktop development with C++" workload,
echo or run this from a Developer Command Prompt.
popd
exit /b 1
