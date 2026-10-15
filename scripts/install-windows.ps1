<#
.SYNOPSIS
  agent-tether target installer for Windows (Task Scheduler). Windows PowerShell 5.1 compatible.

.DESCRIPTION
  Runs `tailcat serve ... ssh` as a scheduled task.
  From an elevated prompt: trigger "at startup", logon type S4U (no stored password,
  runs before anyone signs in, in session 0). RunLevel Limited, or Highest with -Privileged.
  From a normal prompt: trigger "at logon" of the current user, logon type Interactive
  (Windows refuses S4U/at-startup registration without elevation).

  install-windows.ps1 install -ClientNodeKey nodekey:... -AuthorizedKey "ssh-ed25519 AAAA..." [options]
  install-windows.ps1 status
  install-windows.ps1 uninstall [-Detach]

.PARAMETER Privileged
  With S4U, run the listener with RunLevel Highest: for an administrator account the agent's
  shell then has a full (elevated) token without UAC prompts. Anyone holding the agent's keys
  gets administrator rights.

.PARAMETER NoSleepOnAC
  Set the sleep and hibernate timeouts on AC power to "never" (restored by uninstall).

.PARAMETER AtLogon
  Use the at-logon / Interactive task even when elevated.

.PARAMETER Detach
  uninstall: run from a one-shot scheduled task 15 seconds later, so it outlives the SSH
  session that is carried by the task being removed.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true)]
    [ValidateSet('install', 'status', 'uninstall')]
    [string]$Action,
    [string]$ServiceName = 'agent-tether',
    [string]$Dir = (Join-Path $env:USERPROFILE '.config\agent-tether'),
    [string]$Key = '',
    [string[]]$ClientNodeKey = @(),
    [string[]]$AuthorizedKey = @(),
    [string]$AuthorizedKeysFile = '',
    [string]$Tailcat = '',
    [switch]$Privileged,
    [switch]$NoSleepOnAC,
    [switch]$AtLogon,
    [switch]$Detach
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($ServiceName -notmatch '^[A-Za-z0-9_.-]+$') { throw 'ServiceName may only use letters, digits, . _ -' }
if (-not $Key) { $Key = Join-Path $Dir 'server.private.json' }
$KeyIsPath = $Key -match '[\\/]'
$LogFile = Join-Path $env:USERPROFILE "$ServiceName-uninstall.log"
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$IsAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-TetherLog([string]$Message) {
    Write-Output "agent-tether: $Message"
}

# Native commands write progress to stderr; Windows PowerShell 5.1 turns that into
# errors when $ErrorActionPreference is Stop, so relax it around native calls.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>$null
        return @{ Output = $out; Code = $LASTEXITCODE }
    } finally {
        $ErrorActionPreference = $saved
    }
}

function Find-Tailcat {
    if ($Tailcat) {
        if (-not (Test-Path -LiteralPath $Tailcat)) { throw "not found: $Tailcat" }
        return (Resolve-Path -LiteralPath $Tailcat).Path
    }
    # Prefer Scoop's stable "current" path over its shim.
    $scoopExe = Join-Path $env:USERPROFILE 'scoop\apps\tailcat\current\tailcat.exe'
    if (Test-Path -LiteralPath $scoopExe) { return $scoopExe }
    $cmd = Get-Command tailcat.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'tailcat.exe not found; install it first (scoop install tailcat, or the release zip from https://github.com/tailscale/tailcat/releases) or pass -Tailcat <path>'
}

function Write-TextFile([string]$Path, [string[]]$Lines) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
}

# Current AC timeouts (seconds) of a sleep setting; the last two hex values that
# powercfg prints are the AC and DC indexes, whatever the display language.
function Get-AcTimeout([string]$Setting) {
    $text = (powercfg /query SCHEME_CURRENT SUB_SLEEP $Setting) -join "`n"
    $hex = [regex]::Matches($text, '0x[0-9a-fA-F]{8}')
    if ($hex.Count -lt 2) { return $null }
    return [Convert]::ToInt32($hex[$hex.Count - 2].Value, 16)
}

