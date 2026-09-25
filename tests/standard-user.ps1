# CI: join.ps1 for a standard (non-admin) account, the case where keys must go in the user's own
# authorized_keys with that user as owner.
. "$PSScriptRoot\assert.ps1"

$name = 'tjuser'
if (-not (Get-LocalUser -Name $name -ErrorAction SilentlyContinue)) {
  $pw = (-join ((48..57 + 65..90 + 97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })) + 'Aa1!'
  New-LocalUser -Name $name -Password (ConvertTo-SecureString $pw -AsPlainText -Force) -PasswordNeverExpires | Out-Null
  Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $name -ErrorAction SilentlyContinue
}
$sid = (Get-LocalUser -Name $name).SID.Value
# give the account a profile folder without logging it on (a PC's real user always has one)
Add-Type -Namespace TJ -Name Profile -MemberDefinition '[DllImport("userenv.dll", CharSet = CharSet.Unicode)] public static extern int CreateProfile(string pszUserSid, string pszUserName, System.Text.StringBuilder pszProfilePath, uint cchProfilePath);'
$sb = New-Object Text.StringBuilder 260
$hr = [TJ.Profile]::CreateProfile($sid, $name, $sb, 260)
Write-Host ("CreateProfile hr=0x{0:X8} path={1}" -f $hr, $sb.ToString())

& "$PSScriptRoot\..\join.ps1" -SkipTailscale -NoWait -NoUpload -Name ci-test -ForUser $name -SkipRdp
$r = Get-Report
Assert ($r.target.sam -eq $name) "target is $name"
Assert ($r.target.is_admin -eq $false) "$name is a standard account"
Assert ([bool]$r.target.profile) "profile resolved via ProfileList ($($r.target.profile))"
Assert ($r.self_test.ok -eq $true) "standard-account key login works: $($r.self_test.output)"
$uak = Join-Path $r.target.profile '.ssh\authorized_keys'
Assert-PlainAscii $uak
Assert-KeyFileAcl $uak $sid @($sid, 'S-1-5-18', 'S-1-5-32-544')
Assert (-not (Get-Content $uak | Where-Object { $_ -like '*tailnet-join-selftest*' })) 'self-test key was removed again'
exit 0
