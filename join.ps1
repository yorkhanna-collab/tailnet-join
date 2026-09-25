<#
.SYNOPSIS
  Join this Windows PC to York's tailnet and open key-only admin SSH over it, so everything
  else can be finished remotely from the Mac.

.DESCRIPTION
  Run ONCE from an *administrator* PowerShell. Safe to re-run.
    1. Tailscale   - installs/upgrades Tailscale (unattended mode) and joins with a one-time key
    2. SSH         - OpenSSH Server, York's laptop + Mac mini keys authorized, port 22 open to the
                     tailnet only (never the home network or the internet)
    3. RDP         - Remote Desktop (network-level auth, tailnet only) where the Windows edition has it
    4. Self-test   - proves a key login works on this PC before saying so
    5. Report      - posts what it found to the Mac mini over the tailnet, which also checks that
                     port 22 is reachable from the tailnet (third-party firewalls block it silently)
    6. Wait        - keeps the PC awake and shows Claude's progress until the remote setup is done
  Nothing secret lives in this file: the join key and the report address are passed in.

.PARAMETER TsKey    Tailscale auth key (tskey-auth-...). Also read from $env:TS_AUTHKEY.
.PARAMETER Name     Tailnet name for this PC (default home-pc).
.PARAMETER Tailnet  Expected tailnet name; if given, joining a different tailnet is treated as a failure.
.PARAMETER Report   host:port of the report receiver on the tailnet.
.PARAMETER ForUser  Account to authorize for SSH (default: whoever is signed in at the screen).

.EXAMPLE
  [Net.ServicePointManager]::SecurityProtocol=3072; Set-ExecutionPolicy Bypass -Scope Process -Force; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/yorkhanna-collab/tailnet-join/<commit>/join.ps1))) -TsKey 'tskey-auth-...' -Name home-pc -Tailnet '<tailnet>' -Report '<ip>:<port>'
