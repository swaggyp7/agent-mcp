#Requires -Version 7
param(
  [string]$InstallDir = $PSScriptRoot,
  [string]$WorkDir = (Join-Path $InstallDir "workspace"),
  [string]$Uac = 'false',
  [int]$Port = 8765,
  [string]$PublicUrl = '',
  [string]$AllowedHost = '',
  [string]$AllowedOrigin = '',
  [string]$Stateless = 'true',
  [string]$JsonResponse = 'true',
  [string]$AuditLog = 'true'
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$InstallDir = $InstallDir.TrimEnd('\')
$WorkDir = $WorkDir.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = $PSScriptRoot }

$WantAdmin = $Uac -eq 'true' -or $Uac -eq '1'
if ($WantAdmin) {
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    $relaunchArgs = @(
      '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",
      '-InstallDir',"`"$InstallDir`"",
      '-WorkDir',"`"$WorkDir`"",
      '-Uac','true',
      '-Port',"$Port",
      '-PublicUrl',"`"$PublicUrl`"",
      '-AllowedHost',"`"$AllowedHost`"",
      '-AllowedOrigin',"`"$AllowedOrigin`"",
      '-Stateless',"`"$Stateless`"",
      '-JsonResponse',"`"$JsonResponse`"",
      '-AuditLog',"`"$AuditLog`""
    )
    Start-Process pwsh -Verb RunAs -ArgumentList $relaunchArgs
    exit
  }
}

