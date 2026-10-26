# Plain-assert tests for the HD art download from GitHub releases
# (installer/update-check.ps1: hd-art.json "release", resumable download,
# checksum, re-download on a new checksum, opt-out). A local HTTP server in a
# job stands in for GitHub: it serves a folder, honours "Range: bytes=N-",
# logs every request, and breaks a download off once when <file>.cut exists.
#   pwsh -NoProfile -File tests/hd-art-github.Tests.ps1   (or Windows PowerShell 5.1)
# Exit code = number of failures.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $here "..\installer\update-check.ps1") -NoMain -InstallRoot $here

$script:fail = 0; $script:pass = 0
function Check([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Host "ok   $name" } else { $script:fail++; Write-Host "FAIL $name" -ForegroundColor Red }
}
function Set-File([string]$path, [string]$text) {
    $d = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText($path, $text)
}
function Read-F([string]$path) { return [IO.File]::ReadAllText($path) }

# ---- manifest -> URL ------------------------------------------------------
$good = "a" * 64
$rel = "https://github.com/$Repo/releases/download/hd-art-1/"
$i = Get-HdArtInfo ([pscustomobject]@{ release = "hd-art-1"; file = "UOSmallz-HDArt-2x.zip"; size = 5; sha256 = $good })
Check ($i -and $i.Url -eq "${rel}UOSmallz-HDArt-2x.zip") "manifest: release hd-art-1 -> this repo's release URL"
Check ($rel.StartsWith("https://github.com/wesleysnoe-dev/uosmallz-client/")) "manifest: the release URL is the public client repo over HTTPS"
$c = Get-HdCreaturesInfo ([pscustomobject]@{ release = "hd-art-1"; creatures = [pscustomobject]@{ files = @([pscustomobject]@{ file = "A-1.uoanim"; size = 1; sha256 = $good }) } })
Check ($c -and $c.Files[0].Url -eq "${rel}A-1.uoanim") "manifest: creatures come from the same release"
foreach ($bad in @("../evil", "hd-art-1/../../x", "v9", "HD-ART-1", "hd-art-", "hd-art-1 ", "")) {
    Check ($null -eq (Get-HdArtInfo ([pscustomobject]@{ release = $bad; file = "p.zip"; size = 5; sha256 = $good }))) "manifest: release '$bad' is refused"
}
$i = Get-HdArtInfo ([pscustomobject]@{ file = "p.zip"; size = 5; sha256 = $good })
Check ($i.Url -eq "${HdArtLegacyUrl}p.zip") "manifest: no release -> the old shard server (transition only)"

