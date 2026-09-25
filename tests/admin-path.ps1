# CI: join.ps1 as an administrator account (the usual home-PC case).
. "$PSScriptRoot\assert.ps1"

& "$PSScriptRoot\..\join.ps1" -SkipTailscale -NoWait -NoUpload -Name ci-test
$r = Get-Report
Assert ($r.target.is_admin -eq $true) "target $($r.target.account) is an administrator"
Assert ($r.self_test.ok -eq $true) "self-test key login worked as $($r.target.ssh_login): $($r.self_test.output)"
Assert ((Get-Service sshd).Status -eq 'Running') 'sshd is running'
Assert ([string](Get-Service sshd).StartType -eq 'Automatic') 'sshd starts with Windows'
Assert ((Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH').DefaultShell -like '*powershell.exe') 'SSH lands in PowerShell'

$ak = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
Assert-PlainAscii $ak
$lines = @(Get-Content $ak)
Assert (@($lines | Where-Object { $_ -like '*york@macbook->mini' }).Count -eq 1) 'laptop key present exactly once'
Assert (@($lines | Where-Object { $_ -like '*macmini-to-stations' }).Count -eq 1) 'mini key present exactly once'
Assert (-not ($lines | Where-Object { $_ -like '*tailnet-join-selftest*' })) 'self-test key was removed again'
Assert-KeyFileAcl $ak 'S-1-5-32-544' @('S-1-5-18', 'S-1-5-32-544')

$rule = Get-NetFirewallRule -Name 'tailnet-join-ssh'
Assert ([string]$rule.Enabled -eq 'True') 'tailnet SSH rule enabled'
$addr = @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)
Assert (($addr -join ',') -match '100\.64\.0\.0') "SSH rule scoped to the tailnet ($($addr -join ', '))"
$open22 = @(Get-NetFirewallPortFilter -Protocol TCP | Where-Object { @($_.LocalPort) -contains '22' } | Get-NetFirewallRule | Where-Object { $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and [string]$_.Enabled -eq 'True' })
Assert ($open22.Count -eq 1 -and $open22[0].Name -eq 'tailnet-join-ssh') "only the tailnet rule allows port 22 (found: $(($open22 | ForEach-Object { $_.Name }) -join ', '))"

# safe to re-run: same keys, still passes
& "$PSScriptRoot\..\join.ps1" -SkipTailscale -NoWait -NoUpload -Name ci-test
Assert (@(Get-Content $ak).Count -eq $lines.Count) 're-run leaves the key file unchanged'
Assert ((Get-Report).self_test.ok -eq $true) 'self-test passes on re-run'
exit 0
