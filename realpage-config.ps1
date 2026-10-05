# RealPage workstation config (per-user / HKCU)
# Run in a NORMAL (non-elevated) PowerShell window as the user who will use RealPage.

$base = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings'

# Each entry: subkey, value name, DWORD data
$settings = @(
    @{ Key = "$base\Cache\Content";                      Name = 'CacheLimit'; Data = 1048576 }  # 1024 MB in KB
    @{ Key = "$base\5.0\Cache\Content";                  Name = 'CacheLimit'; Data = 1048576 }
    @{ Key = "$base\ZoneMap\Domains\realpage.com\*";     Name = 'https';      Data = 2 }        # *.realpage.com -> Trusted Sites
    @{ Key = "$base\Zones\2";                            Name = '1001';       Data = 0 }        # Download signed ActiveX -> Enable
    @{ Key = "$base\Zones\2";                            Name = '1405';       Data = 0 }        # Script ActiveX marked safe -> Enable
    @{ Key = "$base\Zones\2";                            Name = '1608';       Data = 3 }        # Allow META REFRESH -> Disable
    @{ Key = "$base\Zones\2";                            Name = '2102';       Data = 0 }        # Script windows w/o size/position -> Enable
)

$hkcu = [Microsoft.Win32.Registry]::CurrentUser
$allGood = $true

foreach ($s in $settings) {
    # .NET registry API used so the literal '*' key name isn't treated as a wildcard
    $key = $hkcu.CreateSubKey($s.Key)
    $key.SetValue($s.Name, $s.Data, [Microsoft.Win32.RegistryValueKind]::DWord)
    $actual = $key.GetValue($s.Name)
    $key.Close()

    if ($actual -eq $s.Data) { $status = 'OK' } else { $status = 'MISMATCH'; $allGood = $false }
    Write-Host ("[{0}] HKCU\{1}\{2} = {3}" -f $status, $s.Key, $s.Name, $actual)
}

if ($allGood) { Write-Host "`nRealPage settings applied for $env:USERNAME." -ForegroundColor Green }
else          { Write-Host "`nOne or more settings did not apply." -ForegroundColor Red }