#>
[CmdletBinding()]
param(
  [string]$TsKey = $env:TS_AUTHKEY,
  [string]$Name = 'home-pc',
  [string]$Tailnet = '',
  [string]$Report = '',
  [string]$ForUser = '',
  [switch]$SkipTailscale,
  [switch]$SkipRdp,
  [switch]$NoWait,
  [switch]$NoUpload,
  [int]$WaitMinutes = 30
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Script:Version = '2026-09-24.1'
$Dir = Join-Path $env:ProgramData 'tailnet-join'
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = Join-Path $Dir "join-$Stamp.log"
try { Start-Transcript -Path $LogFile -Force | Out-Null } catch {}

# ---- who may administer this PC: York's laptop + the Mac mini. Public keys only. ----
$AdminKeys = @(
  'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO7XKqXPPWccosK5i9E+uwQmSNpHx1UQo14YMgcpijnj york@macbook->mini'
  'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFeNznFi6Yhtzibn+Uw03r7i4q0nu9IpYSEN+a3y9y+E macmini-to-stations'
)
$TailnetRanges = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')   # Tailscale IPv4 CGNAT + IPv6 ULA
$SidSystem = 'S-1-5-18'
$SidAdmins = 'S-1-5-32-544'
# Fallback when the Windows OpenSSH feature will not install (pinned release + SHA256).
$OpenSshMsi = @{
  'AMD64' = @{ url = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.3.0p2-Preview/OpenSSH-Win64-v9.8.3.0.msi'; sha256 = 'C8A8C7E21136A099665C2FAD9ACCB41152D129466B719EA71678BAB665E03389' }
  'ARM64' = @{ url = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.3.0p2-Preview/OpenSSH-ARM64-v9.8.3.0.msi'; sha256 = '5CBE84935B51402BD5DE0E0E00B8F0C7A7AE605A9F1D3D3C1D0172C6343EAEBB' }
}

$Summary = New-Object System.Collections.ArrayList
function Note([string]$Area, [string]$Msg, [string]$Level = 'OK') {
  $line = '[{0,-4}] {1,-9} {2}' -f $Level, $Area, $Msg
  switch ($Level) { 'FAIL' { Write-Host $line -ForegroundColor Red } 'WARN' { Write-Host $line -ForegroundColor Yellow } 'TODO' { Write-Host $line -ForegroundColor Magenta } default { Write-Host $line -ForegroundColor Green } }
  [void]$Summary.Add([pscustomobject]@{ level = $Level; area = $Area; msg = $Msg })
}
function Step([string]$Title) { Write-Host ''; Write-Host ("== $Title ==") -ForegroundColor Cyan }
function Try-Run([string]$What, [scriptblock]$Block) {
  try { & $Block } catch { Note 'error' ("{0}: {1}" -f $What, $_.Exception.Message) 'WARN' }
}
function Finish {
  try { Stop-Transcript | Out-Null } catch {}
}

Write-Host ''
Write-Host "tailnet-join $Script:Version  ($env:COMPUTERNAME)" -ForegroundColor Cyan
Write-Host "Log: $LogFile"

# ---- admin check (a #Requires line is ignored when the script is piped through irm) ----
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
  Write-Host 'This must run from an ADMINISTRATOR PowerShell: Start -> type powershell -> right-click Windows PowerShell -> Run as administrator.' -ForegroundColor Red
  Finish
  return
}
if ($env:PROCESSOR_ARCHITEW6432) { Note 'windows' 'this is the 32-bit PowerShell; the 64-bit "Windows PowerShell" is preferred' 'WARN' }
# a stale progress log from an earlier run would be replayed in the wait loop
Remove-Item -Path (Join-Path $Dir 'progress.log'), (Join-Path $Dir 'all-set.txt') -Force -ErrorAction SilentlyContinue

# =====================================================================================
# ACCOUNTS - who is at the screen, who elevated, and who gets SSH
# =====================================================================================
function Test-AdminSid([string]$Sid) {
  try {
    $members = @(Get-LocalGroupMember -SID $SidAdmins -ErrorAction Stop)
    return [bool]($members | Where-Object { $_.SID -and $_.SID.Value -eq $Sid })
  } catch {
    # Get-LocalGroupMember throws on orphaned or cloud members; fall back to ADSI
    try {
      $grpName = ((New-Object Security.Principal.SecurityIdentifier($SidAdmins)).Translate([Security.Principal.NTAccount]).Value -split '\\')[-1]
      $grp = [ADSI]"WinNT://./$grpName,group"
      foreach ($m in @($grp.psbase.Invoke('Members'))) {
        $bytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
        if ((New-Object Security.Principal.SecurityIdentifier($bytes, 0)).Value -eq $Sid) { return $true }
      }
    } catch {}
    return $false
  }
}
function Get-AccountInfo([string]$Account) {
  if (-not $Account) { return $null }
  $sid = $null
  foreach ($candidate in @($Account, "$env:COMPUTERNAME\$Account")) {
    if ($sid) { break }
    try { $sid = (New-Object Security.Principal.NTAccount($candidate)).Translate([Security.Principal.SecurityIdentifier]).Value } catch {}
  }
  if (-not $sid) { return $null }
  $full = $Account
  try { $full = (New-Object Security.Principal.SecurityIdentifier($sid)).Translate([Security.Principal.NTAccount]).Value } catch {}
  $domain = ($full -split '\\')[0]
  $sam = ($full -split '\\')[-1]
  $profilePath = $null
  try {
    $pp = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
    if ($pp) { $profilePath = [Environment]::ExpandEnvironmentVariables($pp) }
  } catch {}
  $login = if ($domain -eq 'AzureAD') { "azuread\$sam" } else { $sam }
  [pscustomobject]@{ account = $full; sam = $sam; sid = $sid; profile = $profilePath; is_admin = (Test-AdminSid $sid); ssh_login = $login }
}

$Me = [Security.Principal.WindowsIdentity]::GetCurrent()
$Elevating = Get-AccountInfo $Me.Name
$ConsoleName = $null
try { $ConsoleName = (Get-CimInstance Win32_ComputerSystem).UserName } catch {}
$Target = $null
if ($ForUser) { $Target = Get-AccountInfo $ForUser; if (-not $Target) { Note 'account' "no local account named '$ForUser'" 'FAIL' } }
elseif ($ConsoleName) { $Target = Get-AccountInfo $ConsoleName }
if (-not $Target) { $Target = $Elevating }
Note 'account' ("SSH account: {0} (admin: {1}); this window runs as {2}" -f $Target.account, $Target.is_admin, $Elevating.account)

# =====================================================================================
# REPORT - built up as we go, saved locally, posted to the Mac mini
# =====================================================================================
$Rep = [ordered]@{}
$Rep.purpose = 'tailnet-join'
$Rep.script_version = $Script:Version
$Rep.name = $Name
$Rep.computer = $env:COMPUTERNAME
Try-Run 'os' {
  $os = Get-CimInstance Win32_OperatingSystem
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  $Rep.os = "$($os.Caption) $($cv.DisplayVersion) build $($os.BuildNumber)"
  $Rep.edition_id = $cv.EditionID
  $cs = Get-CimInstance Win32_ComputerSystem
  $Rep.model = "$($cs.Manufacturer) $($cs.Model)"
  $Rep.ram_gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
}
$Arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$Rep.arch = $Arch
$Rep.console_account = $ConsoleName
$Rep.target = $Target
$Rep.elevated_by = $Elevating
Try-Run 'admins' { $Rep.local_admins = @(Get-LocalGroupMember -SID $SidAdmins -ErrorAction Stop | ForEach-Object { $_.Name }) }
Try-Run 'firewall' {
  $Rep.defender_firewall = @(Get-NetFirewallProfile -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ profile = $_.Name; enabled = [string]$_.Enabled; allow_inbound_rules = [string]$_.AllowInboundRules } })
  try { $Rep.firewall_products = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction Stop | ForEach-Object { $_.displayName }) } catch {}
  try { $Rep.antivirus_products = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName }) } catch {}
}