# ---- the local server ------------------------------------------------------
$tmpBase = [IO.Path]::GetTempPath()
$srv = Join-Path $tmpBase ("uosz-srv-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $srv | Out-Null
$log = Join-Path $srv "requests.log"
$port = Get-Random -Minimum 20000 -Maximum 40000
$job = Start-Job -ArgumentList $port, $srv, $log -ScriptBlock {
    param($port, $dir, $log)
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port)
    $l.Start()
    while ($true) {
        $c = $l.AcceptTcpClient()
        try {
            $st = $c.GetStream()
            $rd = New-Object IO.StreamReader($st, [Text.Encoding]::ASCII)
            $first = $rd.ReadLine(); $range = $null
            while (($h = $rd.ReadLine()) -ne $null -and $h -ne "") { if ($h -match '^Range:\s*bytes=(\d+)-') { $range = [long]$Matches[1] } }
            $name = ($first -split ' ')[1].TrimStart('/')
            Add-Content -LiteralPath $log -Value ("GET {0} {1}" -f $name, $(if ($null -ne $range) { "range=$range" } else { "full" }))
            $f = Join-Path $dir $name
            if (-not (Test-Path -LiteralPath $f)) {
                $b = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"); $st.Write($b, 0, $b.Length); continue
            }
            $all = [IO.File]::ReadAllBytes($f)
            $from = 0L; $status = "200 OK"; $extra = ""
            if ($null -ne $range) {
                if ($range -ge $all.Length) {
                    $b = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 416 Range Not Satisfiable`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"); $st.Write($b, 0, $b.Length); continue
                }
                $from = $range; $status = "206 Partial Content"; $extra = "Content-Range: bytes $from-$($all.Length - 1)/$($all.Length)`r`n"
            }
            $len = $all.Length - $from
            $send = $len
            $cut = "$f.cut"
            if (Test-Path -LiteralPath $cut) { Remove-Item -LiteralPath $cut; $send = [long][math]::Floor($len / 2) }
            $b = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Length: $len`r`n$extra" + "Connection: close`r`n`r`n")
            $st.Write($b, 0, $b.Length); $st.Write($all, [int]$from, [int]$send); $st.Flush()
        } catch { } finally { $c.Close() }
    }
}
Start-Sleep -Milliseconds 1500
$base = "http://127.0.0.1:$port/"
function Get-Log { if (Test-Path -LiteralPath $log) { return @(Get-Content -LiteralPath $log) } else { return @() } }
function Clear-Log { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }

# a pack zip with art\ in it, put on the server
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-ServedPack([string]$name, [string]$text) {
    $d = Join-Path $tmpBase ("uosz-pack-" + [Guid]::NewGuid().ToString("N"))
    Set-File (Join-Path $d "art\0001.png") $text
    $z = Join-Path $srv $name
    Remove-Item -LiteralPath $z -Force -ErrorAction SilentlyContinue
    [IO.Compression.ZipFile]::CreateFromDirectory($d, $z)
    Remove-Item -LiteralPath $d -Recurse -Force
    return @{ File = $name; Url = $base + $name; Size = (Get-Item -LiteralPath $z).Length; Sha256 = (Get-Sha256 $z) }
}

# the UI and the "is the game running" check stand in
$script:answer = "Yes"; $script:asked = 0
function Show-Message([string]$text, [string]$buttons = "OK", [string]$icon = "Information") { if ($buttons -eq "YesNoCancel") { $script:asked++; return $script:answer }; return "OK" }
function Show-Busy([string]$text) { return $null }
function Get-ClientProcess([string]$clientDir) { return @() }

$root = Join-Path $tmpBase ("uosz-hd-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $root "Client") -Force | Out-Null
$p = Get-Paths $root

# ---- HD art pack ----------------------------------------------------------
# 1. first download
$i1 = New-ServedPack "UOSmallz-HDArt-2x.zip" "pack one"
Clear-Log
Invoke-HdArtPack $root $i1
Check ((Read-F (Join-Path $p.HdArt "art\0001.png")) -eq "pack one") "pack: first download installed into HDArt"
Check ((Read-HdArtStamp $p.HdArtStamp) -eq $i1.Sha256) "pack: stamp names the pack's SHA-256"
Check (@(Get-Log).Count -eq 1 -and (@(Get-Log))[0] -eq "GET UOSmallz-HDArt-2x.zip full") "pack: one request"
Check (-not (Test-Path -LiteralPath $p.HdArtDl)) "pack: the download folder is cleaned up"

# 2. up to date: no prompt, no request
Clear-Log; $script:asked = 0
Invoke-HdArtPack $root $i1
Check ($script:asked -eq 0 -and @(Get-Log).Count -eq 0) "pack: up to date -> no prompt and no download"

# 3. a new checksum in the manifest -> asked again, downloaded again
$i2 = New-ServedPack "UOSmallz-HDArt-2x.zip" "pack two, new"
Clear-Log; $script:asked = 0
Invoke-HdArtPack $root $i2
Check ($script:asked -eq 1 -and @(Get-Log).Count -eq 1) "pack: changed checksum -> offered and downloaded again"
Check ((Read-F (Join-Path $p.HdArt "art\0001.png")) -eq "pack two, new" -and (Read-HdArtStamp $p.HdArtStamp) -eq $i2.Sha256) "pack: the new pack is in, stamp updated"

# 4. a corrupt download is refused; what was there stays
$i3 = $i2.Clone(); $i3.Sha256 = "b" * 64
Clear-Log
Invoke-HdArtPack $root $i3
Check ((Read-F (Join-Path $p.HdArt "art\0001.png")) -eq "pack two, new" -and (Read-HdArtStamp $p.HdArtStamp) -eq $i2.Sha256) "pack: corrupt download refused, installed pack and stamp kept"
Check (-not (Get-ChildItem -LiteralPath $p.HdArtDl -File -ErrorAction SilentlyContinue)) "pack: the corrupt file is deleted"

# 5. a broken-off download resumes with Range next time
$i4 = New-ServedPack "UOSmallz-HDArt-2x.zip" ("pack four " + ("x" * 5000))
Set-File (Join-Path $srv "UOSmallz-HDArt-2x.zip.cut") "1"
Clear-Log
Invoke-HdArtPack $root $i4
$part = Get-HdPartPath (Join-Path $p.HdArtDl $i4.File) $i4.Sha256
$partLen = 0; if (Test-Path -LiteralPath $part) { $partLen = (Get-Item -LiteralPath $part).Length }
Check ($partLen -gt 0 -and $partLen -lt $i4.Size -and (Read-HdArtStamp $p.HdArtStamp) -eq $i2.Sha256) "pack: broken-off download keeps its part, nothing installed"
Clear-Log
Invoke-HdArtPack $root $i4
Check ((Get-Log) -contains "GET UOSmallz-HDArt-2x.zip range=$partLen") "pack: the next try asks only for the rest (Range)"
Check ((Read-HdArtStamp $p.HdArtStamp) -eq $i4.Sha256 -and (Read-F (Join-Path $p.HdArt "art\0001.png")).StartsWith("pack four")) "pack: resumed download checks out and is installed"

# 6. opt-out: Cancel = don't ask again for this pack
$i5 = New-ServedPack "UOSmallz-HDArt-2x.zip" "pack five"
Clear-Log; $script:asked = 0; $script:answer = "Cancel"
Invoke-HdArtPack $root $i5
Check ($script:asked -eq 1 -and @(Get-Log).Count -eq 0 -and (Read-F $p.HdArtSkip).Trim() -eq $i5.Sha256) "opt-out: Cancel downloads nothing and remembers the pack"
$script:asked = 0; $script:answer = "Yes"
Invoke-HdArtPack $root $i5
Check ($script:asked -eq 0 -and @(Get-Log).Count -eq 0 -and (Read-HdArtStamp $p.HdArtStamp) -eq $i4.Sha256) "opt-out: not asked again for that pack"
$script:answer = "No"; $script:asked = 0
Remove-Item -LiteralPath $p.HdArtSkip
Invoke-HdArtPack $root $i5
Check ($script:asked -eq 1 -and @(Get-Log).Count -eq 0) "opt-out: No downloads nothing (asked again next time)"
$script:answer = "Yes"

# ---- HD creatures ---------------------------------------------------------
function New-ServedAnim([string]$name, [string]$text) {
    $f = Join-Path $srv $name
    [IO.File]::WriteAllText($f, $text)
    return [pscustomobject]@{ file = $name; size = (Get-Item -LiteralPath $f).Length; sha256 = (Get-Sha256 $f) }
}
function Get-LocalSet($files) {
    $s = Get-HdCreaturesInfo ([pscustomobject]@{ release = "hd-art-1"; creatures = [pscustomobject]@{ files = $files } })
    foreach ($f in $s.Files) { $f.Url = $base + $f.File }
    return $s
}
$a1 = New-ServedAnim "UOSmallz-HDAnim-1.uoanim" ("one " * 2000)
$a2 = New-ServedAnim "UOSmallz-HDAnim-2.uoanim" ("two " * 2000)
$s1 = Get-LocalSet @($a1, $a2)
Clear-Log
Install-HdCreatures $root $s1
Check ((Read-F (Join-Path $p.HdAnim "UOSmallz-HDAnim-2.uoanim")).StartsWith("two") -and @(Get-Log).Count -eq 2 -and (Read-HdArtStamp $p.HdAnimStamp) -eq $s1.Id) "creatures: first download, both parts in, stamp written"
Clear-Log
Install-HdCreatures $root $s1
Check (@(Get-Log).Count -eq 0) "creatures: up to date -> nothing downloaded"
$a2b = New-ServedAnim "UOSmallz-HDAnim-2.uoanim" ("TWO " * 2000)
$s2 = Get-LocalSet @($a1, $a2b)
Check ($s2.Id -ne $s1.Id) "creatures: a changed checksum makes a new set id (offered again)"
Set-File (Join-Path $srv "UOSmallz-HDAnim-2.uoanim.cut") "1"
Clear-Log
$threw = $false; try { Install-HdCreatures $root $s2 } catch { $threw = $true }
Check ($threw -and (Read-HdArtStamp $p.HdAnimStamp) -eq $s1.Id) "creatures: a broken-off part fails, stamp unchanged"
Install-HdCreatures $root $s2
Check ((Get-Log | Where-Object { $_ -like "GET UOSmallz-HDAnim-1*" }).Count -eq 0) "creatures: only the changed part is fetched"
Check ((Get-Log | Where-Object { $_ -like "GET UOSmallz-HDAnim-2.uoanim range=*" }).Count -eq 1) "creatures: the broken-off part resumes (Range)"
Check ((Read-F (Join-Path $p.HdAnim "UOSmallz-HDAnim-2.uoanim")).StartsWith("TWO") -and (Read-HdArtStamp $p.HdAnimStamp) -eq $s2.Id) "creatures: the changed part is in, stamp updated"
Check (-not (Get-ChildItem -LiteralPath $p.HdAnim -Filter "*.part")) "creatures: no parts left behind"
$bad = [pscustomobject]@{ file = "UOSmallz-HDAnim-3.uoanim"; size = 9; sha256 = $good }
[IO.File]::WriteAllText((Join-Path $srv "UOSmallz-HDAnim-3.uoanim"), "tampered!")
$s3 = Get-LocalSet @($a1, $a2b, $bad)
$threw = $false; try { Install-HdCreatures $root $s3 } catch { $threw = $true }
Check ($threw -and -not (Test-Path -LiteralPath (Join-Path $p.HdAnim "UOSmallz-HDAnim-3.uoanim")) -and -not (Get-ChildItem -LiteralPath $p.HdAnim -Filter "*.part") -and (Read-HdArtStamp $p.HdAnimStamp) -eq $s2.Id) "creatures: a corrupt part is refused and deleted, the rest kept"

Stop-Job $job -ErrorAction SilentlyContinue; Remove-Job $job -Force
Remove-Item -LiteralPath $root, $srv -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$script:pass passed, $script:fail failed"
exit $script:fail
