<#
.SYNOPSIS
  Finish a tailnet-joined Windows PC over SSH: this PC's own SSH key, an ssh config for York's
  machines, RealVNC Viewer for the Macs' screens, and a "My Computers" folder on the desktop.

.DESCRIPTION
  Run over SSH after join.ps1. The machine list is NOT in this repo: it is a JSON file copied to
  the PC at run time, shaped like
    { "folder": "My Computers",
      "hosts": [ { "alias": "mini", "aliases": ["macmini"], "label": "Mac mini", "ip": "100.x.y.z",
                   "user": "someone", "kind": "mac" },
                 { "alias": "office", "label": "Office PC", "ip": "100.x.y.z", "user": "Some User",
                   "kind": "windows", "rdp_note": "after hours" } ] }
  kind "mac"     -> terminal (SSH) + screen (RealVNC to macOS Screen Sharing)
  kind "windows" -> terminal (SSH) + Remote Desktop file
  Progress lines go to C:\ProgramData\tailnet-join\progress.log, which join.ps1 shows on screen.

.PARAMETER HostsFile  Path to the JSON above.
.PARAMETER Part       machine = install RealVNC (needs admin); user = key, ssh config, viewer prefs,
                      desktop folder (run as the person who uses this PC); verify = test every host
                      from this PC with this PC's key; all = machine + user + verify.
.PARAMETER Done       Write the all-set marker (with -Message) so the waiting join.ps1 window finishes.
#>
[CmdletBinding()]
param(
  [string]$HostsFile = '',
  [ValidateSet('machine', 'user', 'verify', 'all', 'none')][string]$Part = 'none',
  [switch]$Done,
  [string]$Message = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Dir = Join-Path $env:ProgramData 'tailnet-join'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$ProgressLog = Join-Path $Dir 'progress.log'
$RealVnc = @{
  url    = 'https://downloads.realvnc.com/download/file/realvnc-connect-viewer/RealVNC-Connect-Viewer-8.5.0-Windows.msi.zip'
  sha256 = 'F2A145CF067CEEF5035AF9356313D1301EE64FB71E56C899144BC60DE0FF22BB'
}
$Utf8NoBom = New-Object Text.UTF8Encoding($false)
$Ascii = New-Object Text.ASCIIEncoding

function Say([string]$Msg) {
  Write-Host $Msg
  try { [IO.File]::AppendAllText($ProgressLog, $Msg + "`r`n", $Ascii) } catch {}
}
function Find-VncViewer {
  # RealVNC Connect Viewer 8 is rvncconnect.exe (older viewers were vncviewer.exe)
  try {
    $loc = (Get-ItemProperty 'HKLM:\SOFTWARE\RealVNC\installer\rvncconnect' -ErrorAction Stop).InstallLocation
    if ($loc -and (Test-Path (Join-Path $loc 'rvncconnect.exe'))) { return (Join-Path $loc 'rvncconnect.exe') }
  } catch {}
  foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
    if (-not $root) { continue }
    $base = Join-Path $root 'RealVNC'
    if (Test-Path $base) {
      $exe = Get-ChildItem -Path $base -Recurse -Include 'rvncconnect.exe', 'vncviewer.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($exe) { return $exe.FullName }
    }
  }
  return $null
}
function Find-SshDir {
  @((Join-Path $env:SystemRoot 'System32\OpenSSH'), (Join-Path $env:ProgramFiles 'OpenSSH')) | Where-Object { Test-Path (Join-Path $_ 'ssh.exe') } | Select-Object -First 1
}
function Invoke-Quiet([string]$Exe, [string]$ArgLine) {
  # one command-line string: empty arguments such as -N "" survive on every PowerShell version.
  # Temp files go in the caller's own TEMP: the tailnet-join folder is admin-write-only.
  $o = Join-Path $env:TEMP ('tj-out-{0}.tmp' -f [guid]::NewGuid()); $e = Join-Path $env:TEMP ('tj-err-{0}.tmp' -f [guid]::NewGuid())
  $p = Start-Process -FilePath $Exe -ArgumentList $ArgLine -Wait -PassThru -NoNewWindow -RedirectStandardOutput $o -RedirectStandardError $e
  $res = [pscustomobject]@{ code = $p.ExitCode; out = ((Get-Content $o -Raw -ErrorAction SilentlyContinue) -as [string]); err = ((Get-Content $e -Raw -ErrorAction SilentlyContinue) -as [string]) }
  Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
  return $res
}
function Set-PrivateAcl([string]$Path, [string]$Sid) {
  $r = Invoke-Quiet 'icacls.exe' ('"{0}" /setowner "*{1}"' -f $Path, $Sid)
  if ($r.code -ne 0) { throw "icacls /setowner ${Path}: $($r.out) $($r.err)" }
  $r = Invoke-Quiet 'icacls.exe' ('"{0}" /inheritance:r /grant:r "*{1}:F" "*S-1-5-18:F" "*S-1-5-32-544:F"' -f $Path, $Sid)
  if ($r.code -ne 0) { throw "icacls ${Path}: $($r.out) $($r.err)" }
}
function Test-Tcp([string]$Ip, [int]$Port, [bool]$ReadBanner) {
  $c = New-Object Net.Sockets.TcpClient
  try {
    $iar = $c.BeginConnect($Ip, $Port, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(6000)) { return 'timeout' }
    $c.EndConnect($iar)
    if (-not $ReadBanner) { return 'open' }
    $s = $c.GetStream()
    $s.ReadTimeout = 5000
    $buf = New-Object byte[] 12
    $n = $s.Read($buf, 0, 12)
    return ([Text.Encoding]::ASCII.GetString($buf, 0, $n)).Trim()
  } catch { return 'closed' } finally { $c.Close() }
}

