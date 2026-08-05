#Requires -Version 5.1
<#
.SYNOPSIS
    Guided installer for Obsidian Vault Sync on Windows.
.DESCRIPTION
    Automates everything except the steps that genuinely need a human:
    pasting the public key into GitHub and confirming the repository URL.
    Idempotent: re-run it as often as you like.
.EXAMPLE
    .\setup.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir   = Join-Path $env:LOCALAPPDATA 'ObsidianVaultSync'
$ConfigFile   = Join-Path $InstallDir 'config.json'
$TaskName     = 'ObsidianVaultSync'
$DefaultVault = Join-Path $HOME 'Vault'

$script:Step = 0

function Write-Step {
    param([string]$Text)
    $script:Step++
    Write-Host ''
    Write-Host "[$script:Step/9] $Text" -ForegroundColor Blue
}
function Write-Ok    { param($t) Write-Host "   [ok] $t" -ForegroundColor Green }
function Write-Warn  { param($t) Write-Host "   [!]  $t" -ForegroundColor Yellow }
function Write-Info  { param($t) Write-Host "        $t" -ForegroundColor DarkGray }
function Write-Die   {
    param($t)
    Write-Host ''
    Write-Host "   [error] $t" -ForegroundColor Red
    Write-Host ''
    exit 1
}

function Write-Human {
    param([string]$Text)
    Write-Host ''
    Write-Host '   +-- YOUR INPUT NEEDED --------------------------------+' -ForegroundColor Yellow
    foreach ($line in $Text -split "`n") {
        Write-Host ('   | ' + $line) -ForegroundColor Yellow
    }
    Write-Host '   +-----------------------------------------------------+' -ForegroundColor Yellow
    Write-Host ''
}

function Read-Answer {
    param([string]$Prompt, [string]$Default)
    if ($Default) {
        $r = Read-Host "   ? $Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
        return $r.Trim()
    }
    return (Read-Host "   ? $Prompt").Trim()
}

function Read-Confirm {
    param([string]$Prompt)
    $r = Read-Host "   ? $Prompt [y/N]"
    return ($r -match '^[yY]$')
}

Clear-Host
Write-Host @'

   ===================================================
          Obsidian Vault Sync  ·  Windows setup
   ===================================================
'@ -ForegroundColor Cyan
Write-Host '   Automatic two-way backup of your vault over git.' -ForegroundColor DarkGray
Write-Host "   You'll only be asked where a human is genuinely needed." -ForegroundColor DarkGray

# === 1. Dependencies ========================================================
Write-Step 'Dependencies'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Warn 'git is not installed'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        if (Read-Confirm 'Install it with winget?') {
            winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
            $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
                        [Environment]::GetEnvironmentVariable('Path','User')
        }
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Die "Install git from https://git-scm.com/download/win and re-run this script.`n     If you just installed it, close and reopen PowerShell."
    }
}
Write-Ok "git $((git --version) -replace 'git version ','')"

if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Write-Die "OpenSSH not available. Install it from Settings -> Apps -> Optional features -> OpenSSH Client."
}
Write-Ok 'OpenSSH available'

if (-not (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue)) {
    Write-Info 'BurntToast not installed: falling back to system tray notifications'
    if (Read-Confirm 'Install BurntToast for better notifications?') {
        try {
            Install-Module BurntToast -Scope CurrentUser -Force -AllowClobber
            Write-Ok 'BurntToast installed'
        } catch { Write-Warn 'installation failed, using the fallback' }
    }
} else { Write-Ok 'BurntToast available' }

$obsidian = Get-ChildItem "$env:LOCALAPPDATA\Obsidian\Obsidian.exe" -ErrorAction SilentlyContinue
if (-not $obsidian) {
    Write-Warn "Obsidian doesn't appear to be installed"
    Write-Info 'download it from https://obsidian.md/download'
    Write-Info 'not a blocker: syncing works regardless'
}

