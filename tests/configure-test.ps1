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
$viewer = Get-ChildItem "$env:ProgramFiles\RealVNC" -Recurse -Include 'rvncconnect.exe', 'vncviewer.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
Assert ([bool]$viewer) "RealVNC Viewer installed ($($viewer.FullName))"
# a .vnc file only opens with a double-click if Windows maps .vnc to the viewer
$assoc = (cmd /c assoc .vnc 2>&1 | Out-String).Trim()
$progId = ($assoc -split '=', 2)[-1]
$ftype = (cmd /c ftype $progId 2>&1 | Out-String).Trim()
$openCmd = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$progId\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
Write-Host "assoc: $assoc | ftype: $ftype | open: $openCmd"
Assert (($assoc -match '^\.vnc=') -and (("$ftype $openCmd") -match 'rvncconnect|vncviewer')) '.vnc files open with RealVNC'

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
$vncPath = Join-Path $folder 'Fake Mac, screen.vnc'
Assert (Test-Path $vncPath) 'mac screen connection file'
Assert-PlainAscii $vncPath
$vncText = Get-Content $vncPath -Raw
Assert ($vncText -match '(?m)^Host=127\.0\.0\.1' -and $vncText -match '(?m)^UserName=someone') "screen file points at the Mac with its user ($($vncText -replace "`r`n", ' | '))"
$prefs = Get-ItemProperty 'HKCU:\Software\RealVNC\rvncconnect'
Assert ($prefs.WarnUnencrypted -eq 'FALSE' -and $prefs.ShowSplash -eq 'FALSE' -and $prefs.AllowSignIn -eq 'FALSE') 'viewer prefs written'

& "$PSScriptRoot\..\configure.ps1" -Done -Message 'CI done' | Out-Null
Assert ((Get-Content (Join-Path $env:ProgramData 'tailnet-join\all-set.txt') -Raw) -eq 'CI done') 'all-set marker written'
exit 0
