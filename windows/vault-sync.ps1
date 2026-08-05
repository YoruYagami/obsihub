#Requires -Version 5.1
<#
.SYNOPSIS
    Two-way sync for an Obsidian vault backed by git.
.DESCRIPTION
    local commit -> fetch -> merge -> push
    On conflict it aborts the merge, leaves the repository clean, and warns
    the user. Nothing is ever lost.
.PARAMETER Vault
    Vault path. Defaults to the saved configuration, then ~\Vault
.EXAMPLE
    .\vault-sync.ps1 -Verbose
#>
[CmdletBinding()]
param(
    [string]$Vault
)

$ErrorActionPreference = 'Continue'
$ConfigFile = Join-Path $env:LOCALAPPDATA 'ObsidianVaultSync\config.json'
$LockFile   = Join-Path $env:TEMP 'vault-sync.lock'

# ── Vault path ───────────────────────────────────────────────────────────────
if (-not $Vault) {
    if (Test-Path $ConfigFile) {
        $Vault = (Get-Content $ConfigFile -Raw | ConvertFrom-Json).Vault
    }
    if (-not $Vault) { $Vault = Join-Path $HOME 'Vault' }
}

# ── Notifications ────────────────────────────────────────────────────────────
function Send-VaultNotification {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [switch]$Critical
    )

    # 1) BurntToast if available: native toasts that stay in the Action Center
    try {
        if (Get-Module -ListAvailable -Name BurntToast -ErrorAction SilentlyContinue) {
            Import-Module BurntToast -ErrorAction Stop
            New-BurntToastNotification -Text $Title, $Message -ErrorAction Stop
            return
        }
    } catch { }

    # 2) Fallback: tray balloon tip
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Icon = [System.Drawing.SystemIcons]::Information
        $tray.Visible = $true
        $level = if ($Critical) { 'Error' } else { 'Info' }
        $tray.ShowBalloonTip(10000, $Title, $Message, $level)
        Start-Sleep -Seconds 8
        $tray.Dispose()
        return
    } catch { }

    # 3) Last resort: console
    if ($Critical) { Write-Error "$Title - $Message" } else { Write-Host "$Title - $Message" }
}

function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Args)
    $out = & git @Args 2>&1
    return [PSCustomObject]@{
        Ok     = ($LASTEXITCODE -eq 0)
        Output = ($out | Out-String).Trim()
    }
}

# ── Lock: one sync at a time ─────────────────────────────────────────────────
$lock = $null
try {
    $lock = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Write-Verbose "Sync already running, exiting."
    exit 0
}

try {
    # ── Preflight checks ─────────────────────────────────────────────────────
    if (-not (Test-Path $Vault)) {
        Send-VaultNotification -Critical -Title 'Vault not found' `
            -Message "The folder $Vault does not exist."
        exit 1
    }
    Set-Location $Vault

    if (-not (Test-Path (Join-Path $Vault '.git'))) {
        Send-VaultNotification -Critical -Title 'Vault is not a git repository' `
            -Message "$Vault contains no git repo."
        exit 1
    }

    $branch = (Invoke-Git symbolic-ref --short HEAD)
    if (-not $branch.Ok) {
        Send-VaultNotification -Critical -Title 'Vault: detached HEAD' `
            -Message "Not on a branch. Fix it: cd $Vault; git checkout main"
        exit 1
    }
    $branch = $branch.Output

    if (Test-Path (Join-Path $Vault '.git\MERGE_HEAD')) {
        Send-VaultNotification -Critical -Title 'Vault: unfinished merge' `
            -Message "A merge was left incomplete. Fix it: cd $Vault; git status"
        exit 1
    }

    # ── 1. Commit local changes ──────────────────────────────────────────────
    Invoke-Git add -A | Out-Null
    $staged = Invoke-Git diff --cached --quiet
    if (-not $staged.Ok) {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $msg   = "vault: $stamp [$env:COMPUTERNAME]"
        Invoke-Git commit -q -m $msg | Out-Null
        Write-Verbose "Local changes committed."
    }

    # ── 2. Fetch remote state ────────────────────────────────────────────────
    $fetch = Invoke-Git fetch -q origin $branch
    if (-not $fetch.Ok) {
        Send-VaultNotification -Critical -Title 'Vault: fetch failed' `
            -Message $fetch.Output
        exit 1
    }

    $local  = (Invoke-Git rev-parse HEAD).Output
    $remote = (Invoke-Git rev-parse "origin/$branch").Output
    $base   = (Invoke-Git merge-base HEAD "origin/$branch").Output

    # ── 3. Reconcile ─────────────────────────────────────────────────────────
    if ($local -eq $remote) {
        Write-Verbose "Already in sync with origin/$branch."
        exit 0
    }
    elseif ($local -eq $base) {
        # Remote is ahead only: fast-forward
        $ff = Invoke-Git merge -q --ff-only "origin/$branch"
        if (-not $ff.Ok) {
            Send-VaultNotification -Critical -Title 'Vault: update failed' `
                -Message $ff.Output
            exit 1
        }
        $n = (Invoke-Git rev-list --count "$local..$remote").Output
        Send-VaultNotification -Title 'Vault updated' `
            -Message "$n change(s) pulled from another machine."
        exit 0
    }
    elseif ($remote -eq $base) {
        Write-Verbose "Local changes only, moving on to push."
    }
    else {
        # Histories diverged
        $merge = Invoke-Git merge -q --no-edit "origin/$branch"
        if (-not $merge.Ok) {
            $files = (Invoke-Git diff --name-only --diff-filter=U).Output
            Invoke-Git merge --abort | Out-Null
            Send-VaultNotification -Critical -Title 'Vault: CONFLICT' -Message @"
The same notes were edited on two machines.
The repository is clean and nothing was lost.

Fix it with:  cd $Vault ; git pull --no-rebase
then edit the files and run: git add -A ; git commit

Files: $files
"@
            exit 1
        }
        Send-VaultNotification -Title 'Vault merged' `
            -Message 'Changes from two machines merged automatically.'
    }

    # ── 4. Push ──────────────────────────────────────────────────────────────
    $push = Invoke-Git push -q origin $branch
    if (-not $push.Ok) {
        Send-VaultNotification -Critical -Title 'Vault NOT saved to GitHub' -Message @"
The push failed. Your changes are safe locally
but they are not on GitHub yet.

$($push.Output)
"@
        exit 1
    }

    Write-Verbose "Push complete."
    exit 0
}
finally {
    if ($lock) { $lock.Close(); $lock.Dispose() }
}