# === 2. Repository ==========================================================
Write-Step 'Vault repository'

if (Test-Path (Join-Path $DefaultVault '.git')) {
    Push-Location $DefaultVault
    $Repo = (git remote get-url origin 2>$null)
    Pop-Location
    $Vault = $DefaultVault
    Write-Ok "vault already present: $Vault"
    Write-Info "origin: $Repo"
} else {
    Write-Human @'
I need the SSH URL of your private GitHub repository.
Find it on GitHub -> green Code button -> SSH tab.
It looks like:  git@github.com:user/repo.git
'@
    $Repo = Read-Answer 'Repository SSH URL'
    if (-not $Repo) { Write-Die 'no URL given' }
    if ($Repo -like 'https://*') {
        Write-Warn "that's an HTTPS URL — converting it to SSH"
        $Repo = $Repo -replace '^https://github\.com/', 'git@github.com:'
        if ($Repo -notlike '*.git') { $Repo += '.git' }
        Write-Info "-> $Repo"
    }
    $Vault = Read-Answer 'Local vault folder' $DefaultVault
}

# === 3. Git identity ========================================================
Write-Step 'Git identity'

$GitName = (git config --global user.name)  2>$null
$GitMail = (git config --global user.email) 2>$null
if (-not $GitName) { $GitName = Read-Answer 'Name for commits' $env:USERNAME }
if (-not $GitMail) { $GitMail = Read-Answer 'Email for commits' }
Write-Ok "$GitName <$GitMail>"

# === 4. SSH key =============================================================
Write-Step 'SSH key'

$SshDir = Join-Path $HOME '.ssh'
$Key    = Join-Path $SshDir 'id_ed25519'
if (-not (Test-Path $SshDir)) { New-Item -ItemType Directory -Path $SshDir -Force | Out-Null }

if (Test-Path $Key) {
    Write-Ok "key already present: $Key"
    $null = & ssh-keygen -y -P '""' -f $Key 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn 'the key appears to have a passphrase'
        Write-Info 'automated pushes will fail because nothing can type it'
        if (Read-Confirm 'Generate a new key without a passphrase?') {
            $ts = [int][double]::Parse((Get-Date -UFormat %s))
            Move-Item $Key "$Key.backup.$ts"
            if (Test-Path "$Key.pub") { Move-Item "$Key.pub" "$Key.pub.backup.$ts" }
            & ssh-keygen -t ed25519 -C "$env:COMPUTERNAME-obsidian" -N '""' -f $Key -q
            Write-Ok 'new key generated'
        }
    } else { Write-Ok 'no passphrase (correct for automated pushes)' }
} else {
    & ssh-keygen -t ed25519 -C "$env:COMPUTERNAME-obsidian" -N '""' -f $Key -q
    if (-not (Test-Path $Key)) { Write-Die 'key generation failed' }
    Write-Ok 'key created without a passphrase'
}

$KnownHosts = Join-Path $SshDir 'known_hosts'
if (-not (Test-Path $KnownHosts)) { New-Item -ItemType File -Path $KnownHosts -Force | Out-Null }
if (-not (Select-String -Path $KnownHosts -Pattern '^github\.com ' -Quiet -ErrorAction SilentlyContinue)) {
    & ssh-keyscan -t ed25519 github.com 2>$null | Add-Content $KnownHosts
}
Write-Ok 'GitHub host key registered'

# === 5. Authentication ======================================================
Write-Step 'GitHub authentication'

function Test-GitHubAuth {
    $out = & ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com 2>&1
    return (($out | Out-String) -match 'successfully authenticated')
}

