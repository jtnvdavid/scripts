#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Dell New PC Setup Script - Automated Dell Command Update + Windows Update Workflow
.DESCRIPTION
    Multi-phase script for MSP deployment of new Dell computers:
      Phase 0: Set hostname and reboot
      Phase 1: Install prerequisites (.NET Desktop Runtime 8.x) and Dell Command Update, reboot
      Phase 2: Run Dell Command Update scan/install cycle, reboot as needed
      Phase 3: Run Windows Update (PSWindowsUpdate) loop until clean, reboot as needed
      Phase 4: All updates installed - alert user, uninstall DCU, clean up

    Designed to be hosted on GitHub and launched with a one-liner:

        irm https://raw.githubusercontent.com/YOURNAME/YOURREPO/main/Dell-NewPC-Setup.ps1 | iex

    The script survives reboots by registering a scheduled task that runs a small
    launcher at logon. The launcher pulls the LATEST version of this script from
    GitHub each time (so updates you push take effect mid-deployment), and falls
    back to a locally cached copy if the network is unavailable.

.NOTES
    Author:  Jasco Technology
    Version: 2.0
    Run from an elevated PowerShell prompt on a fresh Dell PC.
#>

# ── Configuration ────────────────────────────────────────────────────────────
# ⚠️ UPDATE THIS to your repo's raw URL before publishing:
$ScriptUrl        = "https://raw.githubusercontent.com/YOURNAME/YOURREPO/main/Dell-NewPC-Setup.ps1"

$DeployRoot       = "C:\Deploy"
$LocalScriptPath  = Join-Path $DeployRoot "Dell-NewPC-Setup.ps1"
$LauncherPath     = Join-Path $DeployRoot "Launch-Setup.ps1"
$PhaseFile        = Join-Path $DeployRoot "deploy-phase.txt"
$WUCycleFile      = Join-Path $DeployRoot "wu-cycle.txt"
$LogFile          = Join-Path $DeployRoot "deploy-log.txt"
$TaskName         = "DellNewPCSetup"

# Dell Command Update (DCU) CLI - direct installer URL (fallback when winget fails)
$DCU_DownloadURL  = "https://dl.dell.com/FOLDER12591980M/1/Dell-Command-Update-Application_W4HP2_WIN_5.5.0_A00.EXE"
$DCU_InstallerPath = Join-Path $DeployRoot "DCU_Setup.exe"
$DCU_CLI          = "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe"
$DCU_CLI_Alt      = "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"

# .NET 8 Desktop Runtime (required by newer DCU versions)
$DotNet8_URL      = "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.24/windowsdesktop-runtime-8.0.24-win-x64.exe"
$DotNet8_Installer = Join-Path $DeployRoot "dotnet8-desktop-runtime.exe"

# Maximum update cycles before giving up (per update system)
$MaxDCUCycles     = 5
$MaxWUCycles      = 5

# Ensure modern TLS for all downloads (old Win10 images default to TLS 1.0)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Logging ──────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] $Message"
    Write-Host $entry -ForegroundColor Cyan
    Add-Content -Path $LogFile -Value $entry -ErrorAction SilentlyContinue
}

# ── Self-Caching (GitHub-aware) ──────────────────────────────────────────────
function Save-LocalCopy {
    <#
        Ensure the latest script text is cached at $LocalScriptPath so the
        launcher has a fallback if GitHub is unreachable after a reboot.
        Works whether we were run from a file OR piped in via irm | iex.
    #>
    $sourcePath = $MyInvocation.PSCommandPath
    if (-not $sourcePath) { $sourcePath = $script:MyInvocation.MyCommand.Path }

    if ($sourcePath -and (Test-Path $sourcePath) -and ($sourcePath -ne $LocalScriptPath)) {
        Copy-Item -Path $sourcePath -Destination $LocalScriptPath -Force
        Write-Log "Script cached locally from file: $sourcePath"
        return
    }

    # Running via irm | iex (no source file) - download a copy for offline fallback
    if (-not (Test-Path $LocalScriptPath)) {
        try {
            Invoke-RestMethod -Uri $ScriptUrl -OutFile $LocalScriptPath -UseBasicParsing
            Write-Log "Script cached locally from GitHub."
        }
        catch {
            Write-Log "WARNING: Could not cache script locally ($_). Resume will require network."
        }
    }
}