function Install-Tether {
    $tc = Find-Tailcat
    if ($ClientNodeKey.Count -eq 0) { throw '-ClientNodeKey is required (the agent''s tailcat client key; without it any client could connect)' }
    foreach ($k in $ClientNodeKey) { if ($k -notmatch '^nodekey:[0-9a-f]+$') { throw "client keys look like nodekey:<hex>, got: $k" } }
    $authFile = Join-Path $Dir 'authorized_keys'
    if ($AuthorizedKey.Count -eq 0 -and -not $AuthorizedKeysFile -and -not (Test-Path -LiteralPath $authFile)) {
        throw '-AuthorizedKey or -AuthorizedKeysFile is required'
    }

    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $lines = @()
    $lines += $AuthorizedKey
    if ($AuthorizedKeysFile) { $lines += Get-Content -LiteralPath $AuthorizedKeysFile }
    if ($lines.Count -gt 0) { Write-TextFile $authFile $lines }

    $addrFile = Join-Path $Dir 'address'
    $needKey = $false
    if ($KeyIsPath) {
        $needKey = -not (Test-Path -LiteralPath $Key)
    } else {
        $list = Invoke-Native $tc @('genkey', '--list')
        $needKey = -not (@($list.Output) -contains $Key)
    }
    if ($needKey) {
        $r = Invoke-Native $tc @('genkey', "--key=$Key", '--fixed-region')
        if ($r.Code -ne 0) { throw "tailcat genkey failed (exit $($r.Code))" }
        Write-TextFile $addrFile @(($r.Output | Select-Object -Last 1))
        Write-TetherLog "created server key $Key"
    }

    # Absolute key path: under S4U the profile environment can differ.
    $keyArg = $Key
    if (-not $KeyIsPath) { $keyArg = Join-Path $env:APPDATA "tailcat\keys\$Key.private.json" }
    $allow = $ClientNodeKey -join ','
    $arguments = "serve `"--key=$keyArg`" --allow=$allow `"--ssh-authorized-keys=$authFile`" ssh"
    $action = New-ScheduledTaskAction -Execute $tc -Argument $arguments -WorkingDirectory $Dir

    if ($IsAdmin -and -not $AtLogon) {
        $runLevel = 'Limited'
        if ($Privileged) { $runLevel = 'Highest' }
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType S4U -RunLevel $runLevel
        $mode = "at startup, S4U, RunLevel $runLevel"
    } else {
        if (-not $IsAdmin) {
            Write-TetherLog 'not elevated: using an at-logon task (reachable only after you sign in).'
            Write-TetherLog 'For reachability from boot, rerun this from an elevated PowerShell (Terminal (Admin)).'
        }
        if ($Privileged) { Write-TetherLog 'warning: -Privileged needs an elevated, S4U install; ignored' }
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
        $principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited
        $mode = 'at logon, Interactive, RunLevel Limited'
    }
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $ServiceName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Agent remote access (tailcat SSH)' -Force | Out-Null
    Start-ScheduledTask -TaskName $ServiceName
    Write-TetherLog "registered and started task $ServiceName ($mode)"

    if ($NoSleepOnAC) {
        $marker = Join-Path $Dir 'stay-awake-by-installer'
        if (-not (Test-Path -LiteralPath $marker)) {
            Write-TextFile $marker @("STANDBYIDLE=$(Get-AcTimeout 'STANDBYIDLE')", "HIBERNATEIDLE=$(Get-AcTimeout 'HIBERNATEIDLE')")
        }
        powercfg /change standby-timeout-ac 0 | Out-Null
        powercfg /change hibernate-timeout-ac 0 | Out-Null
        Write-TetherLog 'sleep and hibernate on AC power set to never'
    }

    Start-Sleep -Seconds 3
    Show-TetherStatus
}

