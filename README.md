# tailnet-join

Puts a Windows PC on York's tailnet so it can be reached and finished remotely. The person at the
PC pastes one line; everything else happens over SSH from the Mac.

- `join.ps1` runs once, in an **administrator** PowerShell on the PC. It installs Tailscale in
  unattended mode and joins with a one-time key. It sets up OpenSSH Server, key-only, for York's
  laptop and Mac mini, with port 22 open **to the tailnet only**. It turns on Remote Desktop where the
  Windows edition allows it, also tailnet only. It proves a key login works, then reports to the Mac
  mini, which checks it can reach port 22 back. After that it keeps the PC awake and shows progress
  until the remote setup is done.
- `configure.ps1` is run over SSH. It creates the PC's own SSH key and an ssh config for York's
  machines, installs RealVNC Viewer (for macOS Screen Sharing), and makes a **My Computers** folder
  on the desktop with a terminal, screen or Remote Desktop shortcut for each machine. Then it checks
  every connection from the PC itself.

Nothing secret or site-specific is in this repo. The join key, the tailnet name, the report
address and the list of machines are all passed in at run time.

## The one-liner

Start, type `powershell`, right-click **Windows PowerShell**, choose **Run as administrator**, then
paste the line Claude sends. It has this shape:

```powershell
[Net.ServicePointManager]::SecurityProtocol=3072; Set-ExecutionPolicy Bypass -Scope Process -Force; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/yorkhanna-collab/tailnet-join/<commit>/join.ps1))) -TsKey 'tskey-auth-...' -Name home-pc -Tailnet '<tailnet>' -Report '<ip>:<port>'
```

Leave the window open until it says **ALL SET**.

## Tests

`.github/workflows/windows.yml` runs both scripts end to end on Windows Server 2025 and 2022 under
Windows PowerShell 5.1: an admin account, a standard account, RealVNC install, key, config and
shortcuts, and a real SSH login from the "PC" using its generated key. Tailscale is skipped in CI.

## Undo (admin PowerShell on the PC)

```powershell
Remove-NetFirewallRule -Name tailnet-join-ssh
Stop-Service sshd; Set-Service sshd -StartupType Disabled
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' fDenyTSConnections 1
# and uninstall Tailscale / RealVNC Viewer from Settings > Apps
```