function Save-Report([string]$Stage) {
  $Rep.stage = $Stage
  $Rep.taken_at = (Get-Date).ToString('s')
  $Rep.summary = $Summary
  $json = $Rep | ConvertTo-Json -Depth 6
  [IO.File]::WriteAllText((Join-Path $Dir 'report.json'), $json, (New-Object Text.UTF8Encoding($false)))
  return $json
}
function Send-Report([string]$Stage, [int]$TrySeconds = 90, [hashtable]$Probe = $null) {
  if ($Probe) { $Rep.probe = $Probe } else { $Rep.Remove('probe') }
  $json = Save-Report $Stage
  if ($NoUpload -or -not $Report) { return $null }
  $deadline = (Get-Date).AddSeconds($TrySeconds)
  $lastErr = ''
  do {
    try {
      return Invoke-RestMethod -Method Post -Uri "http://$Report/report" -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 20 -UseBasicParsing
    } catch { $lastErr = $_.Exception.Message; Start-Sleep -Seconds 5 }
  } while ((Get-Date) -lt $deadline)
  Note 'report' ("could not reach the Mac mini: {0}" -f $lastErr) 'WARN'
  return $null
}

# =====================================================================================
# 1. TAILSCALE
# =====================================================================================
$TsExe = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
function Get-TsStatus {
  if (-not (Test-Path $TsExe)) { return $null }
  try { return ((& $TsExe status --json 2>$null) | Out-String | ConvertFrom-Json) } catch { return $null }
}
$TsIp = $null
if (-not $SkipTailscale) {
  Step 'Tailscale'
  Try-Run 'tailscale-install' {
    $tsArch = switch ($Arch) { 'ARM64' { 'arm64' } 'x86' { 'x86' } default { 'amd64' } }
    $msi = Join-Path $Dir "tailscale-setup-$tsArch.msi"
    Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest-$tsArch.msi" -OutFile $msi -UseBasicParsing -TimeoutSec 300
    # always run it: installs, or upgrades an old client, and forces unattended mode (runs before anyone signs in)
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "{0}" /quiet /norestart TS_UNATTENDEDMODE=always' -f $msi) -Wait -PassThru
    if (@(0, 3010, 1638) -notcontains $p.ExitCode) { throw "Tailscale installer exit code $($p.ExitCode)" }
    Note 'tailscale' ("installed/updated ({0})" -f $tsArch)
  }
  # wait for the Tailscale service to answer
  $st = $null
  for ($i = 0; $i -lt 30 -and -not ($st -and $st.BackendState); $i++) { Start-Sleep -Seconds 2; $st = Get-TsStatus }
  if (-not $st) {
    Note 'tailscale' 'Tailscale did not start - tell Claude' 'FAIL'
    Save-Report 'tailscale-failed' | Out-Null
    Finish
    return
  }
  $onOurs = ($st.BackendState -eq 'Running') -and (-not $Tailnet -or ($st.CurrentTailnet -and $st.CurrentTailnet.Name -eq $Tailnet))
  $upOut = ''
  if ($onOurs) {
    $upOut = (& $TsExe up --reset --unattended "--hostname=$Name" --timeout=60s 2>&1 | Out-String)
    Note 'tailscale' 'already on the tailnet'
  } elseif (-not $TsKey) {
    Note 'tailscale' 'no join key was given - ask Claude for the full command' 'FAIL'
    Save-Report 'no-key' | Out-Null
    Finish
    return
  } elseif ($st.BackendState -eq 'Running') {
    # signed in to some other tailnet: add ours as a second profile instead of throwing that login away
    Note 'tailscale' ("this PC was on another tailnet ({0}); adding York's alongside it" -f $st.CurrentTailnet.Name) 'WARN'
    $upOut = (& $TsExe login "--auth-key=$TsKey" "--hostname=$Name" --timeout=60s 2>&1 | Out-String)
    & $TsExe set --unattended 2>&1 | Out-Null
  } else {
    $upOut = (& $TsExe up --reset "--auth-key=$TsKey" "--hostname=$Name" --unattended --timeout=60s 2>&1 | Out-String)
  }
  $st = Get-TsStatus
  $joined = $st -and $st.BackendState -eq 'Running' -and (-not $Tailnet -or ($st.CurrentTailnet -and $st.CurrentTailnet.Name -eq $Tailnet))
  if (-not $joined) {
    $why = ($upOut -replace 'tskey-[A-Za-z0-9-]+', 'tskey-***').Trim()
    Note 'tailscale' ("could not join the tailnet (state {0}). The join key may be used up or expired - tell Claude. Details: {1}" -f $st.BackendState, $why) 'FAIL'
    Save-Report 'join-failed' | Out-Null
    Finish
    return
  }
  $TsIp = (& $TsExe ip -4 2>$null | Select-Object -First 1)
  $Rep.tailscale = [ordered]@{ state = $st.BackendState; tailnet = $st.CurrentTailnet.Name; host_name = $st.Self.HostName; dns_name = $st.Self.DNSName; ip4 = $TsIp; version = $st.Version }
  Note 'tailscale' ("connected as {0} ({1})" -f $st.Self.DNSName, $TsIp)
  # tell the Mac mini right away, so the account names are known even if a later step fails
  [void](Send-Report 'joined' 90)
}

