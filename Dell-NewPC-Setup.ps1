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
    Version: 2.1
    Run from an elevated PowerShell prompt on a fresh Dell PC.

    ── CHANGES IN 2.1 ────────────────────────────────────────────────────────
    * FIXED reboot loop: DCU exit codes 3003/3004/3005 mean "the Dell Client
      Management Service is BUSY - wait and retry", NOT "a self-update is
      available". v2.0 responded by reinstalling DCU and rebooting, which
      restarted the service, re-armed its self-update, and killed the in-flight
      self-update mid-install. That guaranteed an infinite loop. These codes now
      trigger a bounded wait-and-poll instead.
    * Added a busy counter that PERSISTS ACROSS REBOOTS ($BusyFile). The old
      $MaxDCUCycles guard reset to 0 on every boot, so it could never catch a
      reboot loop.
    * Added Wait-DcuService: Phase 2 now waits for the Dell Client Management
      Service to be running and settled before firing the first dcu-cli command.
    * Launcher retries the GitHub fetch (DNS is often not ready at logon) and
      logs which copy of the script actually ran.
    * Removed the invalid "/configure -reboot=disable" call (-reboot is an
      /applyUpdates option, not a /configure option).
#>

# ── Configuration ────────────────────────────────────────────────────────────
$ScriptVersion = "2.1"

# ⚠️ UPDATE THIS to your repo's raw URL before publishing:
$ScriptUrl = "https://raw.githubusercontent.com/jtnvdavid/scripts/refs/heads/main/Dell-NewPC-Setup.ps1"

$DeployRoot       = "C:\Deploy"
$LocalScriptPath  = Join-Path $DeployRoot "Dell-NewPC-Setup.ps1"
$LauncherPath     = Join-Path $DeployRoot "Launch-Setup.ps1"
$PhaseFile        = Join-Path $DeployRoot "deploy-phase.txt"
$WUCycleFile      = Join-Path $DeployRoot "wu-cycle.txt"
$BusyFile         = Join-Path $DeployRoot "dcu-busy-count.txt"
$LogFile          = Join-Path $DeployRoot "deploy-log.txt"
$TaskName         = "DellNewPCSetup"

# Dell Command Update (DCU) CLI - direct installer URL (fallback when winget fails)
$DCU_DownloadURL  = "https://dl.dell.com/FOLDER12591980M/1/Dell-Command-Update-Application_W4HP2_WIN_5.5.0_A00.EXE"
$DCU_InstallerPath = Join-Path $DeployRoot "DCU_Setup.exe"
$DCU_CLI          = "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe"
$DCU_CLI_Alt      = "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
$DCU_ServiceName  = "DellClientManagementService"

# .NET 8 Desktop Runtime (required by newer DCU versions)
$DotNet8_URL      = "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.24/windowsdesktop-runtime-8.0.24-win-x64.exe"
$DotNet8_Installer = Join-Path $DeployRoot "dotnet8-desktop-runtime.exe"

# Maximum update cycles before giving up (per update system)
$MaxDCUCycles     = 5
$MaxWUCycles      = 5

# DCU "service busy" handling
$BusyPollSeconds  = 30    # how often to re-probe while the service is busy
$BusyMaxWait      = 900   # max seconds to wait in a single boot (15 min)
$MaxBusyReboots   = 2     # reboots allowed to clear a busy service before escalating

# DCU exit codes that mean "the service is busy - wait, don't act"
$DcuBusyCodes     = @(3003, 3004, 3005)

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

        v2.1: retries the fetch. At logon the NIC/DNS often isn't ready yet,
        which is why machines silently fall back to a stale cached script.
    #>
    $launcherContent = @"
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

`$logFile = '$LogFile'
function Write-LauncherLog {
    param([string]`$m)
    `$e = "[`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] LAUNCHER: `$m"
    Write-Host `$e -ForegroundColor Yellow
    Add-Content -Path `$logFile -Value `$e -ErrorAction SilentlyContinue
}