$attempt = 0
while (-not (Test-GitHubAuth)) {
    $attempt++
    if ($attempt -gt 5) { Write-Die 'authentication failed after 5 attempts' }

    Write-Human @"
Add this public key to your GitHub account.

1. The key is already on your clipboard
2. Open  https://github.com/settings/ssh/new
3. Title: something like '$env:COMPUTERNAME'
4. Paste into the Key field and save
"@
    $pub = Get-Content "$Key.pub" -Raw
    try { Set-Clipboard -Value $pub.Trim() } catch { }
    Write-Host $pub.Trim() -ForegroundColor Green
    Write-Host ''
    Read-Host "   ? Press ENTER once you've added it"
}
Write-Ok 'authentication successful'

# === 6. Clone ===============================================================
Write-Step 'Local vault'

if (Test-Path (Join-Path $Vault '.git')) {
    Write-Ok "already present at $Vault"
    Push-Location $Vault; git fetch -q origin 2>$null; Pop-Location
} elseif ((Test-Path $Vault) -and (Get-ChildItem $Vault -Force | Measure-Object).Count -gt 0) {
    Write-Die "$Vault exists, isn't empty, and isn't a git repo. Move it or pick another path."
} else {
    git clone -q $Repo $Vault
    if ($LASTEXITCODE -ne 0) { Write-Die "clone failed — is the URL correct?" }
    Write-Ok "cloned into $Vault"
}

Push-Location $Vault
git config user.name  $GitName
git config user.email $GitMail
# Without this a manual 'git pull' on diverged histories fails
git config pull.rebase false

$nested = Get-ChildItem $Vault -Recurse -Depth 2 -Directory -Filter '.obsidian' -Force -ErrorAction SilentlyContinue |
          Where-Object { $_.FullName -ne (Join-Path $Vault '.obsidian') }
if ($nested) {
    Write-Warn 'found a nested .obsidian config:'
    $nested | Select-Object -First 3 | ForEach-Object { Write-Info $_.FullName }
    Write-Info 'this usually means Obsidian was opened on a subfolder'
    Write-Info "open the vault at $Vault, not at a folder inside it"
}

# === 7. Repository configuration ============================================
Write-Step 'Repository configuration'

$changed = $false
$gitignorePath = Join-Path $Vault '.gitignore'
$entries = @(
    '.obsidian/workspace*.json'
    '.obsidian/cache'
    '.obsidian/plugins/obsidian-git/'
    '.trash/'
    '.DS_Store'
    'Thumbs.db'
)
$existing = if (Test-Path $gitignorePath) { Get-Content $gitignorePath } else { @() }
foreach ($e in $entries) {
    if ($existing -notcontains $e) { Add-Content $gitignorePath $e; $changed = $true }
}

$gaPath = Join-Path $Vault '.gitattributes'
$gaHas  = (Test-Path $gaPath) -and (Select-String -Path $gaPath -Pattern 'text=auto' -Quiet)
if (-not $gaHas) {
    @(
        '# Consistent line endings across Windows and Linux'
        '* text=auto eol=lf'
        '*.png binary'
        '*.jpg binary'
        '*.pdf binary'
    ) | Add-Content $gaPath
    $changed = $true
}

# Required on Windows, otherwise git rewrites everything to CRLF
# and every single file shows up as modified
git config core.autocrlf false
Write-Ok 'core.autocrlf disabled (avoids line-ending churn with Linux)'

git rm -r --cached --quiet '.obsidian/workspace.json' 2>$null
if ($changed) {
    git add -A; git commit -q -m 'chore: sync configuration'
    Write-Ok '.gitignore and .gitattributes updated'
} else { Write-Ok 'already configured' }
Pop-Location

# === 8. Automation ==========================================================
Write-Step 'Automatic syncing'

$interval = Read-Answer 'Sync every how many minutes' '15'
if ($interval -notmatch '^\d+$') { $interval = '15' }

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item (Join-Path $ScriptDir 'vault-sync.ps1') $InstallDir -Force
Write-Ok "$InstallDir\vault-sync.ps1"

@{ Vault = $Vault; Repo = $Repo; Interval = [int]$interval } |
    ConvertTo-Json | Set-Content $ConfigFile -Encoding UTF8