# =====================================================================================
# 2. OPENSSH SERVER - key-only logins from York's machines, tailnet only
# =====================================================================================
Step 'SSH'
$SshSource = 'preexisting'
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
  $SshSource = 'windows-feature'
  Note 'ssh' 'installing the Windows OpenSSH Server feature (can take a few minutes)...'
  $job = Start-Job -ScriptBlock {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
  }
  if (-not (Wait-Job $job -Timeout 360)) { Stop-Job $job -ErrorAction SilentlyContinue; Note 'ssh' 'the Windows feature install timed out' 'WARN' }
  try { Receive-Job $job -ErrorAction Stop | Out-Null } catch { Note 'ssh' ("Windows feature install: {0}" -f $_.Exception.Message) 'WARN' }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
}
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
  $SshSource = 'msi'
  Try-Run 'openssh-msi' {
    $pick = if ($OpenSshMsi.ContainsKey($Arch)) { $OpenSshMsi[$Arch] } else { $OpenSshMsi['AMD64'] }
    $file = Join-Path $Dir (Split-Path $pick.url -Leaf)
    Invoke-WebRequest -Uri $pick.url -OutFile $file -UseBasicParsing -TimeoutSec 300
    $hash = (Get-FileHash -Path $file -Algorithm SHA256).Hash
    if ($hash -ne $pick.sha256) { Remove-Item $file -Force; throw "OpenSSH MSI checksum mismatch ($hash)" }
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/i "{0}" /qn /norestart' -f $file) -Wait -PassThru
    if (@(0, 3010) -notcontains $p.ExitCode) { throw "OpenSSH installer exit code $($p.ExitCode)" }
    Note 'ssh' 'installed OpenSSH from the Win32-OpenSSH release'
  }
}
$Rep.sshd_source = $SshSource
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
  Note 'ssh' 'OpenSSH Server could not be installed - tell Claude' 'FAIL'
  [void](Send-Report 'ssh-failed' 30)
  Finish
  return
}