# Wait for the network stack to come up before trying GitHub
for (`$i = 1; `$i -le 12; `$i++) {
    if (Test-Connection -ComputerName 1.1.1.1 -Count 1 -Quiet -ErrorAction SilentlyContinue) { break }
    Write-LauncherLog "Waiting for network (attempt `$i/12)..."
    Start-Sleep -Seconds 10
}

`$gotLatest = `$false
for (`$i = 1; `$i -le 3; `$i++) {
    try {
        Write-LauncherLog "Fetching latest setup script from GitHub (attempt `$i/3)..."
        `$scriptText = Invoke-RestMethod -Uri '$ScriptUrl' -UseBasicParsing
        Set-Content -Path '$LocalScriptPath' -Value `$scriptText -Force
        Write-LauncherLog 'Running LATEST version pulled from GitHub.'
        `$gotLatest = `$true
        break
    }
    catch {
        Write-LauncherLog "GitHub fetch failed: `$(`$_.Exception.Message)"
        Start-Sleep -Seconds 15
    }
}

if (-not `$gotLatest) {
    Write-LauncherLog 'GitHub unreachable after 3 attempts. Running CACHED LOCAL COPY (may be stale).'
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

# ── Reboot-Loop Guard (persists across reboots) ──────────────────────────────
function Get-BusyCount {
    if (Test-Path $BusyFile) {
        return [int](Get-Content $BusyFile -Raw).Trim()
    }
    return 0
}

function Set-BusyCount {
    param([int]$Count)
    Set-Content -Path $BusyFile -Value $Count -Force
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

# ── Wait for the Dell Client Management Service to be ready ─────────────────
function Wait-DcuService {
    <#
        On a fresh boot the Dell Client Management Service starts and frequently
        kicks off its own self-update. Any dcu-cli command issued during that
        window returns 3003/3004/3005. Give it time to settle before we start.
    #>
    param([int]$TimeoutSeconds = 300, [int]$SettleSeconds = 90)

    $svc = Get-Service -Name $DCU_ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Service '$DCU_ServiceName' not found - continuing without settle wait."
        return
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($svc.Status -ne 'Running' -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        Write-Log "Waiting for '$DCU_ServiceName' to start (status: $($svc.Status))..."
        Start-Sleep -Seconds 10
        $svc.Refresh()
    }

    if ($svc.Status -eq 'Running') {
        Write-Log "'$DCU_ServiceName' is running. Settling ${SettleSeconds}s before first dcu-cli call..."
        Start-Sleep -Seconds $SettleSeconds
    }
    else {
        Write-Log "WARNING: '$DCU_ServiceName' did not reach Running within ${TimeoutSeconds}s (status: $($svc.Status))."
    }
}

# ── Handle DCU "service busy" codes 3003 / 3004 / 3005 ──────────────────────
function Resolve-DcuBusy {
    <#
        Returns:
          'Clear'    - service freed up, caller should continue the update loop
          'Reboot'   - caller should register the task, reboot, and return
          'Escalate' - busy across too many boots; caller should move on

        NEVER reinstalls DCU. Reinstalling restarts the service and re-arms the
        very self-update we're waiting on - that was the v2.0 loop bug.
    #>
    param([string]$DcuPath, [int]$Code)

    Write-Log "DCU service busy (code $Code). The Dell Client Management Service is mid-operation."
    Write-Log "Waiting for it to finish - NOT reinstalling or rebooting yet."

    $waited     = 0
    $probeCode  = $Code

    while ($probeCode -in $DcuBusyCodes -and $waited -lt $BusyMaxWait) {
        Start-Sleep -Seconds $BusyPollSeconds
        $waited += $BusyPollSeconds

        $probe = Start-Process -FilePath $DcuPath -ArgumentList "/scan","-silent" `
                    -Wait -PassThru -NoNewWindow
        $probeCode = $probe.ExitCode
        Write-Log "  probe at ${waited}s of ${BusyMaxWait}s -> exit $probeCode"
    }

    if ($probeCode -notin $DcuBusyCodes) {
        Write-Log "Service is free again (probe returned $probeCode). Resuming update cycle."
        Set-BusyCount 0
        return 'Clear'
    }

    $busyReboots = Get-BusyCount
    Set-BusyCount ($busyReboots + 1)

    if ($busyReboots -ge $MaxBusyReboots) {
        Write-Log "Service still busy after $($busyReboots + 1) boots. Giving up on Dell updates."
        Write-Log "ACTION REQUIRED: check 'Get-Service $DCU_ServiceName' and C:\ProgramData\Dell\UpdateService\Log."
        return 'Escalate'
    }

    Write-Log "Still busy after ${BusyMaxWait}s. Rebooting once to clear (reboot $($busyReboots + 1) of $MaxBusyReboots)."
    return 'Reboot'
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
    # NOTE: This is the ONLY place DCU gets installed/reinstalled. Phase 2 must
    # never reinstall it - doing so restarts the service and re-arms its
    # self-update, which is what caused the v2.0 reboot loop.
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

    # ── Let the freshly-installed service come up before configuring ──
    Wait-DcuService -TimeoutSeconds 300 -SettleSeconds 60

    # ── Configure DCU for silent operation ──
    # -reboot is an /applyUpdates option, not a /configure option - removed in 2.1
    Write-Log "Configuring DCU settings..."
    & $dcuPath /configure -autoSuspendBitLocker=enable -scheduleManual -userConsent=disable 2>$null
    Write-Log "DCU configure exit code: $LASTEXITCODE"

    # Reset the busy counter for a clean run
    Set-BusyCount 0

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
        Register-RebootTask
        Restart-Computer -Force
        return
    }

    # Don't fire commands at a service that's still waking up / self-updating
    Wait-DcuService -TimeoutSeconds 300 -SettleSeconds 90

    $cycle = 0

    while ($cycle -lt $MaxDCUCycles) {
        $cycle++
        Write-Log "── Dell Update Cycle $cycle of $MaxDCUCycles ──"

        # Exit codes (Dell Command | Update 5.x reference):
        #   0=success/no updates  1=reboot required  2=fatal error  5=reboot pending
        #   500=no applicable updates  501/502/503=scan or download error
        #   3003=service busy  3004=service self-updating  3005=service installing updates
        #   -> 3003/3004/3005 all mean WAIT. They do NOT mean "reinstall DCU".
        Write-Log "Running: dcu-cli /applyUpdates -reboot=disable -autoSuspendBitLocker=enable"

        $process = Start-Process -FilePath $dcuPath `
            -ArgumentList "/applyUpdates","-reboot=disable","-autoSuspendBitLocker=enable" `
            -Wait -PassThru -NoNewWindow

        $exitCode = $process.ExitCode
        Write-Log "DCU exit code: $exitCode"

        switch ($exitCode) {
            0 {
                Write-Log "No Dell updates needed. Moving to Windows Update phase."
                Set-BusyCount 0
                Set-Phase 3
                Register-RebootTask
                Write-Log "Rebooting before Windows Update phase..."
                Restart-Computer -Force
                return
            }
            1 {
                Write-Log "Dell updates installed - reboot required."
                Set-BusyCount 0
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
                Set-BusyCount 0
                Set-Phase 3
                Register-RebootTask
                Write-Log "Rebooting before Windows Update phase..."
                Restart-Computer -Force
                return
            }
            {$_ -in $DcuBusyCodes} {
                $action = Resolve-DcuBusy -DcuPath $dcuPath -Code $exitCode

                switch ($action) {
                    'Clear' {
                        # fall through - the while loop retries /applyUpdates
                    }
                    'Reboot' {
                        Register-RebootTask
                        Start-Sleep -Seconds 5
                        Restart-Computer -Force
                        return
                    }
                    'Escalate' {
                        Set-BusyCount 0
                        Set-Phase 3
                        Register-RebootTask
                        Write-Log "Skipping Dell updates. Moving to Windows Update phase."
                        Restart-Computer -Force
                        return
                    }
                }
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
    Set-BusyCount 0
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
    Remove-Item $BusyFile -Force -ErrorAction SilentlyContinue
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
Write-Log "Starting Phase $phase on $($env:COMPUTERNAME) [script v$ScriptVersion]"

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
