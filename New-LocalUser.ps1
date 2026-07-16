<#
.SYNOPSIS
    Create local admin user(s) - interactive, safe for public repo hosting.
.DESCRIPTION
    Prompts for username and password (masked, with confirmation), creates the
    local account, and adds it to the local Administrators group. Loops so
    multiple accounts can be created in one run.

    Launch with:
        irm https://raw.githubusercontent.com/jtnvdavid/scripts/main/New-LocalUser.ps1 | iex

.NOTES
    Author: Jasco Technology
    No credentials are stored in this script - password is prompted at runtime.
#>

# ── Elevation check (required because #Requires is ignored under irm|iex) ──
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run from an elevated PowerShell prompt." -ForegroundColor Red
    return
}

do {
    Write-Host ""
    Write-Host "═══ Create Local Admin User ═══" -ForegroundColor Yellow

    # ── Username ──
    $username = Read-Host "Enter the new username"
    if ([string]::IsNullOrWhiteSpace($username)) {
        Write-Host "No username entered. Skipping." -ForegroundColor Red
        continue
    }
    if (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
        Write-Host "User '$username' already exists. Skipping." -ForegroundColor Red
        continue
    }

    # ── Password (masked, with confirmation) ──
    $password  = Read-Host "Enter the password for $username" -AsSecureString
    $password2 = Read-Host "Confirm the password" -AsSecureString

    $p1 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
          [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))
    $p2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
          [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password2))

    if ($p1 -ne $p2) {
        Write-Host "Passwords do not match. Skipping." -ForegroundColor Red
        $p1 = $null; $p2 = $null
        continue
    }
    if ([string]::IsNullOrEmpty($p1)) {
        Write-Host "Blank password not allowed. Skipping." -ForegroundColor Red
        $p1 = $null; $p2 = $null
        continue
    }
    $p1 = $null; $p2 = $null   # clear plaintext copies immediately

    # ── Create user + add to Administrators ──
    try {
        New-LocalUser -Name $username `
            -Password $password `
            -PasswordNeverExpires `
            -UserMayNotChangePassword `
            -AccountNeverExpires `
            -ErrorAction Stop | Out-Null

        Add-LocalGroupMember -Group "Administrators" -Member $username -ErrorAction Stop

        Write-Host "✅ User '$username' created and added to local Administrators group." -ForegroundColor Green
    }
    catch {
        Write-Host "ERROR: $_" -ForegroundColor Red
        # If the user was created but the group add failed, say so
        if (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
            Write-Host "Note: account '$username' exists but may NOT be in Administrators. Verify manually." -ForegroundColor Yellow
        }
    }

    # ── Another? ──
    $again = Read-Host "Create another user? (y/N)"
} while ($again -match '^[Yy]')

Write-Host ""
Write-Host "Done. Current members of Administrators:" -ForegroundColor Cyan
Get-LocalGroupMember -Group "Administrators" | ForEach-Object { Write-Host "  - $($_.Name)" }
