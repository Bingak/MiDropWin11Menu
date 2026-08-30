@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul 2>&1
title MiDrop Win11 右键菜单 - 一键安装
cd /d "%~dp0"

rem ============================================================
rem  MiDrop Win11 右键菜单 一键安装
rem  https://github.com/Bingak/MiDropWin11Menu
rem ============================================================

set "PS1=%~dp0MiDrop-Menu.ps1"

if not exist "%PS1%" (
    echo.
    echo [XX] 找不到 MiDrop-Menu.ps1
    echo     请确保它与本文件在同一个文件夹里。
    echo.
    pause
    exit /b 1
)

echo.
echo 正在检查管理员权限 ...

net session >nul 2>&1
if %ERRORLEVEL% EQU 0 goto :ADMIN

rem -------- 未拥有管理员权限，请求 UAC 提升 --------
echo [!!] 需要管理员权限，正在请求提升 ...
echo      请在弹出的窗口里点「是」。
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p = '%PS1%' -replace \"'\", \"''\"; Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"`\"$p`\"\") -Verb RunAs -Wait"

echo.
echo [!!] 如果刚才没有弹出权限窗口，或你在窗口里点了「否」，脚本无法运行。
echo      也可以右键本文件，选「以管理员身份运行」。
echo.
pause
exit /b 1

:ADMIN
echo [OK] 已获得管理员权限。
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo [!!] 脚本退出码: %RC%
)
echo 已完成。按任意键关闭窗口...
pause >nul
endlocal
exit /b %RC%
