# Shared checks for CI. Throws on the first failed expectation.
function Assert([bool]$Cond, [string]$What) {
  if (-not $Cond) { throw "ASSERT FAILED: $What" }
  Write-Host "ok  - $What"
}
function Get-Report {
  $p = Join-Path $env:ProgramData 'tailnet-join\report.json'
  Assert (Test-Path $p) 'report.json exists'
  return ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
}
function Assert-PlainAscii([string]$Path) {
  $b = [IO.File]::ReadAllBytes($Path)
  Assert ($b.Length -gt 0) "$Path is not empty"
  Assert (-not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) "$Path has no UTF-8 BOM"
  Assert (-not ($b.Length -ge 2 -and (($b[0] -eq 0xFF -and $b[1] -eq 0xFE) -or ($b[0] -eq 0xFE -and $b[1] -eq 0xFF)))) "$Path is not UTF-16"
  Assert (-not ($b | Where-Object { $_ -gt 127 -or $_ -eq 0 })) "$Path is plain ASCII"
}
function Assert-KeyFileAcl([string]$Path, [string]$OwnerSid, [string[]]$AllowedSids) {
  $acl = Get-Acl -Path $Path
  $owner = (New-Object Security.Principal.NTAccount($acl.Owner)).Translate([Security.Principal.SecurityIdentifier]).Value
  Assert ($owner -eq $OwnerSid) "$Path owner is $OwnerSid (got $owner)"
  Assert ($acl.AreAccessRulesProtected) "$Path does not inherit permissions"
  foreach ($rule in $acl.Access) {
    $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    Assert ($AllowedSids -contains $sid) "$Path grants only allowed accounts (found $sid)"
  }
}