$SshBinDir = @((Join-Path $env:SystemRoot 'System32\OpenSSH'), (Join-Path $env:ProgramFiles 'OpenSSH')) | Where-Object { Test-Path (Join-Path $_ 'ssh.exe') } | Select-Object -First 1
if (-not $SshBinDir) {
  Try-Run 'openssh-client' {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Client*' | Select-Object -First 1
    if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
  }
  $SshBinDir = @((Join-Path $env:SystemRoot 'System32\OpenSSH'), (Join-Path $env:ProgramFiles 'OpenSSH')) | Where-Object { Test-Path (Join-Path $_ 'ssh.exe') } | Select-Object -First 1
}

Try-Run 'sshd-service' {
  Set-Service sshd -StartupType Automatic
  if ((Get-Service sshd).Status -ne 'Running') { Start-Service sshd }   # first start writes sshd_config + host keys
  New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
  New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -PropertyType String -Force | Out-Null
  Note 'ssh' 'OpenSSH Server running, starts with Windows, lands in PowerShell'
}

# Write a key file: merge-unique, plain ASCII (no BOM, no UTF-16), owner + ACL the way sshd demands.
function Set-KeyFile([string]$Path, [string[]]$Add, [string[]]$RemoveLike, [string]$OwnerSid, [string[]]$GrantSids) {
  $parent = Split-Path $Path
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $lines = @()
  if (Test-Path $Path) { $lines = @(Get-Content -Path $Path -ErrorAction SilentlyContinue) }
  if ($RemoveLike) { foreach ($pat in $RemoveLike) { $lines = @($lines | Where-Object { $_ -notlike $pat }) } }
  $merged = @(@($lines) + @($Add) | ForEach-Object { if ($_) { $_.Trim() } } | Where-Object { $_ } | Select-Object -Unique)
  $text = ''
  if ($merged.Count -gt 0) { $text = ($merged -join "`r`n") + "`r`n" }
  [IO.File]::WriteAllText($Path, $text, (New-Object Text.ASCIIEncoding))
  $o1 = & icacls.exe $Path /setowner "*$OwnerSid" 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "icacls /setowner on ${Path}: $($o1.Trim())" }
  $icaclsArgs = @($Path, '/inheritance:r')
  foreach ($g in $GrantSids) { $icaclsArgs += '/grant:r'; $icaclsArgs += "*${g}:F" }
  $o2 = & icacls.exe @icaclsArgs 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "icacls on ${Path}: $($o2.Trim())" }
}
$AdminKeyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
$UserKeyFile = $null
if ($Target.profile) { $UserKeyFile = Join-Path $Target.profile '.ssh\authorized_keys' }
Try-Run 'ssh-keys' {
  # Windows OpenSSH reads administrators_authorized_keys for every administrator account ...
  Set-KeyFile -Path $AdminKeyFile -Add $AdminKeys -OwnerSid $SidAdmins -GrantSids @($SidSystem, $SidAdmins)
  Note 'ssh' 'York''s laptop + Mac mini keys authorized for administrator accounts'
  # ... and the account's own authorized_keys only for a standard (non-admin) account
  if (-not $Target.is_admin) {
    if ($UserKeyFile) {
      Set-KeyFile -Path $UserKeyFile -Add $AdminKeys -OwnerSid $Target.sid -GrantSids @($Target.sid, $SidSystem, $SidAdmins)
      Note 'ssh' ("keys also authorized for the standard account {0}" -f $Target.sam)
    } else { Note 'ssh' ("{0} has no profile folder yet, so only administrator logins are set up" -f $Target.sam) 'WARN' }
    # Newer Windows ships sshd_config with 'AllowGroups administrators "openssh users"': a standard
    # account can only log in over SSH if it is in the local OpenSSH Users group.
    $allow = @(Get-Content -Path (Join-Path $env:ProgramData 'ssh\sshd_config') -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*AllowGroups\s' })
    if ($allow.Count -gt 0) {
      if (($allow -join ' ') -match 'openssh users') {
        if (-not (Get-LocalGroup -Name 'OpenSSH Users' -ErrorAction SilentlyContinue)) { New-LocalGroup -Name 'OpenSSH Users' -Description 'Members may log in with OpenSSH' | Out-Null }
        if (-not (Get-LocalGroupMember -Group 'OpenSSH Users' -ErrorAction SilentlyContinue | Where-Object { $_.SID -and $_.SID.Value -eq $Target.sid })) {
          Add-LocalGroupMember -Group 'OpenSSH Users' -Member $Target.sid
        }
        Note 'ssh' ("{0} is in the OpenSSH Users group (this Windows only lets administrators and that group log in over SSH)" -f $Target.sam)
      } else { Note 'ssh' ("sshd_config limits SSH logins to: {0}" -f ($allow -join '; ')) 'WARN' }
    }
  }
}

Try-Run 'ssh-firewall' {
  # port 22 only from the tailnet: turn off any other inbound rule for TCP 22 (the feature's own rule allows everyone)
  $other = @(Get-NetFirewallPortFilter -Protocol TCP -ErrorAction SilentlyContinue | Where-Object { @($_.LocalPort) -contains '22' } | Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and $_.Enabled -eq 'True' -and $_.Name -ne 'tailnet-join-ssh' })
  foreach ($r in $other) { Disable-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue }
  $Rep.ssh_rules_disabled = @($other | ForEach-Object { $_.DisplayName })
  Get-NetFirewallRule -Name 'tailnet-join-ssh' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
  New-NetFirewallRule -Name 'tailnet-join-ssh' -DisplayName 'SSH from the tailnet (tailnet-join)' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -RemoteAddress $TailnetRanges -Profile Any | Out-Null
  Note 'ssh' ("port 22 open to the tailnet only ({0} other rule(s) for port 22 turned off)" -f $other.Count)
}
Try-Run 'sshd-restart' { Restart-Service sshd -Force }