$DataDir = Join-Path $InstallDir 'data'
$LogDir = Join-Path $DataDir 'logs'
$TempDir = Join-Path $DataDir 'temp'
$SrcDir = Join-Path $InstallDir 'src\agent-mcp'
foreach ($d in @($DataDir,$LogDir,$TempDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir "run-$stamp.log"
Start-Transcript -Path $logFile -Append | Out-Null
try {
  # --- same redirects as init, process-local only ---
  $env:UV_CACHE_DIR = Join-Path $DataDir '.uv-cache'
  $env:UV_PYTHON_INSTALL_DIR = Join-Path $DataDir '.uv-python'
  $env:UV_TOOL_DIR = Join-Path $DataDir '.uv-tools'
  $env:UV_TOOL_BIN_DIR = Join-Path $DataDir '.uv-tools\bin'
  $env:UV_DIR = Join-Path $DataDir 'uv'
  $env:UV_PROJECT_ENVIRONMENT = Join-Path $DataDir '.venv'
  $env:TEMP = $TempDir
  $env:TMP = $TempDir
  $env:GIT_CONFIG_GLOBAL = Join-Path $InstallDir 'config\gitconfig'
  $env:GIT_CONFIG_SYSTEM = Join-Path $InstallDir 'config\gitconfig-system'
  $env:GIT_CONFIG_NOSYSTEM = '1'

  $portableUv = Join-Path $InstallDir 'tools\uv\uv.exe'
  $uvExe = if (Test-Path $portableUv) { $portableUv } elseif (Get-Command uv -ErrorAction SilentlyContinue) { 'uv' } else { throw 'uv not found, run init.bat first' }
  if (-not (Test-Path $SrcDir)) { throw "src not found: $SrcDir, run init.bat first" }
  if (-not (Test-Path $env:UV_PROJECT_ENVIRONMENT)) { throw "venv not found: $($env:UV_PROJECT_ENVIRONMENT), run init.bat first" }

  # --- prefer physical NIC IPv4, avoid virtual adapters (WSL/VMware/Hyper-V) ---
  $physIfs = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' } |
    Select-Object -ExpandProperty ifIndex)
  $candidates = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
      $_.IPAddress -notlike '127.*' -and
      $_.IPAddress -notlike '169.254.*' -and
      $_.InterfaceAlias -notlike '*Loopback*' -and
      $_.InterfaceAlias -notlike '*vEthernet*' -and
      $_.InterfaceAlias -notlike '*WSL*' -and
      $_.InterfaceAlias -notlike '*VMware*' -and
      $_.InterfaceAlias -notlike '*VirtualBox*'
    })
  $ip = $null
  if ($physIfs.Count -gt 0) {
    $ip = ($candidates | Where-Object { $physIfs -contains $_.InterfaceIndex -and $_.IPAddress -like '192.168.*' } | Select-Object -First 1).IPAddress
    if (-not $ip) {
      $ip = ($candidates | Where-Object { $physIfs -contains $_.InterfaceIndex } | Select-Object -First 1).IPAddress
    }
  }
  if (-not $ip) {
    $ip = ($candidates | Where-Object { $_.IPAddress -like '192.168.*' } | Select-Object -First 1).IPAddress
  }
  if (-not $ip) { throw 'No usable LAN IPv4 found' }

  $tokenFile = Join-Path $DataDir '.token'
  if (-not (Test-Path $tokenFile)) {
    $bytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    [Convert]::ToBase64String($bytes) | Set-Content $tokenFile -NoNewline
  }
  $env:AGENT_MCP_TOKEN = (Get-Content $tokenFile -Raw).Trim()

  $mcpArgs = @(
    'run', '--project', $SrcDir, 'agent-mcp',
    '--root', $WorkDir,
    '--host', $ip,
    '--port', "$Port",
    '--token', $env:AGENT_MCP_TOKEN
  )

  if ($Stateless -eq 'true' -or $Stateless -eq '1') {
    $mcpArgs += '--stateless'
  }
  if ($JsonResponse -eq 'true' -or $JsonResponse -eq '1') {
    $mcpArgs += '--json-response'
  }

  $hostList = @()
  if (-not [string]::IsNullOrWhiteSpace($AllowedHost)) {
    $hostList += ($AllowedHost -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  }
  if (-not [string]::IsNullOrWhiteSpace($PublicUrl)) {
    $mcpArgs += @('--public-url', $PublicUrl.Trim())
    try {
      $uriHost = ([Uri]$PublicUrl.Trim()).Host
      if ($uriHost -and ($hostList -notcontains $uriHost)) {
        $hostList += $uriHost
      }
    } catch {
      Write-Warning "Invalid PublicUrl format: $PublicUrl"
    }
  } else {
    Write-Warning 'PUBLIC_URL is empty; if exposing via Nginx with Host forwarding, set PUBLIC_URL / ALLOWED_HOST in run.bat.'
  }
  foreach ($h in $hostList) {
    $mcpArgs += @('--allowed-host', $h)
  }

  if (-not [string]::IsNullOrWhiteSpace($AllowedOrigin)) {
    foreach ($o in ($AllowedOrigin -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
      $mcpArgs += @('--allowed-origin', $o)
    }
  }

  $auditLogPath = $null
  if ($AuditLog -eq 'true' -or $AuditLog -eq '1') {
    $auditLogPath = Join-Path $LogDir 'audit.jsonl'
  } elseif ($AuditLog -and $AuditLog -ne 'false' -and $AuditLog -ne '0') {
    $auditLogPath = $AuditLog
  }
  if ($auditLogPath) {
    $mcpArgs += @('--audit-log', $auditLogPath)
  }

  Write-Host "INSTALL_DIR=$InstallDir"
  Write-Host "WORK_DIR=$WorkDir"
  Write-Host "Listen on ${ip}:${Port}"
  Write-Host "MCP=http://${ip}:${Port}/mcp"
  if ($PublicUrl) { Write-Host "PUBLIC_URL=$PublicUrl" }
  if ($hostList.Count -gt 0) { Write-Host "ALLOWED_HOSTS=$($hostList -join ',')" }
  Write-Host "LOG=$logFile"
  if ($auditLogPath) { Write-Host "AUDIT_LOG=$auditLogPath" }
  Write-Host "TOKEN_FILE=$tokenFile"

  & $uvExe @mcpArgs
} finally {
  Stop-Transcript | Out-Null
}
