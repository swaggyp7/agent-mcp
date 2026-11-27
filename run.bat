@echo off
setlocal
REM ===== config, only edit these lines =====
if not defined INSTALL_DIR set "INSTALL_DIR=%~dp0"
if not defined WORK_DIR set "WORK_DIR=%~dp0workspace"
if not defined UAC set "UAC=false"
if not defined PORT set "PORT=8765"
REM --- Nginx reverse proxy settings (leave PUBLIC_URL empty for LAN-only) ---
if not defined PUBLIC_URL set "PUBLIC_URL="
if not defined ALLOWED_HOST set "ALLOWED_HOST="
if not defined ALLOWED_ORIGIN set "ALLOWED_ORIGIN="
if not defined STATELESS set "STATELESS=true"
if not defined JSON_RESPONSE set "JSON_RESPONSE=true"
if not defined AUDIT_LOG set "AUDIT_LOG=true"
REM ===========================================
REM INSTALL_DIR = green root, folder containing run.ps1
REM WORK_DIR = agent-mcp --root, file sandbox
REM UAC = true/false, true = relaunch as admin
cd /d %~dp0
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" -InstallDir "%INSTALL_DIR%" -WorkDir "%WORK_DIR%" -Uac "%UAC%" -Port "%PORT%" -PublicUrl "%PUBLIC_URL%" -AllowedHost "%ALLOWED_HOST%" -AllowedOrigin "%ALLOWED_ORIGIN%" -Stateless "%STATELESS%" -JsonResponse "%JSON_RESPONSE%" -AuditLog "%AUDIT_LOG%"
pause