# =====================================================================================
# 3. REMOTE DESKTOP - only where the Windows edition can host it (not on Home)
# =====================================================================================
Step 'Remote Desktop'
$RdpCapable = -not ([string]$Rep.edition_id -match '^Core')
$Rep.rdp_capable = $RdpCapable
$Rep.rdp_enabled = $false
if ($SkipRdp) { Note 'rdp' 'skipped' }
elseif (-not $RdpCapable) { Note 'rdp' ("Windows {0} cannot be remoted into with Remote Desktop; SSH still works" -f $Rep.edition_id) 'WARN' }
else {
  Try-Run 'rdp' {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1 -PropertyType DWord -Force | Out-Null
    $rules = @(Get-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue)
    if ($rules.Count -eq 0) { $rules = @(Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue) }
    foreach ($r in $rules) { Set-NetFirewallRule -Name $r.Name -Enabled True -RemoteAddress $TailnetRanges -ErrorAction SilentlyContinue }
    $Rep.rdp_enabled = $true
    Note 'rdp' 'Remote Desktop on (network-level auth), tailnet only'
  }
}

# =====================================================================================
# 4. SELF-TEST - a real key login to this PC, as the SSH account, before claiming success
# =====================================================================================
Step 'Self-test'
$SelfTest = [ordered]@{ ok = $false; output = '' }
Try-Run 'self-test' {
  if (-not $SshBinDir) { throw 'ssh.exe not found' }
  $stDir = Join-Path $Dir 'selftest'
  Remove-Item -Path $stDir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $stDir | Out-Null
  $key = Join-Path $stDir 'k'
  # one command-line string, so -N "" reaches ssh-keygen as an empty passphrase on every PowerShell version
  $kg = Start-Process -FilePath (Join-Path $SshBinDir 'ssh-keygen.exe') -ArgumentList ('-q -t ed25519 -N "" -C tailnet-join-selftest -f "{0}"' -f $key) -Wait -PassThru -NoNewWindow
  if ($kg.ExitCode -ne 0 -or -not (Test-Path "$key.pub")) { throw "ssh-keygen exit $($kg.ExitCode)" }
  & icacls.exe $key /inheritance:r /grant:r "*${SidSystem}:F" "*${SidAdmins}:F" "*$($Elevating.sid):F" | Out-Null
  $pub = (Get-Content "$key.pub" -Raw).Trim()
  $file = if ($Target.is_admin) { $AdminKeyFile } else { $UserKeyFile }
  $owner = if ($Target.is_admin) { $SidAdmins } else { $Target.sid }
  $grants = if ($Target.is_admin) { @($SidSystem, $SidAdmins) } else { @($Target.sid, $SidSystem, $SidAdmins) }
  Set-KeyFile -Path $file -Add @($pub) -OwnerSid $owner -GrantSids $grants
  try {
    $out = (& (Join-Path $SshBinDir 'ssh.exe') -i $key -o BatchMode=yes -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR -o ConnectTimeout=20 -l $Target.ssh_login 127.0.0.1 whoami 2>&1 | ForEach-Object { "$_" }) -join "`n"
    $SelfTest.output = $out.Trim()
    $SelfTest.ok = ($LASTEXITCODE -eq 0) -and ($out -match [regex]::Escape($Target.sam))
  } finally {
    Set-KeyFile -Path $file -Add @() -RemoveLike @('*tailnet-join-selftest*') -OwnerSid $owner -GrantSids $grants
    Remove-Item -Path $stDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($SelfTest.ok) { Note 'selftest' ("key login as {0} works ({1})" -f $Target.ssh_login, $SelfTest.output) }
  else { Note 'selftest' ("key login as {0} FAILED: {1}" -f $Target.ssh_login, $SelfTest.output) 'FAIL' }
}
$Rep.self_test = $SelfTest

# =====================================================================================
# 5. REPORT + REACHABILITY - the Mac mini tries port 22 (and 3389) back over the tailnet
# =====================================================================================
Step 'Report'
$Reachable = $null
if ($TsIp -and -not $NoUpload -and $Report) {
  $ports = @(22); if ($Rep.rdp_enabled) { $ports += 3389 }
  $deadline = (Get-Date).AddMinutes(3)
  $warned = $false
  $probed = $false
  do {
    $resp = Send-Report 'ready' 60 @{ ip = $TsIp; ports = $ports }
    if (-not ($resp -and $resp.probe)) { Note 'reach' 'reachability not checked (the Mac mini did not answer the probe)' 'WARN'; break }
    $probed = $true
    $Reachable = [string]$resp.probe.'22'
    $Rep.reachability = $resp.probe
    if ($Reachable -eq 'open') { Note 'reach' 'the Mac mini can reach this PC over the tailnet (port 22 open)'; break }
    if (-not $warned) {
      $fw = @($Rep.firewall_products | Where-Object { $_ -and $_ -notmatch 'Windows Defender|Microsoft Defender' })
      Write-Host ''
      Write-Host ("The Mac mini cannot reach this PC yet (port 22: {0})." -f $Reachable) -ForegroundColor Yellow
      if ($fw.Count -gt 0) { Write-Host ("Your {0} firewall is probably blocking it. If it asks about 'sshd', click Allow; otherwise open it and allow incoming connections for sshd.exe." -f ($fw -join ', ')) -ForegroundColor Yellow }
      else { Write-Host 'If a security window asks about sshd, click Allow. Retrying for 3 minutes...' -ForegroundColor Yellow }
      $warned = $true
    }
    Start-Sleep -Seconds 15
  } while ((Get-Date) -lt $deadline)
  if ($probed -and $Reachable -ne 'open') { Note 'reach' ("the Mac mini still cannot reach port 22 on this PC ({0})" -f $Reachable) 'FAIL' }
  [void](Save-Report 'ready')
} else {
  [void](Save-Report 'ready')
}

# =====================================================================================
# 6. WAIT - keep the PC awake while Claude finishes, show progress, then say ALL SET
# =====================================================================================
$fails = @($Summary | Where-Object level -eq 'FAIL').Count
Write-Host ''
if ($fails -gt 0) {
  Write-Host ("Finished with {0} problem(s). Tell Claude - the details already went to the Mac mini (and are in {1})." -f $fails, $LogFile) -ForegroundColor Red
  Finish
  return
}
if ($NoWait) {
  Write-Host 'DONE (no wait requested).' -ForegroundColor Green
  Finish
  return
}

Add-Type -Namespace TailnetJoin -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction SilentlyContinue
$ES_CONTINUOUS = [uint32]2147483648
$ES_SYSTEM_REQUIRED = [uint32]1
try { [void][TailnetJoin.Power]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) } catch {}
$Marker = Join-Path $Dir 'all-set.txt'
$Progress = Join-Path $Dir 'progress.log'
Write-Host 'Connected. LEAVE THIS WINDOW OPEN - Claude is finishing the setup from the Mac (usually 10-20 minutes).' -ForegroundColor Cyan
Write-Host 'This PC will not go to sleep until it is done.' -ForegroundColor Cyan
$seen = 0
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$done = $false
while ((Get-Date) -lt $deadline) {
  if (Test-Path $Progress) {
    $lines = @(Get-Content -Path $Progress -ErrorAction SilentlyContinue)
    for ($i = $seen; $i -lt $lines.Count; $i++) { Write-Host ('  > ' + $lines[$i]) }
    $seen = $lines.Count
  }
  if (Test-Path $Marker) { $done = $true; break }
  Start-Sleep -Seconds 3
}
try { [void][TailnetJoin.Power]::SetThreadExecutionState($ES_CONTINUOUS) } catch {}
Write-Host ''
if ($done) {
  $msg = (Get-Content -Path $Marker -Raw -ErrorAction SilentlyContinue)
  Write-Host '=============================================' -ForegroundColor Green
  Write-Host ' ALL SET' -ForegroundColor Green
  if ($msg) { Write-Host (' ' + $msg.Trim()) -ForegroundColor Green }
  Write-Host ' You can close this window.' -ForegroundColor Green
  Write-Host '=============================================' -ForegroundColor Green
} else {
  Write-Host ("Claude has not finished within {0} minutes. You can close this window - tell Claude." -f $WaitMinutes) -ForegroundColor Yellow
}
Finish
