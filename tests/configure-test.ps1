# CI: configure.ps1 end to end - RealVNC install, key + ssh config + desktop folder, a real SSH
# login from "this PC" using the generated key and config, and the all-set marker.
. "$PSScriptRoot\assert.ps1"

$hosts = @{
  folder = 'My Computers'
  hosts  = @(
    @{ alias = 'selfhost'; aliases = @('selfhost2'); label = 'This runner'; ip = '127.0.0.1'; user = $env:USERNAME; kind = 'windows'; rdp_note = 'after hours' },
    @{ alias = 'fakemac'; label = 'Fake Mac'; ip = '127.0.0.1'; user = 'someone'; kind = 'mac' }
  )
}
$hf = Join-Path $env:TEMP 'tj-hosts.json'
[IO.File]::WriteAllText($hf, ($hosts | ConvertTo-Json -Depth 5))

& "$PSScriptRoot\..\configure.ps1" -HostsFile $hf -Part machine | Out-Host
Assert ([bool](Get-ChildItem "$env:ProgramFiles\RealVNC" -Recurse -Filter 'vncviewer.exe' -ErrorAction SilentlyContinue)) 'RealVNC Viewer installed'

& "$PSScriptRoot\..\configure.ps1" -HostsFile $hf -Part user | Out-Host
$key = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
Assert (Test-Path $key) 'this PC has its own SSH key'
Assert (Test-Path "$key.pub") 'and its public half'
$cfg = Join-Path $env:USERPROFILE '.ssh\config'
Assert-PlainAscii $cfg
$cfgText = Get-Content $cfg -Raw
Assert ($cfgText -match 'Host selfhost selfhost2') 'ssh config has the host block with aliases'
Assert ($cfgText -match 'StrictHostKeyChecking accept-new') 'first connection needs no yes/no prompt'

# second run keeps a single managed block
& "$PSScriptRoot\..\configure.ps1" -HostsFile $hf -Part user | Out-Null
Assert (([regex]::Matches((Get-Content $cfg -Raw), '# >>> tailnet-join')).Count -eq 1) 're-run keeps one managed block'

# authorize the new key the way the Mac does, then test from "this PC" with its own key + config
$pub = (Get-Content "$key.pub" -Raw).Trim()
$ak = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
Add-Content -Path $ak -Value $pub -Encoding ASCII
$v = & "$PSScriptRoot\..\configure.ps1" -HostsFile $hf -Part verify
$jsonText = (($v | Out-String) -split '=== tailnet-join result ===')[-1]
$res = $jsonText | ConvertFrom-Json
$self = @($res.checks | Where-Object { $_.alias -eq 'selfhost' })[0]
Assert ($self.ssh_ok -eq $true) "ssh selfhost works with the generated key and config ($($self.ssh_output))"

$folder = Join-Path ([Environment]::GetFolderPath('Desktop')) 'My Computers'
Assert (Test-Path (Join-Path $folder 'This runner, terminal.cmd')) 'terminal shortcut'
Assert (Test-Path (Join-Path $folder 'This runner, remote desktop (after hours).rdp')) 'remote desktop file'
Assert (Test-Path (Join-Path $folder 'Fake Mac, terminal.cmd')) 'mac terminal shortcut'
$lnkPath = Join-Path $folder 'Fake Mac, screen.lnk'
Assert (Test-Path $lnkPath) 'mac screen shortcut'
$lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
Assert ($lnk.TargetPath -like '*vncviewer.exe') "screen shortcut opens RealVNC ($($lnk.TargetPath))"
Assert ($lnk.Arguments -match '-UserName=someone' -and $lnk.Arguments -match '127\.0\.0\.1') "screen shortcut args ($($lnk.Arguments))"
$prefs = Get-ItemProperty 'HKCU:\Software\RealVNC\vncviewer'
Assert ($prefs.WarnUnencrypted -eq 'FALSE' -and $prefs.ShowSplash -eq 'FALSE' -and $prefs.AllowSignIn -eq 'FALSE') 'viewer prefs written'

& "$PSScriptRoot\..\configure.ps1" -Done -Message 'CI done' | Out-Null
Assert ((Get-Content (Join-Path $env:ProgramData 'tailnet-join\all-set.txt') -Raw) -eq 'CI done') 'all-set marker written'
exit 0