# VBS wrapper: runs PowerShell without flashing a black console window
$vbs = Join-Path $InstallDir 'run-hidden.vbs'
@"
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""$InstallDir\vault-sync.ps1""", 0, False
"@ | Set-Content $vbs -Encoding ASCII
Write-Ok 'silent wrapper created'

$action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
$trigger1 = New-ScheduledTaskTrigger -AtLogOn
$trigger2 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
                -RepetitionInterval (New-TimeSpan -Minutes ([int]$interval))
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -StartWhenAvailable `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -Hidden

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger $trigger1,$trigger2 -Settings $settings -Force | Out-Null
    Write-Ok "scheduled task active (every $interval minutes)"
} catch {
    Write-Warn "task creation failed: $_"
    Write-Info 'try running PowerShell as administrator, or create the task manually'
}

# PowerShell profile: 'vs' command and unpushed-commit warning
$profileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
if (-not (Test-Path $PROFILE))    { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }

$marker = '# >>> obsidian-vault-sync >>>'
if (Select-String -Path $PROFILE -Pattern ([regex]::Escape($marker)) -Quiet -ErrorAction SilentlyContinue) {
    Write-Ok 'PowerShell profile: already configured'
} else {
    @"

$marker
function vs { & "$InstallDir\vault-sync.ps1" -Vault "$Vault" -Verbose }
if (Test-Path "$Vault\.git") {
    `$_vu = @(git -C "$Vault" log --oneline '@{u}..HEAD' 2>`$null).Count
    if (`$_vu -gt 0) {
        Write-Host "[!] Vault: `$_vu commit(s) not on GitHub yet - run: vs" -ForegroundColor Yellow
    }
}
# <<< obsidian-vault-sync <<<
"@ | Add-Content $PROFILE -Encoding UTF8
    Write-Ok "PowerShell profile: 'vs' command and warning added"
}

# === 9. Verification ========================================================
Write-Step 'Verification'

Push-Location $Vault
"selftest $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $env:COMPUTERNAME" |
    Set-Content '.vault-selftest' -Encoding UTF8
git add '.vault-selftest'; git commit -q -m 'test: sync verification'
git push -q origin HEAD 2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    Remove-Item '.vault-selftest' -Force
    git add -A; git commit -q -m 'test: cleanup'; git push -q origin HEAD | Out-Null
    Write-Ok 'push verified: the channel to GitHub works'
} else {
    git reset -q --hard HEAD~1
    Remove-Item '.vault-selftest' -Force -ErrorAction SilentlyContinue
    Pop-Location
    Write-Die "PUSH FAILED. No note is safe until this works."
}
Pop-Location

& "$InstallDir\vault-sync.ps1" -Vault $Vault -Verbose
Write-Ok 'sync script working'

Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

# === Summary ================================================================
Write-Host ''
Write-Host '   ===================================================' -ForegroundColor Green
Write-Host '                    Setup complete                    ' -ForegroundColor Green
Write-Host '   ===================================================' -ForegroundColor Green
Write-Host ''
Write-Host "   Vault           $Vault"
Write-Host "   Syncs           every $interval minutes, even with Obsidian closed"
Write-Host '   On failure      Windows notification + warning in PowerShell'
Write-Host ''
Write-Host '   Commands' -ForegroundColor White
Write-Host '     vs                                     sync right now'
Write-Host "     Get-ScheduledTask $TaskName            task status"
Write-Host "     Get-ScheduledTaskInfo $TaskName        last result"
Write-Host ''

Write-Human @"
Three things left to do by hand:

1. Open a new PowerShell window (to load the 'vs' command)

2. In Obsidian: 'Open folder as vault' and pick
   $Vault
   CAREFUL: that folder, not a subfolder inside it.

3. In Obsidian: Settings -> File recovery
   interval 5 minutes, retention at maximum.
   It covers notes overwritten by mistake, which git does not.
"@
