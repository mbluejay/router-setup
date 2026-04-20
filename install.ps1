# VLESS TProxy installer — Windows PowerShell launcher
#
# Основная логика в install.sh (bash). Этот скрипт находит Git Bash или WSL
# и запускает через них install.sh. Если ни того ни другого нет — подсказывает
# что поставить.
#
# Запуск:
#   .\install.ps1
# Если PowerShell ругается на политику:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$installSh = Join-Path $scriptDir 'install.sh'

function Write-Step    { param($msg) Write-Host "`n▶ $msg" -ForegroundColor Blue }
function Write-Ok      { param($msg) Write-Host "[ OK ] $msg" -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err     { param($msg) Write-Host "[ERR ] $msg" -ForegroundColor Red }

function Find-GitBash {
    # Обычные пути установки Git for Windows
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe",
        "$env:USERPROFILE\AppData\Local\Programs\Git\bin\bash.exe"
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path $path)) { return $path }
    }
    # В PATH?
    $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Test-Wsl {
    $cmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    # wsl --status возвращает ненулевой код если WSL не инициализирован
    try {
        $null = & wsl.exe --status 2>&1
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Test-Ssh {
    return [bool](Get-Command ssh.exe -ErrorAction SilentlyContinue)
}

# ═════════════════════════════════════════════════════════════════════
# Sanity: install.sh рядом?
# ═════════════════════════════════════════════════════════════════════

if (-not (Test-Path $installSh)) {
    Write-Err "Не найден $installSh"
    Write-Host "Запусти этот скрипт из папки public/ репозитория." -ForegroundColor Yellow
    exit 1
}

# ═════════════════════════════════════════════════════════════════════
# Детект shell-а
# ═════════════════════════════════════════════════════════════════════

Write-Step "Ищу shell для запуска install.sh"

$gitBash = Find-GitBash
if ($gitBash) {
    Write-Ok "Git Bash найден: $gitBash"
    $useGitBash = $true
} else {
    Write-Warn "Git Bash не найден"
    $useGitBash = $false
}

if (-not $useGitBash) {
    if (Test-Wsl) {
        Write-Ok "WSL доступен"
        $useWsl = $true
    } else {
        Write-Warn "WSL не установлен"
        $useWsl = $false
    }
} else {
    $useWsl = $false
}

if (-not $useGitBash -and -not $useWsl) {
    Write-Err "Не найден ни Git Bash, ни WSL"
    Write-Host ""
    Write-Host "Установи Git for Windows (рекомендуется):" -ForegroundColor Cyan
    Write-Host "  https://git-scm.com/download/win" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Или включи WSL:"
    Write-Host "  PowerShell (Admin): wsl --install"
    Write-Host ""
    Write-Host "После установки перезапусти этот скрипт."
    exit 1
}

# ═════════════════════════════════════════════════════════════════════
# Проверка ssh/scp
# ═════════════════════════════════════════════════════════════════════

if (-not (Test-Ssh)) {
    Write-Warn "ssh.exe не найден в PATH"
    Write-Host ""
    Write-Host "В Windows 10/11 OpenSSH Client встроен, но может быть выключен." -ForegroundColor Cyan
    Write-Host "Включить: Settings → Apps → Optional features → Add feature → OpenSSH Client"
    Write-Host "Либо PowerShell (Admin):"
    Write-Host "  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    Write-Host ""
    Write-Host "Если используешь WSL — ssh будет из WSL-окружения, это ок."
    $ans = Read-Host "Продолжить? [y/N]"
    if ($ans -ne 'y' -and $ans -ne 'Y') { exit 1 }
}

# ═════════════════════════════════════════════════════════════════════
# Запуск install.sh
# ═════════════════════════════════════════════════════════════════════

Write-Step "Запускаю install.sh"

if ($useGitBash) {
    # Git Bash использует POSIX пути. Запускаем напрямую.
    & $gitBash -c "cd '$($scriptDir.Replace('\', '/'))' && ./install.sh"
    $exitCode = $LASTEXITCODE
} elseif ($useWsl) {
    # WSL видит Windows-диски как /mnt/c/...
    $wslPath = $scriptDir -replace '^([A-Z]):', { "/mnt/$($_.Groups[1].Value.ToLower())" } -replace '\\', '/'
    & wsl.exe bash -c "cd '$wslPath' && ./install.sh"
    $exitCode = $LASTEXITCODE
}

if ($exitCode -ne 0) {
    Write-Warn "install.sh завершился с кодом $exitCode"
}
exit $exitCode