$Result = [ordered]@{ part = $Part; computer = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"; ok = $true }
$Hosts = @()
$FolderName = 'My Computers'
if ($HostsFile) {
  $cfg = [IO.File]::ReadAllText($HostsFile) | ConvertFrom-Json
  $Hosts = @($cfg.hosts)
  if ($cfg.folder) { $FolderName = [string]$cfg.folder }
}
if ($Part -ne 'none' -and $Hosts.Count -eq 0) { throw 'no hosts: pass -HostsFile with a "hosts" list' }

# =====================================================================================
# machine: RealVNC Viewer (the free viewer speaks macOS Screen Sharing's own login)
# =====================================================================================
if (@('machine', 'all') -contains $Part) {
  $vnc = Find-VncViewer
  if (-not $vnc) {
    Say 'Installing the screen viewer (RealVNC Viewer)...'
    $zip = Join-Path $Dir 'realvnc-viewer.msi.zip'
    Invoke-WebRequest -Uri $RealVnc.url -OutFile $zip -UseBasicParsing -TimeoutSec 600
    $hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
    if ($hash -ne $RealVnc.sha256) { Remove-Item $zip -Force; throw "RealVNC download checksum mismatch ($hash)" }
    $x = Join-Path $Dir 'realvnc'
    Remove-Item -Path $x -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $x -Force
    $msi = Get-ChildItem -Path $x -Filter '*.msi' -Recurse | Select-Object -First 1
    if (-not $msi) { throw 'no MSI inside the RealVNC download' }
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "{0}" /qn /norestart' -f $msi.FullName) -Wait -PassThru
    if (@(0, 3010) -notcontains $p.ExitCode) { throw "RealVNC installer exit code $($p.ExitCode)" }
    Remove-Item -Path $x, $zip -Recurse -Force -ErrorAction SilentlyContinue
    $vnc = Find-VncViewer
    if (-not $vnc) { throw 'RealVNC installed but vncviewer.exe was not found' }
  }
  $Result.vncviewer = $vnc
  Say 'Screen viewer installed.'
}

# =====================================================================================
# user: this PC's own SSH key, ssh config, viewer prefs, desktop folder
# =====================================================================================
if (@('user', 'all') -contains $Part) {
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $bin = Find-SshDir
  if (-not $bin) { throw 'ssh.exe not found' }
  $sshDir = Join-Path $env:USERPROFILE '.ssh'
  New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
  $key = Join-Path $sshDir 'id_ed25519'
  if (-not (Test-Path $key)) {
    Say 'Creating this PC''s own SSH key...'
    $r = Invoke-Quiet (Join-Path $bin 'ssh-keygen.exe') ('-q -t ed25519 -N "" -C "{0}@{1}" -f "{2}"' -f $env:USERNAME, $env:COMPUTERNAME, $key)
    if ($r.code -ne 0) { throw "ssh-keygen failed: $($r.err)" }
  }
  Set-PrivateAcl -Path $key -Sid $sid
  # prove the key has no passphrase (a passphrase would make every shortcut prompt)
  $chk = Invoke-Quiet (Join-Path $bin 'ssh-keygen.exe') ('-y -P "" -f "{0}"' -f $key)
  if ($chk.code -ne 0) { throw "the SSH key at $key has a passphrase or is unreadable: $($chk.err)" }
  $pubFile = "$key.pub"
  if (-not (Test-Path $pubFile)) { [IO.File]::WriteAllText($pubFile, $chk.out.Trim() + "`n", $Ascii) }
  $Result.public_key = ([IO.File]::ReadAllText($pubFile)).Trim()

  # ssh config: our block first (first match wins in ssh_config), anything else the user had kept below it
  $sb = New-Object Text.StringBuilder
  [void]$sb.AppendLine('# >>> tailnet-join: York''s machines over the tailnet (rewritten by configure.ps1) >>>')
  foreach ($h in $Hosts) {
    $names = @([string]$h.alias) + @($h.aliases | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $u = [string]$h.user
    if ($u -match '\s') { $u = '"' + $u + '"' }
    [void]$sb.AppendLine('Host ' + ($names -join ' '))
    [void]$sb.AppendLine('  HostName ' + $h.ip)
    [void]$sb.AppendLine('  User ' + $u)
    [void]$sb.AppendLine('  IdentityFile ~/.ssh/id_ed25519')
    [void]$sb.AppendLine('  IdentitiesOnly yes')
    [void]$sb.AppendLine('  StrictHostKeyChecking accept-new')
    [void]$sb.AppendLine('  ServerAliveInterval 30')
    [void]$sb.AppendLine('  ConnectTimeout 15')
  }
  [void]$sb.AppendLine('# <<< tailnet-join <<<')
  $cfgPath = Join-Path $sshDir 'config'
  $rest = ''
  if (Test-Path $cfgPath) {
    $rest = [IO.File]::ReadAllText($cfgPath)
    $rest = [regex]::Replace($rest, '(?s)# >>> tailnet-join.*?# <<< tailnet-join <<<\r?\n?', '')
    $rest = $rest.TrimStart([char]0xFEFF)
  }
  [IO.File]::WriteAllText($cfgPath, $sb.ToString() + $rest, $Utf8NoBom)
  Set-PrivateAcl -Path $cfgPath -Sid $sid
  Say ('SSH shortcuts set up for: ' + (($Hosts | ForEach-Object { $_.alias }) -join ', '))

  # RealVNC Viewer: no sign-in screen, no "unencrypted" nag (the tailnet already encrypts), no analytics.
  # Connect Viewer 8 keeps its settings under rvncconnect, older viewers under vncviewer: set both.
  foreach ($rk in @('HKCU:\Software\RealVNC\rvncconnect', 'HKCU:\Software\RealVNC\vncviewer')) {
    New-Item -Path $rk -Force | Out-Null
    foreach ($kv in @(@('ShowSplash', 'FALSE'), @('AllowSignIn', 'FALSE'), @('WarnUnencrypted', 'FALSE'), @('SecurityNotificationTimeout', '0'), @('EnableAnalytics', 'FALSE'), @('Scaling', 'AspectFit'), @('UriSuppressConnectionPrompt', 'TRUE'))) {
      New-ItemProperty -Path $rk -Name $kv[0] -Value $kv[1] -PropertyType String -Force | Out-Null
    }
  }

  # the desktop folder
  $desk = [Environment]::GetFolderPath('Desktop')
  if (-not $desk) { $desk = Join-Path $env:USERPROFILE 'Desktop' }
  $folder = Join-Path $desk $FolderName
  New-Item -ItemType Directory -Force -Path $folder | Out-Null
  $ssh = Join-Path $bin 'ssh.exe'
  $vnc = Find-VncViewer
  $wsh = New-Object -ComObject WScript.Shell
  $made = New-Object System.Collections.ArrayList
  foreach ($h in $Hosts) {
    $label = [string]$h.label
    $cmdPath = Join-Path $folder ('{0}, terminal.cmd' -f $label)
    $cmdText = "@echo off`r`ntitle $label`r`n""$ssh"" $($h.alias)`r`nif errorlevel 1 pause`r`n"
    [IO.File]::WriteAllText($cmdPath, $cmdText, $Ascii)
    [void]$made.Add((Split-Path $cmdPath -Leaf))
    if ($h.kind -eq 'mac') {
      if ($vnc) {
        # Connect Viewer 8 (rvncconnect.exe) opens a direct connection the same way its own link handler
        # does (-uri com.realvnc.vncviewer.connect://host); RealVNC 8 registers no .vnc file type.
        # An older vncviewer.exe takes the address (and user name) directly.
        $lnkPath = Join-Path $folder ('{0}, screen.lnk' -f $label)
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath = $vnc
        if ((Split-Path $vnc -Leaf) -ieq 'rvncconnect.exe') { $lnk.Arguments = ('-uri com.realvnc.vncviewer.connect://{0}' -f $h.ip) }
        else { $lnk.Arguments = ('-UserName={0} {1}' -f $h.user, $h.ip) }
        $lnk.WorkingDirectory = (Split-Path $vnc)
        $lnk.IconLocation = "$vnc,0"
        $lnk.Description = "$label screen over the tailnet (Mac user name: $($h.user))"
        $lnk.Save()
        [void]$made.Add((Split-Path $lnkPath -Leaf))
      } else { Say "RealVNC is not installed yet, so there is no screen shortcut for $label" }
    }
    if ($h.kind -eq 'windows') {
      $note = if ($h.rdp_note) { " ($($h.rdp_note))" } else { '' }
      $rdpPath = Join-Path $folder ('{0}, remote desktop{1}.rdp' -f $label, $note)
      $rdpText = "full address:s:$($h.ip)`r`nusername:s:$($h.user)`r`nprompt for credentials:i:1`r`nscreen mode id:i:2`r`nauthentication level:i:2`r`n"
      [IO.File]::WriteAllText($rdpPath, $rdpText, [Text.Encoding]::Unicode)
      [void]$made.Add((Split-Path $rdpPath -Leaf))
    }
  }
  $Result.folder = $folder
  $Result.shortcuts = @($made)
  Say ("'{0}' folder is on the desktop ({1} shortcuts)." -f $FolderName, $made.Count)
}

# =====================================================================================
# verify: every host, from this PC, with this PC's own key and config
# =====================================================================================
if (@('verify', 'all') -contains $Part) {
  $bin = Find-SshDir
  $ssh = Join-Path $bin 'ssh.exe'
  $checks = New-Object System.Collections.ArrayList
  foreach ($h in $Hosts) {
    # Windows PowerShell turns native stderr into error records; under 'Stop' the first one would end the script
    $ErrorActionPreference = 'Continue'
    $out = (& $ssh -o BatchMode=yes -o ConnectTimeout=12 -o LogLevel=ERROR ([string]$h.alias) hostname 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $sshOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
    $port = if ($h.kind -eq 'mac') { 5900 } else { 3389 }
    $state = Test-Tcp -Ip ([string]$h.ip) -Port $port -ReadBanner ($h.kind -eq 'mac')
    [void]$checks.Add([pscustomobject]@{ alias = [string]$h.alias; ssh_ok = $sshOk; ssh_output = $out.Trim(); port = $port; port_state = $state })
    $portWord = if ($h.kind -eq 'mac') { 'screen' } else { 'remote desktop' }
    $sshWord = if ($sshOk) { 'OK' } else { 'FAILED' }
    Say ("Checked {0}: terminal {1}, {2} {3}" -f $h.label, $sshWord, $portWord, $state)
    if (-not $sshOk) { $Result.ok = $false }
  }
  $Result.checks = @($checks)
}

if ($Done) {
  $text = if ($Message) { $Message } else { 'Your computers are in the "My Computers" folder on the desktop.' }
  [IO.File]::WriteAllText((Join-Path $Dir 'all-set.txt'), $text, $Ascii)
  $Result.done = $true
}

Write-Output '=== tailnet-join result ==='
Write-Output ($Result | ConvertTo-Json -Depth 5)