function Write-Launcher {
    <#
        Write a small launcher that the scheduled task runs at each logon.
        It tries GitHub first (always latest version), then falls back to
        the local cached copy.
    #>
    $launcherContent = @"
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    Write-Host 'Fetching latest setup script from GitHub...' -ForegroundColor Yellow
    `$scriptText = Invoke-RestMethod -Uri '$ScriptUrl' -UseBasicParsing
    Set-Content -Path '$LocalScriptPath' -Value `$scriptText -Force
    Write-Host 'Running latest version from GitHub.' -ForegroundColor Green
}
catch {
    Write-Host "GitHub unreachable (`$_). Using cached local copy." -ForegroundColor Yellow
}
& '$LocalScriptPath'
"@
    Set-Content -Path $LauncherPath -Value $launcherContent -Force
}

# ── Scheduled Task Helpers ───────────────────────────────────────────────────
function Register-RebootTask {
    <# Re-register the launcher to run visibly at next logon #>
    Write-Launcher

    $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-ExecutionPolicy Bypass -NoExit -File `"$LauncherPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    # Run as the interactive logged-on user with elevated privileges
    $principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Administrators" -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    Write-Log "Scheduled task '$TaskName' registered for next logon (pulls latest from GitHub)."
}

function Remove-RebootTask {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log "Scheduled task '$TaskName' removed."
}

# ── Phase Management ─────────────────────────────────────────────────────────
function Get-Phase {
    if (Test-Path $PhaseFile) {
        return [int](Get-Content $PhaseFile -Raw).Trim()
    }
    return 0
}

function Set-Phase {
    param([int]$Phase)
    Set-Content -Path $PhaseFile -Value $Phase -Force
    Write-Log "Phase set to $Phase"
}

function Get-WUCycle {
    if (Test-Path $WUCycleFile) {
        return [int](Get-Content $WUCycleFile -Raw).Trim()
    }
    return 0
}

function Set-WUCycle {
    param([int]$Cycle)
    Set-Content -Path $WUCycleFile -Value $Cycle -Force
}

# ── Reusable Download Helper ─────────────────────────────────────────────────
function Get-FileDownload {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Description
    )
    if (Test-Path $Destination) {
        Write-Log "$Description already downloaded."
        return $true
    }
    Write-Log "Downloading $Description from $Url ..."
    try {
        Start-BitsTransfer -Source $Url -Destination $Destination -ErrorAction Stop
        Write-Log "$Description downloaded successfully."
        return $true
    }
    catch {
        Write-Log "BITS transfer failed, trying WebClient..."
        try {
            (New-Object System.Net.WebClient).DownloadFile($Url, $Destination)
            Write-Log "$Description downloaded successfully (WebClient)."
            return $true
        }
        catch {
            Write-Log "ERROR: Failed to download $Description - $_"
            return $false
        }
    }
}

# ── Resolve DCU CLI Path ────────────────────────────────────────────────────
function Get-DCUPath {
    if (Test-Path $DCU_CLI) { return $DCU_CLI }
    if (Test-Path $DCU_CLI_Alt) { return $DCU_CLI_Alt }
    $found = Get-ChildItem "C:\Program Files*\Dell\CommandUpdate\dcu-cli.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 0 - Set Hostname & Reboot
# ═══════════════════════════════════════════════════════════════════════════════
function Invoke-Phase0 {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  DELL NEW PC SETUP - Jasco Technology" -ForegroundColor Yellow
    Write-Host "  Phase 0: Set Computer Name" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""

    $currentName = $env:COMPUTERNAME
    Write-Host "Current hostname: $currentName" -ForegroundColor Gray

    $newName = Read-Host "Enter new hostname (or press Enter to keep '$currentName')"

    if ([string]::IsNullOrWhiteSpace($newName)) {
        Write-Log "Keeping hostname: $currentName"
    }
    else {
        Write-Log "Renaming computer to: $newName"
        Rename-Computer -NewName $newName -Force
    }

    Set-Phase 1
    Register-RebootTask
    Write-Log "Rebooting for Phase 1..."
    Start-Sleep -Seconds 3
    Restart-Computer -Force
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 1 - Install Prerequisites + Dell Command Update
# ═══════════════════════════════════════════════════════════════════════════════
function Invoke-Phase1 {
    Write-Log "═══ Phase 1: Installing Prerequisites & Dell Command Update ═══"

    # ── Install .NET 8 Desktop Runtime if needed ──
    $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
    $dotnetInstalled = $false
    if ($dotnetCmd) {
        $dotnetInstalled = dotnet --list-runtimes 2>$null | Select-String "Microsoft.WindowsDesktop.App 8\."
    }
    if (-not $dotnetInstalled) {
        Write-Log ".NET 8 Desktop Runtime not found. Installing..."

        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Log "Using winget to install .NET 8 Desktop Runtime..."
            winget install Microsoft.DotNet.DesktopRuntime.8 --source winget --accept-source-agreements --accept-package-agreements --silent
            if ($LASTEXITCODE -eq 0) {
                Write-Log ".NET 8 Desktop Runtime installed via winget."
            }
            else {
                Write-Log "Winget install returned exit code $LASTEXITCODE, attempting direct download..."
                $downloaded = Get-FileDownload -Url $DotNet8_URL -Destination $DotNet8_Installer -Description ".NET 8 Desktop Runtime"
                if ($downloaded) {
                    Start-Process -FilePath $DotNet8_Installer -ArgumentList "/install /quiet /norestart" -Wait
                    Write-Log ".NET 8 Desktop Runtime installed via direct download."
                }
            }
        }
        else {
            $downloaded = Get-FileDownload -Url $DotNet8_URL -Destination $DotNet8_Installer -Description ".NET 8 Desktop Runtime"
            if ($downloaded) {
                Start-Process -FilePath $DotNet8_Installer -ArgumentList "/install /quiet /norestart" -Wait
                Write-Log ".NET 8 Desktop Runtime installed via direct download."
            }
        }
    }
    else {
        Write-Log ".NET 8 Desktop Runtime already installed."
    }

    # ── Install Dell Command Update ──
    $dcuPath = Get-DCUPath
    if (-not $dcuPath) {
        Write-Log "Dell Command Update not found. Installing..."

        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget) {
            Write-Log "Attempting winget install of Dell Command Update..."
            winget install Dell.CommandUpdate.Universal --source winget --accept-source-agreements --accept-package-agreements --silent
            $dcuPath = Get-DCUPath
        }

        if (-not $dcuPath) {
            Write-Log "Winget unavailable or failed. Downloading DCU installer directly..."
            $downloaded = Get-FileDownload -Url $DCU_DownloadURL -Destination $DCU_InstallerPath -Description "Dell Command Update"
            if ($downloaded) {
                Write-Log "Running DCU installer silently..."
                Start-Process -FilePath $DCU_InstallerPath -ArgumentList "/s" -Wait
                Start-Sleep -Seconds 10
                $dcuPath = Get-DCUPath
            }
        }

        if ($dcuPath) {
            Write-Log "Dell Command Update installed at: $dcuPath"
        }
        else {
            Write-Log "ERROR: Dell Command Update installation failed! Exiting."
            Write-Host "ERROR: Could not install Dell Command Update. Check the log at $LogFile" -ForegroundColor Red
            Read-Host "Press Enter to exit"
            return
        }
    }
    else {
        Write-Log "Dell Command Update already installed at: $dcuPath"
    }

    # ── Configure DCU for silent operation ──
    Write-Log "Configuring DCU settings..."
    & $dcuPath /configure -autoSuspendBitLocker=enable 2>$null
    & $dcuPath /configure -reboot=disable 2>$null
    & $dcuPath /configure -scheduleManual 2>$null

    Set-Phase 2
    Register-RebootTask
    Write-Log "Rebooting before update scan..."
    Start-Sleep -Seconds 3
    Restart-Computer -Force
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 2 - Dell Updates: Scan & Install (Loop Until Clean)
# ═══════════════════════════════════════════════════════════════════════════════
function Invoke-Phase2 {
    Write-Log "═══ Phase 2: Scanning & Installing Dell Updates ═══"

    $dcuPath = Get-DCUPath
    if (-not $dcuPath) {
        Write-Log "ERROR: Cannot find dcu-cli.exe!"
        Set-Phase 3
        return
    }

    $cycle = 0

    while ($cycle -lt $MaxDCUCycles) {
        $cycle++
        Write-Log "── Dell Update Cycle $cycle of $MaxDCUCycles ──"

        # Exit codes: 0=no updates needed, 1=reboot required, 2=error,
        #             3=cancelled, 4=updates found, 5=reboot pending
        #             500=no applicable updates, 3003=DCU self-update available
        Write-Log "Running: dcu-cli /applyUpdates -reboot=disable -autoSuspendBitLocker=enable"

        $process = Start-Process -FilePath $dcuPath `
            -ArgumentList "/applyUpdates","-reboot=disable","-autoSuspendBitLocker=enable" `
            -Wait -PassThru -NoNewWindow

        $exitCode = $process.ExitCode
        Write-Log "DCU exit code: $exitCode"

        switch ($exitCode) {
            0 {
                Write-Log "No Dell updates needed. Moving to Windows Update phase."
                Set-Phase 3
                Register-RebootTask
                Write-Log "Rebooting before Windows Update phase..."
                Restart-Computer -Force
                return
            }
            1 {
                Write-Log "Dell updates installed - reboot required."
                Register-RebootTask
                Write-Log "Rebooting..."
                Start-Sleep -Seconds 5
                Restart-Computer -Force
                return
            }
            5 {
                Write-Log "A reboot was pending from a previous operation. Rebooting..."
                Register-RebootTask
                Restart-Computer -Force
                return
            }
            500 {
                Write-Log "No applicable Dell updates. Moving to Windows Update phase."
                Set-Phase 3
                Register-RebootTask
                Write-Log "Rebooting before Windows Update phase..."
                Restart-Computer -Force
                return
            }
            3003 {
                Write-Log "DCU self-update available (code 3003). Updating Dell Command Update itself..."

                # Attempt 1: Let DCU self-update via CLI
                $selfUpdate = Start-Process -FilePath $dcuPath `
                    -ArgumentList "/applyUpdates","-updateType=application","-reboot=disable" `
                    -Wait -PassThru -NoNewWindow
                Write-Log "DCU self-update exit code: $($selfUpdate.ExitCode)"

                # Attempt 2: If self-update didn't clearly succeed, reinstall latest
                if ($selfUpdate.ExitCode -notin 0,1,5) {
                    Write-Log "CLI self-update may have failed. Reinstalling latest DCU..."
                    $winget = Get-Command winget -ErrorAction SilentlyContinue
                    $reinstalled = $false

                    if ($winget) {
                        Write-Log "Using winget to reinstall DCU (latest version)..."
                        winget install Dell.CommandUpdate.Universal --source winget --accept-source-agreements --accept-package-agreements --silent --force
                        if ($LASTEXITCODE -eq 0) {
                            Write-Log "DCU reinstalled via winget."
                            $reinstalled = $true
                        } else {
                            Write-Log "Winget reinstall returned exit code $LASTEXITCODE."
                        }
                    }

                    if (-not $reinstalled) {
                        Write-Log "Falling back to direct download installer..."
                        Remove-Item $DCU_InstallerPath -Force -ErrorAction SilentlyContinue
                        $downloaded = Get-FileDownload -Url $DCU_DownloadURL -Destination $DCU_InstallerPath -Description "Dell Command Update (update)"
                        if ($downloaded) {
                            Start-Process -FilePath $DCU_InstallerPath -ArgumentList "/s" -Wait
                            Start-Sleep -Seconds 10
                            Write-Log "DCU reinstalled via direct download."
                        }
                    }
                }

                Register-RebootTask
                Write-Log "Rebooting to complete DCU self-update..."
                Start-Sleep -Seconds 5
                Restart-Computer -Force
                return
            }
            {$_ -in 501,502,503,1000,1001,1002} {
                Write-Log "DCU error (code $_). Retrying..."
                Start-Sleep -Seconds 15
            }
            default {
                Write-Log "DCU returned unexpected code $exitCode. Retrying..."
                Start-Sleep -Seconds 10
            }
        }
    }

    Write-Log "Max Dell update cycles reached. Moving to Windows Update phase."
    Set-Phase 3
    Register-RebootTask
    Restart-Computer -Force
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 3 - Windows Updates: Install All (Loop Until Clean)
# ═══════════════════════════════════════════════════════════════════════════════
function Invoke-Phase3 {
    Write-Log "═══ Phase 3: Windows Updates ═══"

    # ── Ensure PSWindowsUpdate module is available ──
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Log "Installing PSWindowsUpdate module..."
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module PSWindowsUpdate -Force -ErrorAction Stop
            Write-Log "PSWindowsUpdate module installed."
        }
        catch {
            Write-Log "ERROR: Could not install PSWindowsUpdate module - $_"
            Write-Log "Skipping Windows Update phase. Moving to cleanup."
            Set-Phase 4
            Register-RebootTask
            Restart-Computer -Force
            return
        }
    }
    Import-Module PSWindowsUpdate

    # ── Register Microsoft Update service (drivers, Office, etc.) ──
    try {
        if (-not (Get-WUServiceManager | Where-Object { $_.ServiceID -eq "7971f918-a847-4430-9279-4a52d1efe18d" })) {
            Add-WUServiceManager -MicrosoftUpdate -Confirm:$false | Out-Null
            Write-Log "Microsoft Update service registered."
        }
    }
    catch {
        Write-Log "Note: Could not register Microsoft Update service - $_"
    }

    # ── Track pass count across reboots ──
    $wuCycle = Get-WUCycle
    $wuCycle++
    Set-WUCycle $wuCycle
    Write-Log "── Windows Update Pass $wuCycle of $MaxWUCycles ──"

    if ($wuCycle -gt $MaxWUCycles) {
        Write-Log "Max Windows Update passes reached. Moving to cleanup."
        Set-Phase 4
        Register-RebootTask
        Restart-Computer -Force
        return
    }

    # ── Check what's available ──
    Write-Log "Scanning for Windows updates (this can take a few minutes)..."
    try {
        $available = Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop
    }
    catch {
        Write-Log "WARNING: Scan failed ($_). Retrying with default Windows Update source..."
        $available = Get-WindowsUpdate -ErrorAction SilentlyContinue
    }

    if (-not $available -or $available.Count -eq 0) {
        Write-Log "No Windows updates available. System fully patched!"
        Set-Phase 4
        Register-RebootTask
        Write-Log "Final reboot before cleanup..."
        Restart-Computer -Force
        return
    }

    Write-Log "Found $($available.Count) update(s):"
    $available | ForEach-Object { Write-Log "  - $($_.Title)" }

    # ── Install everything, suppress reboot so we control it ──
    Write-Log "Installing Windows updates..."
    try {
        Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "WARNING: Install pass encountered an error - $_"
    }

    # ── Reboot and re-run this phase (new updates often appear after reboot) ──
    Write-Log "Windows Update pass $wuCycle complete. Rebooting to check for more..."
    Register-RebootTask
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PHASE 4 - Alert User, Uninstall DCU, Clean Up
# ═══════════════════════════════════════════════════════════════════════════════
function Invoke-Phase4 {
    Write-Log "═══ Phase 4: Cleanup & Notification ═══"

    # ── Remove scheduled task first ──
    Remove-RebootTask

    # ── Uninstall Dell Command Update ──
    Write-Log "Uninstalling Dell Command Update..."

    # Method 1: DCU's own uninstaller
    $dcuPath = Get-DCUPath
    if ($dcuPath) {
        $dcuDir = Split-Path $dcuPath -Parent
        $uninstaller = Join-Path $dcuDir "uninstall.exe"
        if (Test-Path $uninstaller) {
            Start-Process -FilePath $uninstaller -ArgumentList "/s" -Wait
            Write-Log "DCU uninstalled via its own uninstaller."
        }
    }

    # Method 2: winget
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        winget uninstall "Dell Command | Update" --silent 2>$null
        winget uninstall Dell.CommandUpdate.Universal --silent 2>$null
    }

    # Method 3: WMI / registry-based uninstall as fallback
    $dcuProduct = Get-CimInstance Win32_Product -Filter "Name LIKE '%Dell Command%Update%'" -ErrorAction SilentlyContinue
    if ($dcuProduct) {
        $dcuProduct | ForEach-Object {
            Write-Log "Uninstalling via WMI: $($_.Name)"
            $_.Uninstall() | Out-Null
        }
    }

    # ── Clean up downloaded installers and state files (keep log) ──
    Remove-Item $DCU_InstallerPath -Force -ErrorAction SilentlyContinue
    Remove-Item $DotNet8_Installer -Force -ErrorAction SilentlyContinue
    Remove-Item $PhaseFile -Force -ErrorAction SilentlyContinue
    Remove-Item $WUCycleFile -Force -ErrorAction SilentlyContinue
    Remove-Item $LauncherPath -Force -ErrorAction SilentlyContinue

    Write-Log "Cleanup complete."

    # ── Show on-screen alert ──
    $message = @"
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║   ✅  ALL DELL & WINDOWS UPDATES HAVE BEEN INSTALLED     ║
║                                                          ║
║   Dell Command Update has been uninstalled.              ║
║   This computer is ready for deployment.                 ║
║                                                          ║
║   Hostname: $($env:COMPUTERNAME)                         ║
║   Log file: $LogFile                                     ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
"@

    Write-Host ""
    Write-Host $message -ForegroundColor Green
    Write-Host ""

    # Also show a Windows popup so it's impossible to miss
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "All Dell and Windows updates have been installed.`n`nDell Command Update has been uninstalled.`nHostname: $($env:COMPUTERNAME)`n`nThis PC is ready for deployment.`n`nLog: $LogFile",
        "Jasco Technology - Dell Setup Complete",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null

    Write-Log "═══ DEPLOYMENT COMPLETE ═══"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN - Phase Router
# ═══════════════════════════════════════════════════════════════════════════════

# Ensure deploy directory exists
if (-not (Test-Path $DeployRoot)) {
    New-Item -ItemType Directory -Path $DeployRoot -Force | Out-Null
}

# Cache the script locally (handles both file-based and irm|iex execution)
Save-LocalCopy

$phase = Get-Phase
Write-Log "Starting Phase $phase on $($env:COMPUTERNAME)"

switch ($phase) {
    0 { Invoke-Phase0 }
    1 { Invoke-Phase1 }
    2 { Invoke-Phase2 }
    3 { Invoke-Phase3 }
    4 { Invoke-Phase4 }
    default {
        Write-Log "Unknown phase: $phase. Resetting to Phase 0."
        Set-Phase 0
        Invoke-Phase0
    }
}
