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

# ---- startup recovery (Repair-ClientFolder) ----
$root = New-Root; New-FakeInstall $root
Check ((Repair-ClientFolder $root) -eq "ok") "recovery: healthy Client left alone"
Remove-Item $root -Recurse -Force

# killed between the renames: only Client.old (and a verified Client.new)
$root = New-Root; New-FakeInstall $root
$zip = New-FakeZip $root
# a real kill skips the rollback: build that state by hand
$p = Get-Paths $root
Expand-Archive $zip $p.New; Write-ReadyMarker $p.New "v2" (Get-Sha256 $zip)
Rename-Item $p.Client "Client.old"
Check ((Repair-ClientFolder $root) -eq "old") "recovery: Client.old preferred over a verified Client.new"
Check ((Read-F (Join-Path $p.Client "TazUO.exe")) -eq "old exe") "recovery: old client back in Client"
Check ((Read-F (Join-Path $p.Client "Data\Profiles\acct\UO Smallz\Char\profile.json")) -eq "my profile") "recovery: profile back"
Check ((Read-Stamp $p.Stamp).Tag -eq "v1") "recovery (old): stamp still v1, update offered again"
Remove-Item $root -Recurse -Force

# only a verified Client.new (no old copy: first install killed mid-swap)
$root = New-Root; $p = Get-Paths $root
$zip = New-FakeZip $root
Expand-Archive $zip $p.New; Write-ReadyMarker $p.New "v2" (Get-Sha256 $zip)
Check ((Repair-ClientFolder $root) -eq "new") "recovery: verified Client.new used when no Client.old"
Check ((Read-F $p.Exe) -eq "new exe" -and (Read-Stamp $p.Stamp).Tag -eq "v2") "recovery (new): Client and stamp from the marker"
Check (-not (Test-Path (Join-Path $p.Client ".uosmallz-ready.json"))) "recovery (new): marker removed"
Remove-Item $root -Recurse -Force

# unverified Client.new (no marker = unpack was interrupted): not used
$root = New-Root; $p = Get-Paths $root
$zip = New-FakeZip $root
Expand-Archive $zip $p.New
Check ((Repair-ClientFolder $root) -eq "none" -and -not (Test-Path $p.Client)) "recovery: unverified Client.new never used"
Remove-Item $root -Recurse -Force

# Client without TazUO.exe is moved aside, not deleted
$root = New-Root; New-FakeInstall $root; $p = Get-Paths $root
Rename-Item $p.Client "Client.old"
Set-File (Join-Path $p.Client "Data\keep.txt") "half"
Check ((Repair-ClientFolder $root) -eq "old") "recovery: broken Client replaced by Client.old"
Check (@(Get-ChildItem $root -Directory -Filter "Client.broken-*").Count -eq 1) "recovery: broken Client kept as Client.broken-*"
Remove-Item $root -Recurse -Force

