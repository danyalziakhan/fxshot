@echo off
rem Build reshadefxc.exe, ReShade's own effect compiler, from a ReShade source
rem checkout:  build.bat C:\src\reshade
rem stubs.cpp stands in for the GLSL and SPIR-V back ends, which D3D11 does not
rem need, and version.h replaces the header ReShade generates in its own build.
setlocal
if "%~1"=="" goto :usage
set "R=%~f1"
if not exist "%R%\tools\fxc.cpp" goto :usage
pushd "%~dp0"

if defined VCINSTALLDIR goto :compile
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" goto :novs
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if not defined VSPATH goto :novs
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul

:compile
cl /nologo /O2 /EHsc /std:c++17 /MP /DNDEBUG /I. /I"%R%\source" /I"%R%\include" "%R%\tools\fxc.cpp" "%R%\source\effect_codegen_hlsl.cpp" "%R%\source\effect_codegen_dxbc.cpp" stubs.cpp "%R%\source\effect_expression.cpp" "%R%\source\effect_lexer.cpp" "%R%\source\effect_parser_exp.cpp" "%R%\source\effect_parser_stmt.cpp" "%R%\source\effect_preprocessor.cpp" "%R%\source\effect_symbol_table.cpp" /Fe:reshadefxc.exe /link d3dcompiler.lib
set BUILD_RESULT=%ERRORLEVEL%
del /q *.obj 2>nul
popd
exit /b %BUILD_RESULT%

:usage
echo usage: build.bat RESHADE_SOURCE_DIR
echo The directory is a ReShade source checkout, the one holding tools\fxc.cpp.
exit /b 1

:novs
echo Could not find the MSVC compiler. Run this from a Developer Command Prompt.
popd
exit /b 1