function Show-TetherStatus {
    $task = Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue
    $addr = ''
    $addrFile = Join-Path $Dir 'address'
    if (Test-Path -LiteralPath $addrFile) { $addr = (Get-Content -LiteralPath $addrFile | Select-Object -First 1).Trim() }
    Write-Output "SERVICE=$ServiceName"
    Write-Output "USER=$CurrentUser"
    if ($task) {
        Write-Output "STATE=$($task.State)"
        Write-Output "LOGON_TYPE=$($task.Principal.LogonType)"
        Write-Output "RUN_LEVEL=$($task.Principal.RunLevel)"
    } else {
        Write-Output 'STATE=missing'
    }
    Write-Output "DIR=$Dir"
    Write-Output "STAY_AWAKE=$(if (Test-Path -LiteralPath (Join-Path $Dir 'stay-awake-by-installer')) { 'yes' } else { 'no' })"
    Write-Output "ADDRESS=$addr"
}

function Uninstall-Tether {
    if ($Detach) {
        $copy = Join-Path $env:TEMP "$ServiceName-uninstall.ps1"
        Copy-Item -LiteralPath $PSCommandPath -Destination $copy -Force
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$copy`" uninstall -ServiceName $ServiceName -Dir `"$Dir`" -Key `"$Key`""
        if ($Tailcat) { $arguments += " -Tailcat `"$Tailcat`"" }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddSeconds(15))
        if ($IsAdmin) {
            $principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType S4U -RunLevel Highest
        } else {
            $principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited
        }
        Register-ScheduledTask -TaskName "$ServiceName-uninstall" -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Write-TetherLog "uninstall scheduled in 15 seconds; this connection will drop. Log: $LogFile"
        return
    }

    $procs = @()
    Start-Transcript -LiteralPath $LogFile -Append | Out-Null
    try {
        Write-TetherLog "uninstall started $(Get-Date)"
        $marker = Join-Path $Dir 'stay-awake-by-installer'
        if (Test-Path -LiteralPath $marker) {
            foreach ($line in Get-Content -LiteralPath $marker) {
                $name, $value = $line -split '=', 2
                if ($value -match '^\d+$') {
                    powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP $name $value | Out-Null
                }
            }
            powercfg /setactive SCHEME_CURRENT | Out-Null
            Write-TetherLog 'restored AC sleep and hibernate timeouts'
        }
        if (-not $KeyIsPath) {
            try {
                $null = Invoke-Native (Find-Tailcat) @('genkey', '--delete', "--key=$Key")
                Write-TetherLog "deleted tailcat key $Key"
            } catch { Write-TetherLog "could not delete tailcat key ${Key}: $_" }
        } elseif ((Test-Path -LiteralPath $Key) -and -not $Key.StartsWith($Dir)) {
            Remove-Item -LiteralPath $Key -Force
            Write-TetherLog "deleted $Key"
        }

        # Remember the listener processes before the task goes away.
        $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'tailcat.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Key) })
        if (Get-ScheduledTask -TaskName $ServiceName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $ServiceName -Confirm:$false
            Write-TetherLog "removed task $ServiceName"
        }
        if (Test-Path -LiteralPath $Dir) {
            Remove-Item -LiteralPath $Dir -Recurse -Force
            Write-TetherLog "removed $Dir"
        }
        if (Get-ScheduledTask -TaskName "$ServiceName-uninstall" -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName "$ServiceName-uninstall" -Confirm:$false
        }
        Write-TetherLog 'stopping the listener; an agent connected through it is disconnected now'
        Write-TetherLog "uninstall finished $(Get-Date)"
    } finally {
        Stop-Transcript | Out-Null
    }
    # Last step: a running tailcat.exe ends the session that carries this script.
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($PSCommandPath -like (Join-Path $env:TEMP "$ServiceName-uninstall.ps1")) {
        Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
    }
}

switch ($Action) {
    'install' { Install-Tether }
    'status' { Show-TetherStatus }
    'uninstall' { Uninstall-Tether }
}