# interrupted unpack leaves no Client.new
$root = New-Root; New-FakeInstall $root; $p = Get-Paths $root
$zip = New-FakeZip $root
Set-Item Function:\Copy-UserFiles -Value { param($a, $b) throw "simulated: disk full" }
$threw = $false; try { Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2" } catch { $threw = $true }
. (Join-Path $here "..\installer\update-check.ps1") -NoMain -InstallRoot $here
Check ($threw -and -not (Test-Path $p.New) -and (Read-F $p.Exe) -eq "old exe") "failed unpack/copy: Client.new removed, old client untouched"
Remove-Item $root -Recurse -Force

# ---- unconfirmed update: Client.old kept until a good launch ----
$root = New-Root; New-FakeInstall $root; $p = Get-Paths $root
$zip = New-FakeZip $root
Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2"
$pend = Read-Pending $p.Pending
Check ($pend -and $pend.Tag -eq "v2" -and $pend.PrevTag -eq "v1" -and -not $pend.Ok) "pending: written at swap with the previous stamp"
Check (-not (Confirm-PendingUpdate $root) -and (Test-Path (Join-Path $p.Old "TazUO.exe"))) "pending: Client.old kept while unconfirmed (same run / no good launch)"
# a quick-exit "client": not healthy
# a stand-in for TazUO.exe: Windows PowerShell on Windows, /bin/sh elsewhere
function Start-FakeClient([int]$runSeconds) {
    if ($env:OS -eq "Windows_NT") {
        return Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile", "-Command", "Start-Sleep $runSeconds" -WindowStyle Hidden -PassThru
    }
    return Start-Process -FilePath "sleep" -ArgumentList "$runSeconds" -PassThru
}
$quick = Start-FakeClient 0
Check (-not (Test-LaunchHealthy $quick 5)) "launch watch: a client that exits at once is not healthy"
# a long-running "client": healthy after the window
$slow = Start-FakeClient 8
Check (Test-LaunchHealthy $slow 2) "launch watch: a client still up after the window is healthy"
try { $slow.Kill() } catch { }
Check ((Read-Pending $p.Pending).Ok -eq $false) "pending: still unconfirmed before a healthy launch"
Set-PendingLaunchOk $root
Check ((Read-Pending $p.Pending).Ok -and (Test-Path $p.Old)) "pending: healthy launch recorded, Client.old still there this run"
Check ((Confirm-PendingUpdate $root) -and -not (Test-Path $p.Old) -and -not (Test-Path $p.Pending)) "pending: next run removes Client.old and the marker"
Remove-Item $root -Recurse -Force

# update check deferred while unconfirmed: Install never runs over a pending Client.old
$root = New-Root; New-FakeInstall $root; $p = Get-Paths $root
$zip = New-FakeZip $root
Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2"
Set-Item Function:\Get-LatestRelease -Value { throw "must not be called while pending" }
$called = $true
try { Invoke-Launcher $root; $called = $false } catch { }
. (Join-Path $here "..\installer\update-check.ps1") -NoMain -InstallRoot $here
Check (-not $called -and (Test-Path (Join-Path $p.Old "TazUO.exe"))) "pending: launcher defers the update check, Client.old safe"
# rollback after a failed launch: profile changes made with the new client survive
Set-File (Join-Path $p.Client "Data\Profiles\acct\UO Smallz\Char\profile.json") "played on v2"
Restore-PreviousClient $root
Check ((Read-F $p.Exe) -eq "old exe") "rollback: previous client back in Client"
Check ((Read-F (Join-Path $p.Client "Data\Profiles\acct\UO Smallz\Char\profile.json")) -eq "played on v2") "rollback: profile from the failed client carried back"
Check ((Read-Stamp $p.Stamp).Tag -eq "v1" -and -not (Test-Path $p.Pending)) "rollback: stamp v1, pending cleared"
Check (((Get-Content $p.Skip -Raw).Trim()) -like "v2 *") "rollback: failed version remembered as skipped"
Check (@(Get-ChildItem $root -Directory -Filter "Client.failed-*").Count -eq 1) "rollback: failed client kept aside"
Remove-Item $root -Recurse -Force

# recovery with a pending marker: restoring Client.old resets the stamp
$root = New-Root; New-FakeInstall $root; $p = Get-Paths $root
$zip = New-FakeZip $root
Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2"
Remove-Item $p.Client -Recurse -Force
Check ((Repair-ClientFolder $root) -eq "old" -and (Read-Stamp $p.Stamp).Tag -eq "v1" -and -not (Test-Path $p.Pending)) "recovery after an update: Client.old back, stamp v1, pending cleared"
Remove-Item $root -Recurse -Force

# pending without Client.old (removed by hand): marker dropped, updates resume
$root = New-Root; New-FakeInstall $root; $p = Get-Paths $root
$zip = New-FakeZip $root
Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2"
Remove-Item $p.Old -Recurse -Force
Check ((Confirm-PendingUpdate $root) -and -not (Test-Path $p.Pending)) "pending: no Client.old left, marker dropped"
Remove-Item $root -Recurse -Force

# ---- installer path: a zip that wrongly ships settings.json / Data\ ----
function New-BadZip([string]$dir) {
    $src = Join-Path $dir ("badsrc-" + [Guid]::NewGuid().ToString("N"))
    Set-File (Join-Path $src "TazUO.exe") "new exe"
    Set-File (Join-Path $src "settings.json") '{"ip":"zip-default"}'
    Set-File (Join-Path $src "Data\Profiles\acct\UO Smallz\Char\profile.json") "zip profile"
    Set-File (Join-Path $src "Data\zip-only.txt") "zip data"
    $zip = Join-Path $dir "bad.zip"
    Compress-Archive -Path (Join-Path $src "*") -DestinationPath $zip
    return $zip
}
$root = New-Root; New-FakeInstall $root; $p = Get-Paths $root
$zip = New-BadZip $root
Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2"
Check ((Read-F (Join-Path $p.Client "settings.json")) -eq '{"ip":"192.168.1.222","port":2593}') "installer swap: zip's settings.json never overwrites the player's"
Check ((Read-F (Join-Path $p.Client "Data\Profiles\acct\UO Smallz\Char\profile.json")) -eq "my profile") "installer swap: zip's Data\ never overwrites the player's"
Check (-not (Test-Path (Join-Path $p.Client "Data\zip-only.txt"))) "installer swap: nothing from the zip's Data\ at all"
Remove-Item $root -Recurse -Force
# fresh install (no Client yet): swap creates Client, no Client.old, no pending; zip's settings.json dropped
$root = New-Root; $p = Get-Paths $root
$zip = New-BadZip $root
Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2"
Check ((Read-F $p.Exe) -eq "new exe" -and -not (Test-Path $p.Old) -and -not (Test-Path $p.Pending)) "fresh install: Client created, no Client.old or pending"
Check (-not (Test-Path (Join-Path $p.Client "settings.json"))) "fresh install: zip's settings.json dropped (Merge-ClientSettings writes it)"
Check ((Read-Stamp $p.Stamp).Tag -eq "v2") "fresh install: stamp written by the swap"
Remove-Item $root -Recurse -Force
# re-install over a half-swapped client: repair first, then swap keeps the profile
$root = New-Root; New-FakeInstall $root; $p = Get-Paths $root
Rename-Item $p.Client "Client.old"
$zip = New-FakeZip $root
$r = Repair-ClientFolder $root
Install-ClientUpdate $root $zip (Get-Sha256 $zip) "v2"
Check ($r -eq "old" -and (Read-F (Join-Path $p.Client "Data\Profiles\acct\UO Smallz\Char\profile.json")) -eq "my profile") "re-install after an interrupted update: profile kept"
Remove-Item $root -Recurse -Force

# ---- download with timeouts (local one-shot HTTP server in a job) ----
function Start-OneShotServer([int]$port, [string]$body, [int]$sleepAfterSec) {
    return Start-Job -ArgumentList $port, $body, $sleepAfterSec -ScriptBlock {
        param($port, $body, $sleepAfterSec)
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port)
        $l.Start()
        $c = $l.AcceptTcpClient()
        $st = $c.GetStream()
        $buf = New-Object byte[] 4096; [void]$st.Read($buf, 0, 4096)
        $bytes = [Text.Encoding]::ASCII.GetBytes($body)
        $len = $bytes.Length
        if ($sleepAfterSec -gt 0) { $len = $bytes.Length + 1000 }   # promise more than we send
        $hdr = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $len`r`nConnection: close`r`n`r`n")
        $st.Write($hdr, 0, $hdr.Length); $st.Write($bytes, 0, $bytes.Length); $st.Flush()
        if ($sleepAfterSec -gt 0) { Start-Sleep -Seconds $sleepAfterSec }
        $c.Close(); $l.Stop()
    }
}
$root = New-Root
$port = Get-Random -Minimum 20000 -Maximum 40000
$job = Start-OneShotServer $port "hello" 0
Start-Sleep -Milliseconds 1500
$out = Join-Path $root "dl.bin"
try { Save-UrlWithTimeout "http://127.0.0.1:$port/x" $out 5 5 60; $ok = (Read-F $out) -eq "hello" } catch { $ok = $false; Write-Host $_ }
Check $ok "download: complete file saved"
Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force
$port++
$job = Start-OneShotServer $port "partial" 15
Start-Sleep -Milliseconds 1500
$out = Join-Path $root "stall.bin"
$sw = [Diagnostics.Stopwatch]::StartNew()
$threw = $false; try { Save-UrlWithTimeout "http://127.0.0.1:$port/x" $out 5 2 60 } catch { $threw = $true }
$sw.Stop()
Check ($threw -and $sw.Elapsed.TotalSeconds -lt 10) "download: stall times out ($([int]$sw.Elapsed.TotalSeconds) s)"
Check (-not (Test-Path -LiteralPath $out)) "download: partial file removed after a stall"
Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force
Remove-Item $root -Recurse -Force

