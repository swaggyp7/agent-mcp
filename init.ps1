#Requires -Version 7
param(
  [string]$InstallDir = $PSScriptRoot,
  [string]$WorkDir = (Join-Path $InstallDir "workspace")
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$InstallDir = $InstallDir.TrimEnd('\')
$WorkDir = $WorkDir.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($WorkDir)) { $WorkDir = Join-Path $InstallDir "workspace" }

# If init is run from elsewhere, copy launchers and patch into INSTALL_DIR first
if ($PSScriptRoot -ne $InstallDir) {
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  foreach ($f in @('init.bat','init.ps1','run.bat','run.ps1','run_uac.bat','agent-mcp-audit-log.patch')) {
    $src = Join-Path $PSScriptRoot $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $InstallDir $f) -Force }
  }
}

$ToolsDir = Join-Path $InstallDir 'tools'
$SrcDir = Join-Path $InstallDir 'src\agent-mcp'
$DataDir = Join-Path $InstallDir 'data'
$LogDir = Join-Path $DataDir 'logs'
$TempDir = Join-Path $DataDir 'temp'
$DlDir = Join-Path $DataDir 'downloads'
$ConfigDir = Join-Path $InstallDir 'config'
foreach ($d in @($InstallDir,$ToolsDir,$SrcDir,$DataDir,$LogDir,$TempDir,$DlDir,$ConfigDir,$WorkDir)) {
  New-Item -ItemType Directory -Force -Path $d | Out-Null
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $LogDir "init-$stamp.log"
Start-Transcript -Path $logFile -Append | Out-Null
try {
  Write-Host "INSTALL_DIR=$InstallDir"
  Write-Host "WORK_DIR=$WorkDir"
  Write-Host "LOG=$logFile"

  # --- redirect every shit-folder into INSTALL_DIR, process-local only ---
  $env:UV_CACHE_DIR = Join-Path $DataDir '.uv-cache'
  $env:UV_PYTHON_INSTALL_DIR = Join-Path $DataDir '.uv-python'
  $env:UV_TOOL_DIR = Join-Path $DataDir '.uv-tools'
  $env:UV_TOOL_BIN_DIR = Join-Path $DataDir '.uv-tools\bin'
  $env:UV_DIR = Join-Path $DataDir 'uv'
  $env:UV_PROJECT_ENVIRONMENT = Join-Path $DataDir '.venv'
  $env:TEMP = $TempDir
  $env:TMP = $TempDir
  $env:GIT_CONFIG_GLOBAL = Join-Path $ConfigDir 'gitconfig'
  $env:GIT_CONFIG_SYSTEM = Join-Path $ConfigDir 'gitconfig-system'
  $env:GIT_CONFIG_NOSYSTEM = '1'
  if (-not (Test-Path $env:GIT_CONFIG_GLOBAL)) { '' | Set-Content $env:GIT_CONFIG_GLOBAL }
  if (-not (Test-Path $env:GIT_CONFIG_SYSTEM)) { '' | Set-Content $env:GIT_CONFIG_SYSTEM }
  foreach ($d in @($env:UV_CACHE_DIR,$env:UV_PYTHON_INSTALL_DIR,$env:UV_TOOL_DIR,$env:UV_TOOL_BIN_DIR)) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
  }

  # --- git: prefer portable inside tools, else system git, else download portable ---
  $portableGit = Join-Path $ToolsDir 'git\cmd\git.exe'
  $gitExe = $null
  if (Test-Path $portableGit) { $gitExe = $portableGit }
  elseif (Get-Command git -ErrorAction SilentlyContinue) { $gitExe = 'git' }
  else {
    $gitVer = '2.52.0'
    $gitUrl = "https://github.com/git-for-windows/git/releases/download/v$gitVer.windows.1/PortableGit-$gitVer-64-bit.7z.exe"
    $gitDl = Join-Path $DlDir "PortableGit-$gitVer-64-bit.7z.exe"
    Write-Host "Downloading PortableGit $gitVer ..."
    Invoke-WebRequest -Uri $gitUrl -OutFile $gitDl -UseBasicParsing
    $gitRoot = Join-Path $ToolsDir 'git'
    Write-Host "Extracting to $gitRoot ..."
    Start-Process -FilePath $gitDl -ArgumentList "-o`"$gitRoot`"",'-y' -Wait -NoNewWindow
    $post = Join-Path $gitRoot 'post-install.bat'
    if (Test-Path $post) { Start-Process -FilePath $post -WorkingDirectory $gitRoot -Wait -NoNewWindow }
    if (-not (Test-Path $portableGit)) { throw 'PortableGit extract failed, no cmd\git.exe' }
    $gitExe = $portableGit
  }
  Write-Host "git = $gitExe"
  & $gitExe --version

  # --- uv: prefer portable inside tools, else system uv, else download zip ---
  $portableUv = Join-Path $ToolsDir 'uv\uv.exe'
  $uvExe = $null
  if (Test-Path $portableUv) { $uvExe = $portableUv }
  elseif (Get-Command uv -ErrorAction SilentlyContinue) { $uvExe = 'uv' }
  else {
    $uvZip = Join-Path $DlDir 'uv-x86_64-pc-windows-msvc.zip'
    $uvUrl = 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip'
    Write-Host 'Downloading uv latest ...'
    Invoke-WebRequest -Uri $uvUrl -OutFile $uvZip -UseBasicParsing
    $uvRoot = Join-Path $ToolsDir 'uv'
    New-Item -ItemType Directory -Force -Path $uvRoot | Out-Null
    Expand-Archive -Path $uvZip -DestinationPath $uvRoot -Force
    if (-not (Test-Path $portableUv)) { throw 'uv zip extract failed, no uv.exe' }
    $uvExe = $portableUv
  }
  Write-Host "uv = $uvExe"
  & $uvExe --version

  # Make portable tools visible to this process only, not system PATH.
  $pathParts = @()
  foreach ($d in @((Split-Path $portableUv -Parent), (Split-Path $portableGit -Parent))) {
    if (Test-Path $d) { $pathParts += $d }
  }
  if ($pathParts.Count -gt 0) { $env:Path = "$($pathParts -join ';');$env:Path" }

  # --- clone or pull agent-mcp into src, and apply audit-log patch ---
  $patchFile = Join-Path $InstallDir 'agent-mcp-audit-log.patch'
  $hasPatch = Test-Path $patchFile
  if (Test-Path (Join-Path $SrcDir '.git')) {
    if ($hasPatch) {
      & $gitExe -C $SrcDir apply --reverse --check $patchFile 2>$null
      if ($LASTEXITCODE -eq 0) {
        Write-Host 'Reverting existing audit-log patch before git pull ...'
        & $gitExe -C $SrcDir apply --reverse $patchFile
      }
    }
    Write-Host 'agent-mcp already cloned, pulling ...'
    & $gitExe -C $SrcDir pull --ff-only
  } else {
    Write-Host 'Cloning agent-mcp ...'
    & $gitExe clone https://github.com/uukelele/agent-mcp.git $SrcDir
  }

  if ($hasPatch) {
    & $gitExe -C $SrcDir apply --reverse --check $patchFile 2>$null
    if ($LASTEXITCODE -eq 0) {
      Write-Host 'audit-log patch already applied.'
    } else {
      Write-Host 'Applying agent-mcp-audit-log.patch ...'
      & $gitExe -C $SrcDir apply $patchFile
      if ($LASTEXITCODE -ne 0) { throw "Failed to apply patch: $patchFile" }
      Write-Host 'Patch applied.'
    }
  } else {
    Write-Warning "Patch file not found: $patchFile (skipping)"
  }

  # --- uv sync, venv lives in data\.venv ---
  Write-Host 'uv sync ...'
  & $uvExe sync --project $SrcDir --python 3.12
  Write-Host 'uv sync done.'

  # --- green-root gitignore ---
  @'
data/.venv/
data/.uv-cache/
data/.uv-python/
data/.uv-tools/
data/uv/
data/temp/
data/downloads/
data/logs/
data/.token
'@ | Set-Content (Join-Path $InstallDir '.gitignore') -Encoding UTF8

  Write-Host ''
  Write-Host 'INIT OK'
  Write-Host "INSTALL_DIR=$InstallDir"
  Write-Host "SRC=$SrcDir"
  Write-Host "VENV=$($env:UV_PROJECT_ENVIRONMENT)"
  Write-Host "LOG=$logFile"
  Write-Host 'Next: edit PUBLIC_URL in run.bat (if using Nginx) and double-click run.bat'
} finally {
  Stop-Transcript | Out-Null
}
