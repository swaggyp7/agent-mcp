@echo off
setlocal
REM ===== config, only edit these 2 lines =====
if not defined INSTALL_DIR set "INSTALL_DIR=%~dp0"
if not defined WORK_DIR set "WORK_DIR=%~dp0workspace"
REM ===========================================
REM INSTALL_DIR = green root, all files live here, no spaces in name
REM WORK_DIR = agent-mcp --root, file sandbox for read/write/edit/shell
cd /d %~dp0
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0init.ps1" -InstallDir "%INSTALL_DIR%" -WorkDir "%WORK_DIR%"
pause