# ---- HD art ----
$good = "a" * 64
$info = Get-HdArtInfo ([pscustomobject]@{ file = "UOSmallz-HDArt-2x.zip"; size = 551811205; sha256 = $good.ToUpper() })
Check ($info -and $info.Url -eq "${HdArtBaseUrl}UOSmallz-HDArt-2x.zip" -and $info.Sha256 -eq $good -and $info.Size -eq 551811205) "hd art: manifest read, URL from the allowlisted server only"
Check ($null -eq (Get-HdArtInfo ([pscustomobject]@{ file = "../evil.zip"; size = 1; sha256 = $good }))) "hd art: a path in the file name is refused"
Check ($null -eq (Get-HdArtInfo ([pscustomobject]@{ file = "pack.exe"; size = 1; sha256 = $good }))) "hd art: only a .zip is accepted"
Check ($null -eq (Get-HdArtInfo ([pscustomobject]@{ file = "pack.zip"; size = 1; sha256 = "abc" }))) "hd art: a malformed SHA-256 is refused"
Check ($null -eq (Get-HdArtInfo ([pscustomobject]@{ file = "pack.zip"; size = 0; sha256 = $good }))) "hd art: size 0 is refused"
Check ($null -eq (Get-HdArtInfo $null)) "hd art: no manifest, nothing offered"

