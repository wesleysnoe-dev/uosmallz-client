# Plain-assert tests for installer/update-check.ps1 (no Pester needed).
#   pwsh -NoProfile -File tests/updater.Tests.ps1      (or Windows PowerShell 5.1)
# Exit code = number of failures.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "..\installer\update-check.ps1") -NoMain -InstallRoot $here

$script:fail = 0; $script:pass = 0
function Check([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Host "ok   $name" } else { $script:fail++; Write-Host "FAIL $name" -ForegroundColor Red }
}
function New-Root {
    $r = Join-Path ([IO.Path]::GetTempPath()) ("uosz-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $r | Out-Null
    return $r
}
function Set-File([string]$path, [string]$text) {
    $d = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText($path, $text)
}
# A fake installed client and a fake release zip.
function New-FakeInstall([string]$root) {
    $c = Join-Path $root "Client"
    Set-File (Join-Path $c "TazUO.exe") "old exe"
    Set-File (Join-Path $c "TazUO.dll") "old dll"
    Set-File (Join-Path $c "TazUO.deps.json") "old deps"
    Set-File (Join-Path $c "settings.json") '{"ip":"192.168.1.222","port":2593}'
    Set-File (Join-Path $c "Data\Profiles\acct\UO Smallz\Char\profile.json") "my profile"
    Set-File (Join-Path $c "Data\global_settings.json") "my global"
    Set-File (Join-Path $c "LegionScripts\mine.py") "my script"
    Set-File (Join-Path $c "LegionScripts\shipped.py") "old shipped"
    Set-File (Join-Path $c "old-only.dll") "stale"
    Write-Stamp (Join-Path $root "client-version.json") "v1" ("a" * 64)
}
function New-FakeZip([string]$dir, [bool]$withExe = $true) {
    $src = Join-Path $dir ("zipsrc-" + [Guid]::NewGuid().ToString("N"))
    if ($withExe) { Set-File (Join-Path $src "TazUO.exe") "new exe" }
    Set-File (Join-Path $src "TazUO.dll") "new dll"
    Set-File (Join-Path $src "TazUO.deps.json") "new deps"
    Set-File (Join-Path $src "LegionScripts\shipped.py") "new shipped"
    Set-File (Join-Path $src "notices\NOTICE.txt") "notice"
    $zip = Join-Path $dir ("client-" + [Guid]::NewGuid().ToString("N") + ".zip")
    Compress-Archive -Path (Join-Path $src "*") -DestinationPath $zip
    Remove-Item -LiteralPath $src -Recurse -Force
    return $zip
}
function Read-F([string]$p) { if (Test-Path -LiteralPath $p) { return [IO.File]::ReadAllText($p) } return $null }

# ---- version compare ----
$l1 = @{ Tag = "v1"; Sha256 = ("a" * 64) }
Check (Test-IsNewer $l1 "v2" ("b" * 64)) "v2 is newer than v1"
Check (-not (Test-IsNewer $l1 "v1" ("a" * 64))) "same tag, same sha: current"
Check (Test-IsNewer $l1 "v1" ("b" * 64)) "same tag, re-published zip: newer"
Check (-not (Test-IsNewer @{ Tag = "v3"; Sha256 = ("a" * 64) } "v2" ("b" * 64))) "older release never offered"
Check (Test-IsNewer @{ Tag = "v9"; Sha256 = "x" } "v10" "y") "v10 > v9 (numeric, not string)"
Check (Test-IsNewer @{ Tag = "v2.1"; Sha256 = "x" } "v2.2" "y") "v2.2 > v2.1"
Check (Test-IsNewer $null "v2" "y") "no stamp: offered"
Check (Test-IsNewer @{ Tag = "unknown"; Sha256 = "" } "v2" "y") "unknown stamp: offered"
Check (Test-IsNewer @{ Tag = "beta"; Sha256 = "x" } "gamma" "x") "non-numeric tags: any difference"
Check (-not (Test-IsNewer $l1 "" "y")) "no remote tag: not offered"

# ---- release parsing / SHA sources ----
$h = "0123456789abcdef" * 4
$rel = [pscustomobject]@{ tag_name = "v2"; name = "UO Smallz client v2"; body = "notes"; assets = @(
    [pscustomobject]@{ name = "UOSmallz-Client-win-x64.zip"; browser_download_url = "https://x/zip"; digest = "sha256:$($h.ToUpper())" },
    [pscustomobject]@{ name = "SHA256SUMS.txt"; browser_download_url = "https://x/sums" }) }
$i = Get-UpdateInfo $rel $null
Check ($i.Tag -eq "v2" -and $i.Url -eq "https://x/zip" -and $i.Sha256 -eq $h) "digest read (lower-cased)"
$sums = "$("f" * 64)  UOSmallz-Client-linux-x64.zip`n$h  UOSmallz-Client-win-x64.zip`n"
$relNoDigest = [pscustomobject]@{ tag_name = "v2"; assets = @([pscustomobject]@{ name = "UOSmallz-Client-win-x64.zip"; browser_download_url = "u" }) }
Check ((Get-UpdateInfo $relNoDigest $sums).Sha256 -eq $h) "SHA256SUMS.txt used when no digest"
Check ($null -eq (Get-UpdateInfo $relNoDigest $null).Sha256) "no digest, no sums: no sha (not offered)"
$bad = $false; try { Get-UpdateInfo $rel ("e" * 64 + "  UOSmallz-Client-win-x64.zip") | Out-Null } catch { $bad = $true }
Check $bad "digest and sums disagree: refused"
Check ($null -eq (Get-UpdateInfo ([pscustomobject]@{ tag_name = "v2"; assets = @() }) $null)) "release without the asset: null"
Check ((Get-ShaFromSums "$h *UOSmallz-Client-win-x64.zip" "UOSmallz-Client-win-x64.zip") -eq $h) "sums binary-mode '*name' line"

# ---- SHA verify ----
$root = New-Root
$f = Join-Path $root "f.bin"; Set-File $f "hello"
$hello = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
Check (Test-Sha256 $f $hello) "sha256 of 'hello' matches"
Check (Test-Sha256 $f $hello.ToUpper()) "sha compare is case-insensitive"
Check (-not (Test-Sha256 $f ("0" * 64))) "wrong sha rejected"
Check (-not (Test-Sha256 $f "")) "empty expected sha rejected"

# ---- stamp ----
Write-Stamp (Join-Path $root "s.json") "v2" $h.ToUpper()
$s = Read-Stamp (Join-Path $root "s.json")
Check ($s.Tag -eq "v2" -and $s.Sha256 -eq $h) "stamp round-trip"
Set-File (Join-Path $root "broken.json") "{not json"
Check ($null -eq (Read-Stamp (Join-Path $root "broken.json"))) "broken stamp reads as none"
Remove-Item $root -Recurse -Force

# ---- swap: success ----
$root = New-Root; New-FakeInstall $root
$zip = New-FakeZip $root
$zsha = Get-Sha256 $zip
Install-ClientUpdate $root $zip $zsha "v2"
$c = Join-Path $root "Client"
Check ((Read-F (Join-Path $c "TazUO.exe")) -eq "new exe") "swap: new exe in Client"
Check ((Read-F (Join-Path $c "TazUO.deps.json")) -eq "new deps") "swap: release json wins over old"
Check ((Read-F (Join-Path $c "settings.json")) -eq '{"ip":"192.168.1.222","port":2593}') "swap: settings.json kept"
Check ((Read-F (Join-Path $c "Data\Profiles\acct\UO Smallz\Char\profile.json")) -eq "my profile") "swap: profile kept"
Check ((Read-F (Join-Path $c "Data\global_settings.json")) -eq "my global") "swap: Data\ kept"
Check (-not (Test-Path (Join-Path $c "Data\Data"))) "swap: no nested Data\Data"
Check ((Read-F (Join-Path $c "LegionScripts\mine.py")) -eq "my script") "swap: player's own file carried"
Check ((Read-F (Join-Path $c "LegionScripts\shipped.py")) -eq "new shipped") "swap: shipped file updated"
Check (-not (Test-Path (Join-Path $c "old-only.dll"))) "swap: stale program file not carried"
Check ((Read-F (Join-Path $root "Client.old\TazUO.exe")) -eq "old exe") "swap: Client.old kept"
Check (-not (Test-Path (Join-Path $root "Client.new"))) "swap: no Client.new left"
Check ((Read-Stamp (Join-Path $root "client-version.json")).Tag -eq "v2") "swap: stamp says v2"
# a second update replaces Client.old
$zip2 = New-FakeZip $root
Install-ClientUpdate $root $zip2 (Get-Sha256 $zip2) "v3"
Check ((Read-F (Join-Path $root "Client.old\TazUO.exe")) -eq "new exe") "second update: Client.old is the previous client"
Check ((Read-F (Join-Path $root "Client\Data\Profiles\acct\UO Smallz\Char\profile.json")) -eq "my profile") "second update: profile still kept"
Remove-Item $root -Recurse -Force

# ---- swap: bad sha -> nothing touched ----
$root = New-Root; New-FakeInstall $root
$zip = New-FakeZip $root
$threw = $false; try { Install-ClientUpdate $root $zip ("0" * 64) "v2" } catch { $threw = $true }
Check $threw "bad sha: throws"
Check ((Read-F (Join-Path $root "Client\TazUO.exe")) -eq "old exe") "bad sha: old client untouched"
Check (-not (Test-Path (Join-Path $root "Client.new"))) "bad sha: nothing unpacked"
Check ((Read-Stamp (Join-Path $root "client-version.json")).Tag -eq "v1") "bad sha: stamp unchanged"
Remove-Item $root -Recurse -Force

# ---- swap: zip without TazUO.exe ----
$root = New-Root; New-FakeInstall $root
$zip = New-FakeZip $root $false
$threw = $false; try { Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2" } catch { $threw = $true }
Check ($threw -and (Read-F (Join-Path $root "Client\TazUO.exe")) -eq "old exe" -and -not (Test-Path (Join-Path $root "Client.new"))) "zip without exe: refused, old kept"
Remove-Item $root -Recurse -Force

# ---- swap: failure after the old client moved -> rollback ----
$root = New-Root; New-FakeInstall $root
$zip = New-FakeZip $root
$script:renames = 0
function Rename-Item {
    param([string]$LiteralPath, [string]$NewName)
    $script:renames++
    if ($script:renames -eq 2) { throw "simulated: Client.new is locked" }
    Microsoft.PowerShell.Management\Rename-Item -LiteralPath $LiteralPath -NewName $NewName
}
$threw = $false; try { Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2" } catch { $threw = $true }
Remove-Item Function:\Rename-Item
Check $threw "rename failure: throws"
Check ((Read-F (Join-Path $root "Client\TazUO.exe")) -eq "old exe") "rename failure: old client restored"
Check ((Read-F (Join-Path $root "Client\Data\Profiles\acct\UO Smallz\Char\profile.json")) -eq "my profile") "rename failure: profile in place"
Check (-not (Test-Path (Join-Path $root "Client.old")) -and -not (Test-Path (Join-Path $root "Client.new"))) "rename failure: no leftovers"
Check ((Read-Stamp (Join-Path $root "client-version.json")).Tag -eq "v1") "rename failure: stamp unchanged"
Remove-Item $root -Recurse -Force

# ---- swap: failure after the swap (stamp write) -> rollback ----
$root = New-Root; New-FakeInstall $root
$zip = New-FakeZip $root
$sha = Get-Sha256 $zip
Set-Item Function:\Write-Stamp -Value { param($p, $t, $s) throw "simulated: disk full" }
$threw = $false; try { Install-ClientUpdate $root $zip $sha "v2" } catch { $threw = $true }
. (Join-Path $here "..\installer\update-check.ps1") -NoMain -InstallRoot $here   # restore Write-Stamp
Check ($threw -and (Read-F (Join-Path $root "Client\TazUO.exe")) -eq "old exe") "stamp failure: old client restored"
Check (-not (Test-Path (Join-Path $root "Client.old")) -and -not (Test-Path (Join-Path $root "Client.new"))) "stamp failure: no leftovers"
Remove-Item $root -Recurse -Force

# ---- swap: locked old client (rename of Client fails) ----
$root = New-Root; New-FakeInstall $root
$zip = New-FakeZip $root
$script:renames = 0
function Rename-Item { param([string]$LiteralPath, [string]$NewName) throw "simulated: TazUO.exe in use" }
$threw = $false; try { Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2" } catch { $threw = $true }
Remove-Item Function:\Rename-Item
Check ($threw -and (Read-F (Join-Path $root "Client\TazUO.exe")) -eq "old exe" -and -not (Test-Path (Join-Path $root "Client.new"))) "client locked: refused, old kept, Client.new removed"
Remove-Item $root -Recurse -Force

# ---- settings merge ----
$root = New-Root
$data = Join-Path $root "UOData"; New-Item -ItemType Directory $data | Out-Null
$defaults = [ordered]@{ username = ""; ip = "uosmallz.duckdns.org"; port = 2593; ultimaonlinedirectory = $data; clientversion = "7.0.23.1"; fps = 60 }
$sp = Join-Path $root "settings.json"
$r = @(Merge-ClientSettings $sp $defaults)
$j = Get-Content $sp -Raw | ConvertFrom-Json
Check ($r[0] -eq "(new file)" -and $j.ip -eq "uosmallz.duckdns.org" -and $j.fps -eq 60) "settings: fresh file gets defaults"
Set-File $sp ('{"ip":"192.168.1.222","port":2593,"fps":169,"ultimaonlinedirectory":"' + $data.Replace('\', '/') + '","window_position":{"X":644,"Y":209}}')
$r = @(Merge-ClientSettings $sp $defaults)
$j = Get-Content $sp -Raw | ConvertFrom-Json
Check ($j.ip -eq "192.168.1.222" -and $j.fps -eq 169 -and $j.window_position.X -eq 644) "settings: custom ip/fps/window kept"
Check ($r -contains "clientversion" -and $j.clientversion -eq "7.0.23.1" -and -not ($r -contains "ip")) "settings: only the missing clientversion added"
$before = Read-F $sp
$r = @(Merge-ClientSettings $sp $defaults)
Check ($r.Count -eq 0 -and (Read-F $sp) -eq $before) "settings: nothing missing, file untouched"
Set-File $sp '{"ip":"10.0.0.5","port":2593,"clientversion":"7.0.23.1","ultimaonlinedirectory":"Z:/gone/UO"}'
$r = @(Merge-ClientSettings $sp $defaults)
$j = Get-Content $sp -Raw | ConvertFrom-Json
Check ($r -contains "ultimaonlinedirectory" -and $j.ultimaonlinedirectory -eq $data -and $j.ip -eq "10.0.0.5") "settings: missing UO folder replaced, ip kept"
Set-File $sp '{"ip": broken'
$r = @(Merge-ClientSettings $sp $defaults)
Check ($r[0] -eq "(new file)" -and @(Get-ChildItem $root -Filter "settings.json.unreadable-*").Count -eq 1) "settings: unreadable file backed up, defaults written"
Remove-Item $root -Recurse -Force

Write-Host ""
Write-Host "$script:pass passed, $script:fail failed"
exit $script:fail