$root = New-Root
Set-File (Join-Path $root "Client\ClassicUO.Renderer.dll") "...ClassicUO.Renderer.TextureAtlas..."
Check (-not (Test-ClientDrawsHdArt (Join-Path $root "Client"))) "hd art: a client without the patch is not offered the pack"
Set-File (Join-Path $root "Client\ClassicUO.Renderer.dll") "...ClassicUO.Renderer.ScaledTexture2D..."
Check (Test-ClientDrawsHdArt (Join-Path $root "Client")) "hd art: a client with the patch is"

function New-FakePack([string]$dir, [string]$marker) {
    $src = Join-Path $dir ("packsrc-" + [Guid]::NewGuid().ToString("N"))
    Set-File (Join-Path $src "art\0x0001.png") $marker
    Set-File (Join-Path $src "gumps\0x0001.png") $marker
    $zip = Join-Path $dir ("pack-" + [Guid]::NewGuid().ToString("N") + ".zip")
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
    return $zip
}
$z1 = New-FakePack $root "pack one"
Install-HdArt $root $z1 (Get-Sha256 $z1)
Check ((Read-F (Join-Path $root "HDArt\art\0x0001.png")) -eq "pack one") "hd art: installed into HDArt beside Client"
Check ((Read-HdArtStamp (Join-Path $root "hdart-version.json")) -eq (Get-Sha256 $z1)) "hd art: stamp names the installed pack"
$z2 = New-FakePack $root "pack two"
$threw = $false; try { Install-HdArt $root $z2 $good } catch { $threw = $true }
Check ($threw -and (Read-F (Join-Path $root "HDArt\art\0x0001.png")) -eq "pack one") "hd art: a zip that doesn't match the SHA-256 is refused, the old pack stays"
Check (-not (Test-Path -LiteralPath (Join-Path $root "HDArt.new"))) "hd art: nothing half-unpacked left behind"
Install-HdArt $root $z2 (Get-Sha256 $z2)
Check ((Read-F (Join-Path $root "HDArt\art\0x0001.png")) -eq "pack two" -and -not (Test-Path -LiteralPath (Join-Path $root "HDArt.old"))) "hd art: a new pack replaces the old one"
Remove-Item $root -Recurse -Force

Write-Host ""
Write-Host "$script:pass passed, $script:fail failed"
exit $script:fail
