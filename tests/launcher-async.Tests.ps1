# Tests for the background update (launcher 10): hash cache, changed-file scan,
# parallel copy, background runspace with progress/cancel/failure/rollback, zip
# and tree helpers. Plain asserts, no Pester; runs on Linux pwsh and on Windows
# PowerShell 5.1. WinForms is not touched (Show-Busy / Update-Busy are stood in
# for), the logic behind it is.
#   pwsh -NoProfile -File tests/launcher-async.Tests.ps1
#   UOSMALLZ_TEST_FILES=2000 pwsh ...      (smaller synthetic client; default 15314)
# Exit code = number of failures.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$launcher = Join-Path (Join-Path $here "..") "installer"
$launcher = Join-Path $launcher "update-check.ps1"
. $launcher -NoMain -InstallRoot $here

$script:fail = 0; $script:pass = 0
function Check([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Host "ok   $name" } else { $script:fail++; Write-Host "FAIL $name" -ForegroundColor Red }
}
function Info([string]$text) { Write-Host "     $text" -ForegroundColor DarkGray }
$sepc = [string][IO.Path]::DirectorySeparatorChar
function P([string]$base, [string]$rel) { return Join-Path $base ($rel.Replace('/', $sepc)) }
function New-Root {
    $r = Join-Path ([IO.Path]::GetTempPath()) ("uosz-async-" + [Guid]::NewGuid().ToString("N"))
    [void][IO.Directory]::CreateDirectory($r)
    return $r
}
function Read-F([string]$p) { if (Test-Path -LiteralPath $p) { return [IO.File]::ReadAllText($p) } return $null }
function Put([string]$path, [string]$text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $text)
}
function Get-Seconds([scriptblock]$sb) { $sw = [Diagnostics.Stopwatch]::StartNew(); & $sb | Out-Null; $sw.Stop(); return $sw.Elapsed.TotalSeconds }

$N = 15314
if ($env:UOSMALLZ_TEST_FILES -match '^\d+$') { $N = [int]$env:UOSMALLZ_TEST_FILES }
$BigTests = ($N -ge 2000)

# =========================================================================
# 0. the file parses, and uses nothing Windows PowerShell 5.1 does not have
# =========================================================================
$tokens = $null; $perr = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$tokens, [ref]$perr)
Check ($perr.Count -eq 0) "parse: update-check.ps1 has no parse errors"
$bad = @($tokens | Where-Object { $_.Kind.ToString() -in @("AndAnd", "OrOr", "QuestionQuestion", "QuestionQuestionEquals", "QuestionDot", "QuestionLBracket", "QuestionMark") })
Check ($bad.Count -eq 0) "5.1: no &&, ||, ??, ?. or ternary tokens ($($bad.Count))"
$badAst = @($ast.FindAll({ param($n) $n.GetType().Name -in @("TernaryExpressionAst", "PipelineChainAst", "NullConditionalMemberAccessAst", "NullConditionalIndexExpressionAst") }, $true))
Check ($badAst.Count -eq 0) "5.1: no PowerShell 7-only syntax nodes"
$src = [IO.File]::ReadAllText($launcher)
Check (-not ($src -cmatch '[^\x00-\x7F]')) "5.1: the script is pure ASCII (5.1 reads a BOM-less file as ANSI)"
Check (-not ($src -match 'ForEach-Object\s+-Parallel|-AsHashtable|-AsByteStream|\[IO\.Path\]::GetRelativePath|Join-Path[^\r\n|)]*-AdditionalChildPath')) "5.1: none of the PowerShell 7 / .NET Core-only calls"
Check ($LauncherVersion -eq 10) "launcher version is 10"
Check (Test-LauncherScript $src) "self-update: the new launcher passes Test-LauncherScript"

# =========================================================================
# 1. hash cache file
# =========================================================================
$root = New-Root
$cf = Join-Path $root "c.tsv"
$c = @{}
Set-CacheEntry $c "a/b.png" 10 123456789 ("a" * 64)
Set-CacheEntry $c "TazUO.exe" 99 5 ("b" * 64)
Check ((Write-HashCache $cf $c) -and -not (Test-Path "$cf.tmp")) "cache: written, no temp file left"
$r = Read-HashCache $cf
Check ($r.Count -eq 2 -and $r["a/b.png"][0] -eq 10 -and $r["a/b.png"][1] -eq 123456789 -and $r["a/b.png"][2] -eq ("a" * 64)) "cache: read back size, mtime, sha"
[IO.File]::WriteAllText($cf, "SOMETHING ELSE 9`n10`t1`t$("a" * 64)`tx`n")
Check ((Read-HashCache $cf).Count -eq 0) "cache: a file with another header is ignored"
[IO.File]::WriteAllText($cf, "$HashCacheMagic`ngarbage`n1`t2`tnothex`tx`n7`t8`t$("c" * 64)`tgood.dll`n")
$r = Read-HashCache $cf
Check ($r.Count -eq 1 -and $r.ContainsKey("good.dll")) "cache: bad rows skipped, good rows kept"
Check ((Read-HashCache (Join-Path $root "missing.tsv")).Count -eq 0) "cache: no file = empty cache"
[IO.File]::WriteAllText($cf, "$HashCacheMagic`nx`ty`t$("c" * 64)`tp`n")
Check ((Read-HashCache $cf).Count -eq 0) "cache: a row with a non-number empties the cache instead of throwing"
Set-CacheEntry $c "tab`tname" 1 1 ("d" * 64)
[void](Write-HashCache $cf $c)
Check ((Read-HashCache $cf).Count -eq 2) "cache: a path with a tab is not written (it would break the row)"
$env:UOSMALLZ_REHASH = "1"
Check ((Read-HashCache $cf).Count -eq 0) "cache: UOSMALLZ_REHASH=1 ignores it"
$env:UOSMALLZ_REHASH = $null
# Get-CachedSha256: trusts size+mtime, rehashes when either moves
$f1 = Join-Path $root "f1.bin"; [IO.File]::WriteAllBytes($f1, [byte[]](1..200))
(Get-Item $f1).LastWriteTimeUtc = (Get-Date).AddMinutes(-10).ToUniversalTime()
$cc = @{}
$h1 = Get-CachedSha256 $cc "f1" $f1
Check ($h1 -eq (Get-FileHash $f1 -Algorithm SHA256).Hash.ToLower() -and $cc.ContainsKey("f1")) "cache: first read hashes and stores"
$t = (Get-Item $f1).LastWriteTimeUtc
[IO.File]::WriteAllBytes($f1, [byte[]](2..201)); (Get-Item $f1).LastWriteTimeUtc = $t
Check ((Get-CachedSha256 $cc "f1" $f1) -eq $h1) "cache: same size and mtime -> the cached hash (not read again)"
(Get-Item $f1).LastWriteTimeUtc = $t.AddMinutes(1)
Check ((Get-CachedSha256 $cc "f1" $f1) -eq (Get-FileHash $f1 -Algorithm SHA256).Hash.ToLower()) "cache: new mtime -> rehashed"
[IO.File]::WriteAllBytes($f1, [byte[]](1..50)); (Get-Item $f1).LastWriteTimeUtc = $t.AddMinutes(1)
Check ((Get-CachedSha256 $cc "f1" $f1) -eq (Get-FileHash $f1 -Algorithm SHA256).Hash.ToLower()) "cache: new size -> rehashed"
$f2 = Join-Path $root "fresh.bin"; [IO.File]::WriteAllBytes($f2, [byte[]](1..9))
$cc2 = @{}; [void](Get-CachedSha256 $cc2 "fresh" $f2)
Check (-not $cc2.ContainsKey("fresh")) "cache: a file written in the last 2 s is not trusted into the cache"
Remove-Item $root -Recurse -Force

# =========================================================================
# 2. helpers: Get-Sha256, Remove-TreeFast, Expand-ZipTo, Copy-UserFiles, workers
# =========================================================================
$root = New-Root
$big = Join-Path $root "big.bin"
$rnd = New-Object Random 7; $buf = New-Object byte[] (20MB); $rnd.NextBytes($buf); [IO.File]::WriteAllBytes($big, $buf)
Check ((Get-Sha256 $big) -eq (Get-FileHash $big -Algorithm SHA256).Hash.ToLower()) "sha256: streamed hash equals Get-FileHash (20 MB)"
$ProgressMs = 0   # report on every block
$global:UoWork = [hashtable]::Synchronized(@{ Status = ""; Detail = ""; Done = 0L; Total = 0L; Cancel = $false; CanCancel = $true })
[void](Get-Sha256 $big)
Check ($global:UoWork.Total -eq 20MB -and $global:UoWork.Detail -match "of 20 MB") "sha256: reports progress for a big file when run with a window"
$global:UoWork.Cancel = $true
$threw = $false; try { [void](Get-Sha256 $big) } catch { $threw = Test-IsCancel $_ }
Check $threw "sha256: Cancel stops a big file"
$global:UoWork.CanCancel = $false
Check ((Get-Sha256 $big) -eq (Get-FileHash $big -Algorithm SHA256).Hash.ToLower()) "cancel: ignored once CanCancel is false (the swap)"
Remove-Variable UoWork -Scope Global
$ProgressMs = 200
$threw = $false; try { Assert-NotCancelled } catch { $threw = $true }
Check (-not $threw) "cancel: no window, no cancel"

# Remove-TreeFast: read-only file inside
$t = Join-Path $root "tree"
Put (P $t "a/b/c.txt") "x"; Put (P $t "a/ro.txt") "y"
(Get-Item (P $t "a/ro.txt")).IsReadOnly = $true
Remove-TreeFast $t
Check (-not (Test-Path $t)) "Remove-TreeFast: a tree with a read-only file is gone"
Remove-TreeFast (Join-Path $root "nothing-here")
Check $true "Remove-TreeFast: a missing folder is fine"

# Expand-ZipTo
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-ZipWith([string]$zip, $entries) {
    $fs = [IO.File]::Create($zip)
    $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
    foreach ($e in $entries.GetEnumerator()) {
        $en = $za.CreateEntry($e.Key)
        $w = New-Object IO.StreamWriter($en.Open()); $w.Write($e.Value); $w.Dispose()
    }
    $za.Dispose(); $fs.Dispose()
}
$z = Join-Path $root "ok.zip"
New-ZipWith $z @{ "TazUO.exe" = "exe"; "sub\win.txt" = "backslash entry"; "d/e/f.txt" = "nested"; "emptydir/" = "" }
$out = Join-Path $root "out"
Expand-ZipTo $z $out
Check ((Read-F (P $out "TazUO.exe")) -eq "exe" -and (Read-F (P $out "sub/win.txt")) -eq "backslash entry" -and (Read-F (P $out "d/e/f.txt")) -eq "nested" -and (Test-Path (P $out "emptydir"))) "unzip: files, backslash entries and folders extracted"
foreach ($evil in @("../evil.txt", "..\evil.txt", "a/../../evil.txt", "/abs.txt", "C:/win.txt")) {
    $zz = Join-Path $root "evil.zip"; Remove-Item $zz -Force -ErrorAction SilentlyContinue
    New-ZipWith $zz @{ $evil = "no" }
    $threw = $false; try { Expand-ZipTo $zz (Join-Path $root "o2") } catch { $threw = $true }
    Check ($threw -and -not (Test-Path (Join-Path $root "evil.txt")) -and -not (Test-Path (Join-Path (Split-Path $root) "evil.txt"))) "unzip: '$evil' is refused"
}

# Copy-UserFiles (the semantics are in updater.Tests.ps1; here: the fast version)
$old = Join-Path $root "oldc"; $new = Join-Path $root "newc"
Put (P $old "settings.json") "mine"; Put (P $old "Data/Profiles/a/p.json") "profile"; Put (P $old "Data/x.txt") "x"
Put (P $old "Scripts/mine.py") "py"; Put (P $old "Scripts/shipped.py") "old shipped"; Put (P $old "lib.dll") "dll"; Put (P $old "TazUO.deps.json") "deps"
Put (P $old "ExternalImages/art/0xFE99.png") "stale icon"
Put (P $new "Scripts/shipped.py") "new shipped"; Put (P $new "settings.json") "zip's"
(Get-Item (P $new "settings.json")).IsReadOnly = $true
Copy-UserFiles $old $new
Check ((Read-F (P $new "settings.json")) -eq "mine" -and (Read-F (P $new "Data/Profiles/a/p.json")) -eq "profile" -and (Read-F (P $new "Scripts/mine.py")) -eq "py") "user files: settings.json (even over a read-only one), Data and own scripts carried"
Check ((Read-F (P $new "Scripts/shipped.py")) -eq "new shipped" -and -not (Test-Path (P $new "lib.dll")) -and -not (Test-Path (P $new "TazUO.deps.json"))) "user files: the release's file wins, program files not carried"
Check ((Read-F (P $new "ExternalImages/art/0xFE99.png")) -eq "stale icon") "user files: other files (also old icons) are carried, as before"
Remove-Item $root -Recurse -Force

# Invoke-FileWorkers: 1 thread = 4 threads, errors and cancel come back
$root = New-Root
$files = 1..300 | ForEach-Object { $p = Join-Path $root "f$_.dat"; [IO.File]::WriteAllBytes($p, [byte[]](($_ % 250), 1, 2, 3)); (Get-Item $p).LastWriteTimeUtc = (Get-Date).AddHours(-1).ToUniversalTime(); @{ Key = "f$_"; Path = $p } }
$r1 = Invoke-FileWorkers $files $HashWorker $null 1
$r4 = Invoke-FileWorkers $files $HashWorker $null 4
$m1 = @{}; foreach ($x in $r1) { $m1[$x.Key] = $x.Sha }
$same = ($r4.Count -eq 300); foreach ($x in $r4) { if ($m1[$x.Key] -ne $x.Sha) { $same = $false } }
Check ($r1.Count -eq 300 -and $same -and ($r4 | Where-Object { $_.Stable }).Count -eq 300) "workers: 1 thread and 4 threads give the same 300 hashes, all stable"
$withBad = @($files) + @(@{ Key = "nope"; Path = (Join-Path $root "does-not-exist.dat") })
$threw = $null; try { [void](Invoke-FileWorkers $withBad $HashWorker $null 4) } catch { $threw = $_.Exception.Message }
Check ($threw -and $threw -match "does-not-exist") "workers: a failing file's error comes back (4 threads): $threw"
$threw = $null; try { [void](Invoke-FileWorkers $withBad $HashWorker $null 1) } catch { $threw = $_.Exception.Message }
Check ($threw -and $threw -match "does-not-exist") "workers: ... and with one thread"
$global:UoWork = [hashtable]::Synchronized(@{ Status = ""; Detail = ""; Done = 0L; Total = 0L; Cancel = $true; CanCancel = $true })
$threw = $false; try { [void](Invoke-FileWorkers $files $HashWorker $null 4) } catch { $threw = Test-IsCancel $_ }
Check $threw "workers: Cancel stops them with the cancelled exception"
Remove-Variable UoWork -Scope Global
Remove-Item $root -Recurse -Force

# =========================================================================
# 3. a synthetic client the size of v14's: scan cold vs warm, changes, delta
# =========================================================================
Write-Host ""
Write-Host "synthetic client: $N files ($([int]($N * 0.924)) icons)"

# deterministic content; variant 1 = the next release (a few changes)
function New-Content([int]$i, [int]$variant) {
    $len = 300 + ($i * 37) % 700
    $b = New-Object byte[] $len
    (New-Object Random ($i * 7919 + 13)).NextBytes($b)
    if ($variant -eq 1 -and ($i % 3000) -eq 5) { $b[0] = 255 - $b[0]; $b[$len - 1] = 7 }       # same size, other bytes
    if ($variant -eq 1 -and $i -eq 11) { $b = New-Object byte[] ($len + 50); (New-Object Random 99).NextBytes($b) }   # other size
    return , $b
}
function New-Tree([string]$dir, [int]$count, [int]$variant, [bool]$aged) {
    [void][IO.Directory]::CreateDirectory($dir)
    $icons = [int]($count * 0.924)
    $dirs = @{}
    for ($i = 0; $i -lt $count; $i++) {
        if ($i -eq 0) { $rel = "TazUO.exe" }
        elseif ($i -lt 40) { $rel = "lib$i.dll" }
        elseif ($i -lt ($count - $icons)) { $rel = "ExternalImages/gumps/0x{0:X4}.png" -f $i }
        else { $rel = "ExternalImages/art/0x{0:X5}.png" -f $i }
        if ($variant -eq 1 -and $i -eq 3) { continue }                       # removed in the next release
        $path = P $dir $rel
        $d = [IO.Path]::GetDirectoryName($path)
        if (-not $dirs.ContainsKey($d)) { [void][IO.Directory]::CreateDirectory($d); $dirs[$d] = 1 }
        $content = New-Content $i $variant
        if ($i -lt 40) { $content = $content + (New-Object byte[] 60000) }
        [IO.File]::WriteAllBytes($path, $content)
        if ($aged) { [IO.File]::SetLastWriteTimeUtc($path, (Get-Date).AddDays(-3).ToUniversalTime()) }
    }
    if ($variant -eq 1) { Put (P $dir "brand-new.dll") "added" }
}
function Get-TreeList([string]$dir) {
    $full = (Resolve-Path $dir).Path.TrimEnd('\', '/')
    $items = New-Object Collections.ArrayList
    foreach ($f in [IO.Directory]::EnumerateFiles($full, "*", [IO.SearchOption]::AllDirectories)) {
        [void]$items.Add(@{ Key = $f.Substring($full.Length + 1).Replace('\', '/'); Path = $f })
    }
    return , $items.ToArray()
}
function Get-TreeDigest([string]$dir) {   # path -> sha, via the workers
    $h = @{}
    foreach ($r in (Invoke-FileWorkers (Get-TreeList $dir) $HashWorker $null)) { $h[$r.Key] = $r.Sha }
    return $h
}
function New-ManifestFor([string]$dir, [string]$tag) {
    $full = (Resolve-Path $dir).Path.TrimEnd('\', '/')
    $list = foreach ($r in (Invoke-FileWorkers (Get-TreeList $dir) $HashWorker $null)) { [ordered]@{ path = $r.Key; size = $r.Size; sha256 = $r.Sha } }
    return ([ordered]@{ tag = $tag; files = @($list | Sort-Object { $_.path }) } | ConvertTo-Json -Depth 4)
}
function New-FileReader([string]$zip) {
    return {
        param([long]$from, [int]$count)
        $fs = [IO.File]::OpenRead($zip)
        try {
            [void]$fs.Seek($from, [IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] $count
            $got = 0
            while ($got -lt $count) { $n = $fs.Read($buf, $got, $count - $got); if ($n -le 0) { throw "short read" }; $got += $n }
        } finally { $fs.Dispose() }
        return , $buf
    }.GetNewClosure()
}
function Compare-Digest($a, $b) {
    if ($a.Count -ne $b.Count) { return $false }
    foreach ($k in $a.Keys) { if (-not $b.ContainsKey($k) -or $b[$k] -ne $a[$k]) { return $false } }
    return $true
}

$root = New-Root
$sw = [Diagnostics.Stopwatch]::StartNew()
New-Tree (Join-Path $root "Client") $N 0 $true
Put (P $root "Client/settings.json") '{"ip":"1.2.3.4"}'
Put (P $root "Client/Data/Profiles/a/p.json") "my profile"
Put (P $root "Client/LegionScripts/mine.py") "mine"
Write-Stamp (Join-Path $root "client-version.json") "v14" ("a" * 64)
$rel = Join-Path $root "release"
New-Tree $rel $N 1 $false
$listText = New-ManifestFor $rel "v15"
$zip = Join-Path $root "UOSmallz-Client-win-x64.zip"
[IO.Compression.ZipFile]::CreateFromDirectory($rel, $zip)
Info ("built the client, the release and its zip in {0:N1} s" -f $sw.Elapsed.TotalSeconds)
$zipSha = Get-Sha256 $zip
$p = Get-Paths $root
$clientDir = $p.Client
$manifest = Read-ClientManifest $listText
Check ($manifest.Files.Count -ge $N - 1) "manifest: $($manifest.Files.Count) entries read"
$before = Get-TreeDigest $clientDir

# ---- scan: first run (no cache) vs second run (cache) ----
$cache = Read-HashCache $p.HashCache
$tCold = Get-Seconds { $script:chg1 = Get-ChangedFiles $clientDir $manifest $cache }
$scan1 = $script:LastScan
[void](Write-HashCache $p.HashCache $cache)
Info ("first scan : {0:N2} s  ({1} files, {2} hashed, {3} from cache, {4} changed)" -f $tCold, $scan1.Files, $scan1.Hashed, $scan1.Cached, $scan1.Changed)
$cache = Read-HashCache $p.HashCache
$tWarm = Get-Seconds { $script:chg2 = Get-ChangedFiles $clientDir $manifest $cache }
$scan2 = $script:LastScan
Info ("second scan: {0:N2} s  ({1} files, {2} hashed, {3} from cache, {4} changed)" -f $tWarm, $scan2.Files, $scan2.Hashed, $scan2.Cached, $scan2.Changed)
Check ($scan1.Hashed -gt 0 -and $scan1.Cached -eq 0) "scan 1: nothing cached yet, files are hashed ($($scan1.Hashed))"
Check ($scan2.Hashed -eq 0 -and $scan2.Cached -ge $scan1.Hashed - 1) "scan 2: no file is hashed again; $($scan2.Cached) came from the cache"
Check ($tWarm -lt $tCold) ("scan 2 is faster than scan 1 ({0:N2} s vs {1:N2} s)" -f $tWarm, $tCold)
$names = (@($chg1 | ForEach-Object { $_.Path }) | Sort-Object) -join ","
Check (@($chg1).Count -eq @($chg2).Count -and ((@($chg2 | ForEach-Object { $_.Path }) | Sort-Object) -join ",") -eq $names) "scan 1 and 2 find the same changed files ($(@($chg1).Count))"
$chgNames = @($chg1 | ForEach-Object { $_.Path })
Check (($chgNames -contains "brand-new.dll") -and ($chgNames -contains "lib5.dll") -and ($chgNames -contains "lib11.dll")) "scan: the new file, the edited dll and the resized dll are the changed ones ($($chgNames.Count) in all)"
if ($N -ge 3100) { Check (@($chgNames | Where-Object { $_ -match 'png$' }).Count -ge 1) "scan: edited icons found among $($chgNames.Count) changed" }
Check (@($chg1 | Where-Object { $_.Path -eq "TazUO.exe" }).Count -eq 0) "scan: an untouched program file is not changed"

# ---- invalidation by size / mtime, and the escape hatch ----
$victimKey = "ExternalImages/art/0x{0:X5}.png" -f ($N - 3)
$victim = P $clientDir $victimKey
Check (Test-Path $victim) "(test setup: victim icon exists)"
$sz = (Get-Item $victim).Length; $mt = (Get-Item $victim).LastWriteTimeUtc
$cache = Read-HashCache $p.HashCache
[void](Get-ChangedFiles $clientDir $manifest $cache)   # victim as it is: same as the release?
$changedBefore = @((Get-ChangedFiles $clientDir $manifest $cache) | Where-Object { $_.Path -eq $victimKey }).Count
# same size, other bytes, mtime moved: must be seen
$bytes = [IO.File]::ReadAllBytes($victim); $bytes[1] = 255 - $bytes[1]; [IO.File]::WriteAllBytes($victim, $bytes); [IO.File]::SetLastWriteTimeUtc($victim, $mt.AddMinutes(7))
$c2 = @((Get-ChangedFiles $clientDir $manifest $cache) | Where-Object { $_.Path -eq $victimKey }).Count
Check ($c2 -eq 1 -and $script:LastScan.Hashed -eq 1) "invalidate: same size but a new mtime -> rehashed and seen as changed (hashed $($script:LastScan.Hashed))"
# back to the original bytes and mtime: same as the release again, cache row refreshed meanwhile
$bytes[1] = 255 - $bytes[1]; [IO.File]::WriteAllBytes($victim, $bytes); [IO.File]::SetLastWriteTimeUtc($victim, $mt)
$c3 = @((Get-ChangedFiles $clientDir $manifest $cache) | Where-Object { $_.Path -eq $victimKey }).Count
Check ($c3 -eq $changedBefore) "invalidate: restored bytes and mtime -> back to the earlier verdict"
# a different size: seen without any hashing
[IO.File]::WriteAllBytes($victim, ($bytes + [byte[]](1, 2, 3))); [IO.File]::SetLastWriteTimeUtc($victim, $mt)
$cache = Read-HashCache $p.HashCache
$c4 = @((Get-ChangedFiles $clientDir $manifest $cache) | Where-Object { $_.Path -eq $victimKey }).Count
Check ($c4 -eq 1) "invalidate: a new size is changed (no hashing needed)"
# deleted
Remove-Item $victim -Force
$c5 = @((Get-ChangedFiles $clientDir $manifest $cache) | Where-Object { $_.Path -eq $victimKey }).Count
Check ($c5 -eq 1) "invalidate: a deleted file is changed"
# a poisoned cache row (same size and mtime, other bytes) is trusted - that is the cost of the cache - and UOSMALLZ_REHASH=1 is the way out
[IO.File]::WriteAllBytes($victim, $bytes); [IO.File]::SetLastWriteTimeUtc($victim, $mt)
$cache = @{}; [void](Get-ChangedFiles $clientDir $manifest $cache)   # fresh scan caches the restored file
$bytes2 = $bytes.Clone(); $bytes2[2] = 255 - $bytes2[2]; [IO.File]::WriteAllBytes($victim, $bytes2); [IO.File]::SetLastWriteTimeUtc($victim, $mt)
$trusted = @((Get-ChangedFiles $clientDir $manifest $cache) | Where-Object { $_.Path -eq $victimKey }).Count
$env:UOSMALLZ_REHASH = "1"; [void](Write-HashCache $p.HashCache $cache)
$cacheOff = Read-HashCache $p.HashCache
$env:UOSMALLZ_REHASH = $null
$seen = @((Get-ChangedFiles $clientDir $manifest $cacheOff) | Where-Object { $_.Path -eq $victimKey }).Count
Check ($trusted -eq $changedBefore -and $seen -eq 1) "cache limit: same size+mtime edits are trusted; UOSMALLZ_REHASH=1 sees them"
[IO.File]::WriteAllBytes($victim, $bytes); [IO.File]::SetLastWriteTimeUtc($victim, $mt)
$before = Get-TreeDigest $clientDir

# ---- the delta update: copy + fetch + swap ----
$cache = Read-HashCache $p.HashCache
$changed = Get-ChangedFiles $clientDir $manifest $cache
[void](Write-HashCache $p.HashCache $cache)
$reader = New-FileReader $zip
$fetched = 0
$tDelta = Get-Seconds { $script:fetched = Install-ClientDelta $root $manifest $changed (Get-Item $zip).Length $reader $zipSha "v15" $cache }
Info ("delta install ({0} files, {1} changed): {2:N2} s" -f @($manifest.Files).Count, @($changed).Count, $tDelta)
$after = Get-TreeDigest $p.Client
$want = @{}; foreach ($f in $manifest.Files) { $want[$f.Path] = $f.Sha256 }
$userKeys = @("settings.json", "Data/Profiles/a/p.json", "LegionScripts/mine.py")
$program = @{}; foreach ($k in $after.Keys) { if ($userKeys -notcontains $k -and -not $want.ContainsKey($k)) { $program[$k] = 1 } }
$allOk = $true; foreach ($k in $want.Keys) { if (-not $after.ContainsKey($k) -or $after[$k] -ne $want[$k]) { $allOk = $false } }
Check $allOk "delta: every one of the release's $($want.Count) files in Client is byte-identical to the release"
Check ($program.Count -le 1) "delta: nothing unexpected carried besides the player's files and old icons ($($program.Count))"
Check ((Read-F (P $p.Client "settings.json")) -eq '{"ip":"1.2.3.4"}' -and (Read-F (P $p.Client "Data/Profiles/a/p.json")) -eq "my profile" -and (Read-F (P $p.Client "LegionScripts/mine.py")) -eq "mine") "delta: settings.json, Data and the player's scripts carried"
$oldNow = Get-TreeDigest $p.Old
Check ((Compare-Digest ($before) $oldNow)) "delta: Client.old is the previous client, untouched, every file"
Check ((Read-Stamp $p.Stamp).Tag -eq "v15" -and (Read-Pending $p.Pending).Tag -eq "v15" -and -not (Test-Path $p.New)) "delta: stamp v15, pending marker, no Client.new"
Check ($fetched -gt 0 -and $fetched -lt (Get-Item $zip).Length / 2) "delta: fetched only part of the zip ($fetched bytes of $((Get-Item $zip).Length))"
# the cache after the swap describes the new client: the NEXT scan hashes nothing
$cache = Read-HashCache $p.HashCache
$null = Get-ChangedFiles $p.Client $manifest $cache
Check ($script:LastScan.Hashed -eq 0 -and $script:LastScan.Changed -eq 0) "cache after the swap: the next scan hashes 0 files and finds 0 changed (hashed $($script:LastScan.Hashed), changed $($script:LastScan.Changed))"

# ---- legacy per-file approach on the same tree, for the numbers in the handoff note ----
if ($env:UOSMALLZ_TEST_BASELINE -eq "1") {
    $tOldScan = Get-Seconds {
        foreach ($f in $manifest.Files) {
            $local = Get-LocalPath $p.Client $f.Path
            if ((Test-Path -LiteralPath $local -PathType Leaf) -and (Get-Item -LiteralPath $local).Length -eq $f.Size -and ((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLower() -eq $f.Sha256)) { continue }
        }
    }
    $legacyDst = Join-Path $root "legacy-new"
    $tOldCopy = Get-Seconds {
        foreach ($f in $manifest.Files) {
            $dest = Get-LocalPath $legacyDst $f.Path
            $d = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            Copy-Item -LiteralPath (Get-LocalPath $p.Client $f.Path) -Destination $dest -Force
        }
    }
    $tOldRm = Get-Seconds { Remove-Item -LiteralPath $legacyDst -Recurse -Force }
    Info ("legacy per-file approach, same tree: scan {0:N1} s, copy {1:N1} s, delete {2:N1} s" -f $tOldScan, $tOldCopy, $tOldRm)
}

# =========================================================================
# 4. rollback: failures in the delta, in the swap, and through the runspace
# =========================================================================
function New-Scenario([int]$count = 1500) {
    # a fresh install of the base client and the next release (a few files differ)
    $r = New-Root
    $n = [Math]::Min($N, $count)
    New-Tree (Join-Path $r "Client") $n 0 $true
    Put (P $r "Client/settings.json") '{"ip":"1.2.3.4"}'
    Put (P $r "Client/Data/Profiles/a/p.json") "my profile"
    $rl = Join-Path $r "release"; New-Tree $rl $n 1 $false
    $lt = New-ManifestFor $rl "v15"
    $z = Join-Path $r "c.zip"; [IO.Compression.ZipFile]::CreateFromDirectory($rl, $z)
    Write-Stamp (Join-Path $r "client-version.json") "v14" ("a" * 64)
    return @{ Root = $r; Zip = $z; List = $lt; Digest = (Get-TreeDigest (Join-Path $r "Client")) }
}
function Test-Untouched($sc) {
    $pp = Get-Paths $sc.Root
    return (Test-Path $pp.Exe) -and (Compare-Digest $sc.Digest (Get-TreeDigest $pp.Client)) -and -not (Test-Path $pp.New) -and -not (Test-Path $pp.Old) -and -not (Test-Path $pp.Pending) -and (Read-Stamp $pp.Stamp).Tag -eq "v14"
}

# 4a. a fetched file does not match the list, found after the unchanged files were copied
$sc = New-Scenario
$pp = Get-Paths $sc.Root
$mf = Read-ClientManifest $sc.List
$last = $mf.Files | Where-Object { $_.Path -eq "brand-new.dll" }
$last.Sha256 = "b" * 64
$ch = Get-ChangedFiles $pp.Client $mf @{}
$threw = $null; try { [void](Install-ClientDelta $sc.Root $mf $ch (Get-Item $sc.Zip).Length (New-FileReader $sc.Zip) (Get-Sha256 $sc.Zip) "v15") } catch { $threw = $_.Exception.Message }
Check ($threw -match "does not match" -and (Test-Untouched $sc)) "rollback: a bad fetched file after the copy phase -> the old client is exactly as it was, no Client.new"
Remove-Item $sc.Root -Recurse -Force

# 4b. the swap itself fails (client-version.json cannot be written): Client.old goes back
$sc = New-Scenario
$pp = Get-Paths $sc.Root
Remove-Item $pp.Stamp -Force; New-Item -ItemType Directory -Path $pp.Stamp | Out-Null   # Write-Stamp will throw
$mf = Read-ClientManifest $sc.List
$ch = Get-ChangedFiles $pp.Client $mf @{}
$threw = $null; try { [void](Install-ClientDelta $sc.Root $mf $ch (Get-Item $sc.Zip).Length (New-FileReader $sc.Zip) (Get-Sha256 $sc.Zip) "v15") } catch { $threw = $_.Exception.Message }
$ok = $threw -and (Test-Path $pp.Exe) -and (Compare-Digest $sc.Digest (Get-TreeDigest $pp.Client)) -and -not (Test-Path $pp.New) -and -not (Test-Path $pp.Old) -and -not (Test-Path $pp.Pending)
Check $ok "rollback: a failure during the swap -> Client restored from Client.old, no Client.new, no pending marker ($threw)"
Remove-Item $sc.Root -Recurse -Force

# =========================================================================
# 5. the background runspace: liveness, progress, success, failure, cancel
# =========================================================================
# stand-ins for the window: Show-Busy answers an object (so the loop runs and
# Update-Busy is called ~every 50 ms), Update-Busy records what the UI thread sees
$script:ticks = New-Object Collections.ArrayList
$script:cancelAfter = -1.0
$script:clock = [Diagnostics.Stopwatch]::StartNew()
function Show-Busy([string]$text) { $script:clock.Restart(); $script:ticks.Clear(); return [pscustomobject]@{ Tag = @{ Allow = $false } } }
$script:throwAtTick = -1; $script:pumps = 0
function Invoke-UiPump($form) { $script:pumps++ }
function Update-Busy($form, $state) {
    if ($script:throwAtTick -ge 0 -and $script:ticks.Count -ge $script:throwAtTick) { throw "the window broke" }
    [void]$script:ticks.Add(@{ T = $script:clock.Elapsed.TotalMilliseconds; Status = [string]$state.Status; Done = [long]$state.Done; Total = [long]$state.Total; CanCancel = [bool]$state.CanCancel })
    if ($script:cancelAfter -ge 0 -and $script:clock.Elapsed.TotalSeconds -ge $script:cancelAfter -and [bool]$state.CanCancel) { $state.Cancel = $true }
}
function Close-Busy($form) { }

# 5a. a full-zip install through the runspace: the "UI thread" keeps ticking, the bar moves, the result is right
$sc = New-Scenario $N
$pp = Get-Paths $sc.Root
$zsha = Get-Sha256 $sc.Zip
$script:cancelAfter = -1.0
$tBg = Get-Seconds { Invoke-Background $sc.Root "Updating..." "Install-ClientUpdate" @($sc.Root, $sc.Zip, $zsha, "v15") }
$tk = @($script:ticks)
$gaps = @(); for ($i = 1; $i -lt $tk.Count; $i++) { $gaps += ($tk[$i].T - $tk[$i - 1].T) }
$maxGap = 0; if ($gaps.Count) { $maxGap = ($gaps | Measure-Object -Maximum).Maximum }
$statuses = @($tk | ForEach-Object { $_.Status } | Select-Object -Unique)
$withTotal = @($tk | Where-Object { $_.Total -gt 0 }).Count
Info ("background install: {0:N2} s, UI thread ticked {1} times, longest gap {2:N0} ms, statuses: {3}" -f $tBg, $tk.Count, $maxGap, ($statuses -join " | "))
Check ((Read-Stamp $pp.Stamp).Tag -eq "v15" -and (Test-Path $pp.Old) -and (Read-F (P $pp.Client "brand-new.dll")) -eq "added") "background: the install ran in the runspace and finished (stamp v15, Client.old kept)"
Check ($tk.Count -ge [Math]::Min(8, [Math]::Floor($tBg / 0.15)) -and $maxGap -lt 400) ("background: the UI thread was never blocked ($($tk.Count) ticks, longest gap {0:N0} ms)" -f $maxGap)
Check ($statuses.Count -ge 2) "background: the status line changed while it ran ($($statuses.Count) different)"
Check ($withTotal -ge 1 -or $tBg -lt 0.5) "background: a determinate progress (done/total) was reported ($withTotal ticks)"
Check ((Read-F (P $pp.Client "settings.json")) -eq '{"ip":"1.2.3.4"}') "background: the player's settings carried"
Remove-Item $sc.Root -Recurse -Force

# 5b. a failure inside the runspace (the swap cannot write the stamp): same message here, rollback done
$sc = New-Scenario
$pp = Get-Paths $sc.Root
Remove-Item $pp.Stamp -Force; New-Item -ItemType Directory -Path $pp.Stamp | Out-Null
$threw = $null; $type = $null
try { Invoke-Background $sc.Root "Updating..." "Install-ClientUpdate" @($sc.Root, $sc.Zip, (Get-Sha256 $sc.Zip), "v15") } catch { $threw = $_.Exception.Message; $type = $_.Exception.GetType().Name }
Check ($threw -and $type -ne "OperationCanceledException") "failure: the runspace's error reaches the caller ($threw)"
Check ((Test-Path $pp.Exe) -and (Compare-Digest $sc.Digest (Get-TreeDigest $pp.Client)) -and -not (Test-Path $pp.New) -and -not (Test-Path $pp.Old) -and -not (Test-Path $pp.Pending)) "failure: ... and the swap's rollback ran in the runspace: Client is as it was"
Remove-Item $sc.Root -Recurse -Force

# 5c. a wrong SHA-256 on the zip: refused in the runspace, nothing touched
$sc = New-Scenario
$threw = $null; try { Invoke-Background $sc.Root "Updating..." "Install-ClientUpdate" @($sc.Root, $sc.Zip, ("0" * 64), "v15") } catch { $threw = $_.Exception.Message }
Check ($threw -match "SHA256 mismatch" -and (Test-Untouched $sc)) "failure: a zip that fails its SHA-256 -> error to the caller, client untouched"
Remove-Item $sc.Root -Recurse -Force

# 5d. Cancel while it unpacks: nothing is left, the old client stays
$sc = New-Scenario
$script:cancelAfter = 0.15
$threw = $null; $isCancel = $false
$tC = Get-Seconds { try { Invoke-Background $sc.Root "Updating..." "Install-ClientUpdate" @($sc.Root, $sc.Zip, (Get-Sha256 $sc.Zip), "v15") } catch { $script:threw = $_.Exception.Message; $script:isCancel = $_.Exception -is [System.OperationCanceledException] } }
$script:cancelAfter = -1.0
Check ($isCancel) "cancel: the caller gets OperationCanceledException ($threw)"
Check (Test-Untouched $sc) "cancel: the old client is exactly as it was, no Client.new, no stamp change"
Info ("cancelled after {0:N2} s" -f $tC)
Remove-Item $sc.Root -Recurse -Force

# 5e. Cancel is honoured up to the ready marker and not after: CanCancel goes false for the swap
$sc = New-Scenario
$pp = Get-Paths $sc.Root
Expand-ZipTo $sc.Zip $pp.New
$global:UoWork = [hashtable]::Synchronized(@{ Status = ""; Detail = ""; Done = 0L; Total = 0L; Cancel = $true; CanCancel = $true })
$threw = $false; try { Complete-ClientUpdate $sc.Root ("a" * 64) "v15" } catch { $threw = Test-IsCancel $_ }
Remove-Variable UoWork -Scope Global   # (the digest below uses the workers, which would honour it too)
Check ($threw -and (Test-Untouched $sc)) "cancel: before the swap it stops, Client.new is removed, Client untouched"
Expand-ZipTo $sc.Zip $pp.New
$global:UoWork = [hashtable]::Synchronized(@{ Status = ""; Detail = ""; Done = 0L; Total = 0L; Cancel = $false; CanCancel = $true })
Complete-ClientUpdate $sc.Root ("a" * 64) "v15"
Check ($global:UoWork.CanCancel -eq $false -and (Read-Stamp $pp.Stamp).Tag -eq "v15") "cancel: the update marks itself not cancellable from the ready marker on"
Remove-Item $pp.Client -Recurse -Force; Rename-Item $pp.Old "Client"; Remove-Item $pp.Pending -Force; Write-Stamp $pp.Stamp "v14" ("a" * 64)
Expand-ZipTo $sc.Zip $pp.New
$global:UoWork.CanCancel = $false; $global:UoWork.Cancel = $true   # a late click: the button was already disabled
Complete-ClientUpdate $sc.Root ("a" * 64) "v15"
Check ((Read-Stamp $pp.Stamp).Tag -eq "v15" -and -not (Test-Path $pp.New)) "cancel: a Cancel that arrives during the swap is ignored, the swap completes"
Remove-Variable UoWork -Scope Global
Remove-Item $sc.Root -Recurse -Force

# 5f. no text to load into a runspace: runs inline, as before
$keep = $SelfText; $SelfText = $null
$sc = New-Scenario
$null = Invoke-Background $sc.Root "Updating..." "Install-ClientUpdate" @($sc.Root, $sc.Zip, (Get-Sha256 $sc.Zip), "v15")
Check ((Read-Stamp (Join-Path $sc.Root "client-version.json")).Tag -eq "v15") "fallback: without the script text the same work runs inline"
$SelfText = $keep
Remove-Item $sc.Root -Recurse -Force

# 5h. the real update job over HTTP with byte ranges: the changed-files path, then the full-zip fallback
function Start-RangeServer([int]$port, [string]$dir) {
    return Start-Job -ArgumentList $port, $dir -ScriptBlock {
        param($port, $dir)
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port)
        $l.Start()
        try {
            while ($true) {
                if (-not $l.Pending()) { Start-Sleep -Milliseconds 15; continue }   # (so Stop-Job can stop it)
                $c = $l.AcceptTcpClient()
                try {
                    $st = $c.GetStream()
                    $sb = New-Object Text.StringBuilder; $b = New-Object byte[] 1
                    while ($st.Read($b, 0, 1) -gt 0) { [void]$sb.Append([char]$b[0]); if ($sb.Length -ge 4 -and $sb.ToString().EndsWith("`r`n`r`n")) { break } }
                    $req = $sb.ToString()
                    if ($req -match '^GET /([^ ]+) HTTP') {
                        $file = Join-Path $dir $Matches[1]
                        if (Test-Path -LiteralPath $file) {
                            [byte[]]$all = [IO.File]::ReadAllBytes($file)
                            if ($req -match '(?im)^Range:\s*bytes=(\d+)-(\d*)') {
                                $from = [long]$Matches[1]; $to = $all.Length - 1
                                if ($Matches[2] -ne "") { $to = [Math]::Min([long]$Matches[2], $all.Length - 1) }
                                $len = $to - $from + 1
                                $h = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 206 Partial Content`r`nContent-Range: bytes $from-$to/$($all.Length)`r`nContent-Length: $len`r`nConnection: close`r`n`r`n")
                                $st.Write($h, 0, $h.Length); $st.Write($all, [int]$from, [int]$len)
                            } else {
                                $h = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($all.Length)`r`nConnection: close`r`n`r`n")
                                $st.Write($h, 0, $h.Length); $st.Write($all, 0, $all.Length)
                            }
                        } else {
                            $h = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"); $st.Write($h, 0, $h.Length)
                        }
                    }
                    $st.Flush()
                } catch { } finally { $c.Close() }
            }
        } finally { $l.Stop() }
    }
}
$sc = New-Scenario $N
$pp = Get-Paths $sc.Root
$srvDir = Join-Path $sc.Root "srv"; [void][IO.Directory]::CreateDirectory($srvDir)
$mName = "UOSmallz-Client-win-x64.files.json"
[IO.File]::WriteAllText((Join-Path $srvDir $mName), $sc.List)
Copy-Item $sc.Zip (Join-Path $srvDir "UOSmallz-Client-win-x64.zip")
$port = Get-Random -Minimum 20000 -Maximum 40000
$job = Start-RangeServer $port $srvDir
Start-Sleep -Milliseconds 1500
$base = "http://127.0.0.1:$port/"
$zsha = Get-Sha256 $sc.Zip
$info = @{ Tag = "v15"; Url = $base + "UOSmallz-Client-win-x64.zip"; Sha256 = $zsha; ManifestUrl = $base + $mName; ManifestSha256 = (Get-Sha256 (Join-Path $srvDir $mName)) }
$tmpZip = Join-Path $sc.Root "dl.zip"
$script:cancelAfter = -1.0
$tUp = Get-Seconds { Invoke-Background $sc.Root "Updating..." "Invoke-ClientUpdateWork" @($sc.Root, $info, $tmpZip) }
$tk = @($script:ticks)
$gaps = @(); for ($i = 1; $i -lt $tk.Count; $i++) { $gaps += ($tk[$i].T - $tk[$i - 1].T) }
$maxGap = 0; if ($gaps.Count) { $maxGap = ($gaps | Measure-Object -Maximum).Maximum }
$log = Read-F $pp.Log
Info ("Invoke-ClientUpdateWork in the background, over HTTP ranges, {0} files: {1:N2} s, {2} UI ticks, longest gap {3:N0} ms" -f $N, $tUp, $tk.Count, $maxGap)
Check ((Read-Stamp $pp.Stamp).Tag -eq "v15" -and $log -match "by fetching the changed files only" -and $log -match "checked \d+ files") "update job: changed-files update through the runspace, over HTTP ranges, logged"
Check ($tk.Count -ge [Math]::Min(8, [Math]::Floor($tUp / 0.15)) -and $maxGap -lt 400) ("update job: the UI thread was never blocked ($($tk.Count) ticks, longest gap {0:N0} ms)" -f $maxGap)
$mf = Read-ClientManifest $sc.List; $okAll = $true
$aft = Get-TreeDigest $pp.Client
foreach ($f in $mf.Files) { if ($aft[$f.Path] -ne $f.Sha256) { $okAll = $false } }
Check ($okAll -and (Test-Path (Join-Path $pp.Old "TazUO.exe"))) "update job: the whole new client matches the release; Client.old kept"
Check ((Get-ChildItem $pp.Root -Filter "client-hashcache.tsv").Count -eq 1) "update job: the hash cache is saved beside the client"
Stop-Job $job; Remove-Job $job -Force
Remove-Item $sc.Root -Recurse -Force

# the same, but the file list does not match its SHA-256: the full zip is used, in the same window
$sc = New-Scenario
$pp = Get-Paths $sc.Root
$srvDir = Join-Path $sc.Root "srv"; [void][IO.Directory]::CreateDirectory($srvDir)
[IO.File]::WriteAllText((Join-Path $srvDir $mName), $sc.List)
Copy-Item $sc.Zip (Join-Path $srvDir "UOSmallz-Client-win-x64.zip")
$port++
$job = Start-RangeServer $port $srvDir
Start-Sleep -Milliseconds 1500
$base = "http://127.0.0.1:$port/"
$info = @{ Tag = "v15"; Url = $base + "UOSmallz-Client-win-x64.zip"; Sha256 = (Get-Sha256 $sc.Zip); ManifestUrl = $base + $mName; ManifestSha256 = ("0" * 64) }
$null = Invoke-Background $sc.Root "Updating..." "Invoke-ClientUpdateWork" @($sc.Root, $info, (Join-Path $sc.Root "dl.zip"))
$log = Read-F $pp.Log
Check ((Read-Stamp $pp.Stamp).Tag -eq "v15" -and $log -match "changed-files update not used" -and (Read-F (P $pp.Client "brand-new.dll")) -eq "added") "update job: a bad file list -> falls back to the full zip, update done"
Stop-Job $job; Remove-Job $job -Force
Remove-Item $sc.Root -Recurse -Force

# the same, with a zip that fails its SHA-256 too: error to the caller, client untouched
$sc = New-Scenario
$pp = Get-Paths $sc.Root
$srvDir = Join-Path $sc.Root "srv"; [void][IO.Directory]::CreateDirectory($srvDir)
Copy-Item $sc.Zip (Join-Path $srvDir "UOSmallz-Client-win-x64.zip")
$port++
$job = Start-RangeServer $port $srvDir
Start-Sleep -Milliseconds 1500
$info = @{ Tag = "v15"; Url = "http://127.0.0.1:$port/UOSmallz-Client-win-x64.zip"; Sha256 = ("0" * 64); ManifestUrl = $null; ManifestSha256 = $null }
$threw = $null; try { $null = Invoke-Background $sc.Root "Updating..." "Invoke-ClientUpdateWork" @($sc.Root, $info, (Join-Path $sc.Root "dl.zip")) } catch { $threw = $_.Exception.Message }
Check ($threw -match "SHA256 mismatch" -and (Test-Untouched $sc)) "update job: full zip with a wrong SHA-256 -> error reaches the caller, old client untouched"
Stop-Job $job; Remove-Job $job -Force
Remove-Item $sc.Root -Recurse -Force

# scan in the background (the hash workers inside a runspace)
$sc = New-Scenario
$pp = Get-Paths $sc.Root
$mf = Read-ClientManifest $sc.List
$cachePre = @{}
$res = Invoke-Background $sc.Root "Checking..." "Get-ChangedFiles" @($pp.Client, $mf, $cachePre)
Check (@($res).Count -ge 3 -and $cachePre.Count -gt 100) "background scan: the hash workers run inside the runspace ($(@($res).Count) changed, $($cachePre.Count) cached)"
Remove-Item $sc.Root -Recurse -Force


# ---- QC 174 fixes ----
# L1: a full-zip install forgets the hash cache (same size + mtime, other bytes, then a revert)
$root = New-Root
$pp = Get-Paths $root
$mt = [DateTime]::SpecifyKind((Get-Date).AddDays(-5).Date.AddHours(10).AddMinutes(20), [DateTimeKind]::Local).ToUniversalTime()
function Set-Old([string]$text) { $f = P $pp.Client "x.dll"; [IO.File]::WriteAllText($f, $text); [IO.File]::SetLastWriteTimeUtc($f, $mt) }
Put (P $pp.Client "TazUO.exe") "exe"; [IO.File]::SetLastWriteTimeUtc((P $pp.Client "TazUO.exe"), $mt)
Set-Old "AAAA"
Write-Stamp $pp.Stamp "v1" ("a" * 64)
function New-OneManifest([string]$xText) {
    $x = Join-Path $root "m.tmp"; [IO.File]::WriteAllText($x, $xText); $e = Join-Path $root "e.tmp"; [IO.File]::WriteAllText($e, "exe")
    $j = [ordered]@{ tag = "v1"; files = @([ordered]@{ path = "TazUO.exe"; size = 3; sha256 = (Get-Sha256 $e) }, [ordered]@{ path = "x.dll"; size = $xText.Length; sha256 = (Get-Sha256 $x) }) } | ConvertTo-Json -Depth 4
    return Read-ClientManifest $j
}
$mOld = New-OneManifest "AAAA"
$cache = Read-HashCache $pp.HashCache
[void](Get-ChangedFiles $pp.Client $mOld $cache)
# (the files are older than the 2 s caution, so the rows are kept)
[void](Write-HashCache $pp.HashCache $cache)
Check ((Test-Path $pp.HashCache) -and (Read-HashCache $pp.HashCache).Count -eq 2) "L1: setup: the scan of the old client wrote a cache with a row per file"
# the release zip: x.dll has the same size AND the same mtime as the installed one, other bytes
$zsrc = Join-Path $root "zsrc"; Put (P $zsrc "TazUO.exe") "exe"; Put (P $zsrc "x.dll") "BBBB"
$zipx = Join-Path $root "full.zip"
$zf = [IO.File]::Create($zipx); $za = New-Object IO.Compression.ZipArchive($zf, [IO.Compression.ZipArchiveMode]::Create)
foreach ($pair in @(@("TazUO.exe", "exe"), @("x.dll", "BBBB"))) {
    $en = $za.CreateEntry($pair[0]); $en.LastWriteTime = New-Object DateTimeOffset ($mt.ToLocalTime())   # (zip times are local clock fields)
    $w = New-Object IO.StreamWriter($en.Open()); $w.Write($pair[1]); $w.Dispose()
}
$za.Dispose(); $zf.Dispose()
Install-ClientUpdate $root $zipx (Get-Sha256 $zipx) "v2"
$xi = New-Object IO.FileInfo (P $pp.Client "x.dll")
Info "mtime wanted $($mt.Ticks) got $($xi.LastWriteTimeUtc.Ticks)"
Check ((Read-F (P $pp.Client "x.dll")) -eq "BBBB" -and $xi.LastWriteTimeUtc.Ticks -eq $mt.Ticks) "L1: setup: the new x.dll has the old one's size and mtime, other bytes"
Check (-not (Test-Path $pp.HashCache)) "L1: the full-zip install removed the hash cache"
# a later release lists the OLD bytes again (revert): the scan must see x.dll as changed
$c2 = Read-HashCache $pp.HashCache
$chg = @(Get-ChangedFiles $pp.Client $mOld $c2 | ForEach-Object { $_.Path })
Check ($chg -contains "x.dll" -and $script:LastScan.Hashed -ge 1) "L1: revert to the old bytes: x.dll is seen as changed (changed: $($chg -join ','))"
# a rollback forgets it too
Set-Content -LiteralPath $pp.HashCache -Value "$HashCacheMagic"
Rename-Item $pp.Client "Client.failed"; Copy-Item -Recurse (P $root "Client.failed") $pp.Old
Write-Pending $pp.Pending "v2" ("b" * 64) @{ Tag = "v1"; Sha256 = ("a" * 64) } $false
Restore-PreviousClient $root
Check (-not (Test-Path $pp.HashCache)) "L1: a rollback (Restore-PreviousClient) forgets the hash cache"
Remove-Item $root -Recurse -Force

# L2: Cancel is switched on again before the full-zip fallback after a swap that failed
$sc = New-Scenario
$pp = Get-Paths $sc.Root
$mfList = Join-Path $sc.Root "list.json"; [IO.File]::WriteAllText($mfList, $sc.List)
$info = @{ Tag = "v15"; Url = "http://example.invalid/c.zip"; Sha256 = (Get-Sha256 $sc.Zip); ManifestUrl = "http://example.invalid/list"; ManifestSha256 = (Get-Sha256 $mfList) }
$script:origInvokeDelta = ${function:Invoke-ClientDelta}; $script:origSave = ${function:Save-UrlWithTimeout}
function Invoke-ClientDelta([string]$root, $info) {
    # the real thing up to the swap, then the swap fails (as it would on a locked folder)
    Set-WorkCancelable $false
    throw "the swap failed (test)"
}
$script:canAtDownload = $null; $script:dl = 0
function Save-UrlWithTimeout([string]$url, [string]$out, $a, $b, $c, [switch]$Resume) {
    $script:dl++; $script:canAtDownload = (Get-WorkState).CanCancel
    Copy-Item -LiteralPath $sc.Zip -Destination $out
}
$global:UoWork = [hashtable]::Synchronized(@{ Status = ""; Detail = ""; Done = 0L; Total = 0L; Cancel = $false; CanCancel = $true })
Invoke-ClientUpdateWork $sc.Root $info (Join-Path $sc.Root "dl.zip")
$canAfter = $global:UoWork.CanCancel
Remove-Variable UoWork -Scope Global
Check ($script:dl -eq 1 -and $script:canAtDownload -eq $true) "L2: after a failed swap the full-zip download starts with Cancel enabled"
Check ((Read-Stamp $pp.Stamp).Tag -eq "v15") "L2: ... and the fallback completes the update"
Set-Item function:Invoke-ClientDelta $script:origInvokeDelta
Set-Item function:Save-UrlWithTimeout $script:origSave
Remove-Item $sc.Root -Recurse -Force

# L3: when the window loop throws, the wait for the job pumps the window instead of blocking
$sc = New-Scenario $N
$pp = Get-Paths $sc.Root
$script:pumps = 0; $script:throwAtTick = 0;   # the very first tick (the job is still starting up)
 $script:cancelAfter = -1.0
$threw = $null
$tL3 = Get-Seconds { try { $null = Invoke-Background $sc.Root "Updating..." "Install-ClientUpdate" @($sc.Root, $sc.Zip, (Get-Sha256 $sc.Zip), "v15") } catch { $script:threw = $_.Exception.Message } }
$script:throwAtTick = -1
Check ($script:threw -eq "the window broke") "L3: the UI loop's own error reaches the caller ($script:threw)"
Check ($script:pumps -ge 1) ("L3: while waiting for the job to stop the window was pumped ($($script:pumps) times, {0:N1} s)" -f $tL3)
$pp2 = $pp
Check (((Test-Path $pp2.New) -eq $false) -and ((Read-Stamp $pp2.Stamp).Tag -in @("v14", "v15")) -and ((Test-Path (Join-Path $pp2.Client "TazUO.exe")))) "L3: the job stopped at a safe point: no Client.new, a whole Client"
Remove-Item $sc.Root -Recurse -Force

# L4: Cancel on a dead connection is immediate (it was the connect / stall timeout)
function Start-DeadServer([int]$port, [string]$mode) {
    return Start-Job -ArgumentList $port, $mode -ScriptBlock {
        param($port, $mode)
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port); $l.Start()
        try {
            while ($true) {
                if (-not $l.Pending()) { Start-Sleep -Milliseconds 15; continue }
                $c = $l.AcceptTcpClient(); $st = $c.GetStream()
                $b = New-Object byte[] 4096; [void]$st.Read($b, 0, 4096)
                if ($mode -eq "stall") {   # headers and a few bytes, then silence
                    $h = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 5000000`r`nConnection: close`r`n`r`nabcdef")
                    $st.Write($h, 0, $h.Length); $st.Flush()
                }
                Start-Sleep -Seconds 60   # (mode "silent": no answer at all)
            }
        } finally { $l.Stop() }
    }
}
$root = New-Root
$port = Get-Random -Minimum 20000 -Maximum 40000
foreach ($mode in @("silent", "stall")) {
    $port++
    $job = Start-DeadServer $port $mode
    Start-Sleep -Milliseconds 1500
    $out = Join-Path $root "dead-$mode.bin"
    $script:cancelAfter = 0.7; $script:isCancel = $false
    $tD = Get-Seconds { try { $null = Invoke-Background $root "Downloading..." "Save-UrlWithTimeout" @("http://127.0.0.1:$port/x", $out, 30, 60, 1800) } catch { $script:isCancel = $_.Exception -is [System.OperationCanceledException] } }
    $script:cancelAfter = -1.0
    Check ($script:isCancel -and $tD -lt 5) ("L4: Cancel on a connection that is $mode ends the download in {0:N1} s (timeouts are 30 / 60 s)" -f $tD)
    Check (-not (Test-Path $out)) "L4: ... and the partial file is removed ($mode)"
    Stop-Job $job; Remove-Job $job -Force
}
# the stall timeout still works in the background path (no Cancel pressed)
$port++
$job = Start-DeadServer $port "stall"
Start-Sleep -Milliseconds 1500
$script:err = $null
$tS = Get-Seconds { try { $null = Invoke-Background $root "Downloading..." "Save-UrlWithTimeout" @("http://127.0.0.1:$port/x", (Join-Path $root "stall2.bin"), 30, 2, 1800) } catch { $script:err = $_.Exception.Message } }
Check ($script:err -and $tS -lt 10) ("L4: a stalled download still times out in the background path ({0:N1} s: $script:err)" -f $tS)
Stop-Job $job; Remove-Job $job -Force
Remove-Item $root -Recurse -Force

# L5: the runspace's error position / stack goes to launch.log, the message to the caller
$sc = New-Scenario
$pp = Get-Paths $sc.Root
Remove-Item $pp.Stamp -Force; New-Item -ItemType Directory -Path $pp.Stamp | Out-Null
$script:err = $null; try { $null = Invoke-Background $sc.Root "Updating..." "Install-ClientUpdate" @($sc.Root, $sc.Zip, (Get-Sha256 $sc.Zip), "v15") } catch { $script:err = $_.Exception.Message }
$lg = Read-F $pp.Log
Check ($lg -match "background Install-ClientUpdate failed: " -and $lg -match "Write-Stamp" -and $lg -match "Complete-ClientUpdate" -and @($lg -split "`n" | Where-Object { $_ -match "background Install-ClientUpdate failed" }).Count -eq 1) "L5: launch.log gets the error detail with the stack on one line"
Check ($script:err -and $script:err -notmatch "\|") "L5: the caller still gets only the message"
Remove-Item $sc.Root -Recurse -Force


# ---- QC 174b: Clear-ClientHashCache never throws, and recovery / rollback finish whatever the cache path is ----
function New-RecoveryRoot([string]$kind) {
    # kind: "repair" = Client without TazUO.exe + Client.old (killed mid-swap); "restore" = new Client + Client.old + pending marker
    $r = New-Root
    $pq = Get-Paths $r
    Put (P $pq.Old "TazUO.exe") "old exe"; Put (P $pq.Old "Data/keep.txt") "old data"
    if ($kind -eq "repair") { Put (P $pq.Client "junk.txt") "half" }
    else {
        Put (P $pq.Client "TazUO.exe") "new exe"; Put (P $pq.Client "Data/mine.txt") "played since"
        Write-Stamp $pq.Stamp "v2" ("b" * 64)
        Write-Pending $pq.Pending "v2" ("b" * 64) @{ Tag = "v1"; Sha256 = ("a" * 64) } $false
    }
    return $r
}
function Set-CachePathTo([string]$r, [string]$how) {
    $pq = Get-Paths $r
    switch ($how) {
        "dir"      { Put (Join-Path $pq.HashCache "child.txt") "x" }                       # a non-empty folder where the file should be
        "readonly" { Set-Content -LiteralPath $pq.HashCache -Value $HashCacheMagic; (Get-Item $pq.HashCache).IsReadOnly = $true }
        "locked"   { Set-Content -LiteralPath $pq.HashCache -Value $HashCacheMagic; $script:lockFs = [IO.File]::Open($pq.HashCache, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        "file"     { Set-Content -LiteralPath $pq.HashCache -Value $HashCacheMagic }
    }
}
function Release-CachePath([string]$r) {
    if ($script:lockFs) { $script:lockFs.Dispose(); $script:lockFs = $null }
    $pq = Get-Paths $r
    if (Test-Path -LiteralPath $pq.HashCache -PathType Leaf) { (Get-Item $pq.HashCache).IsReadOnly = $false }
}
foreach ($how in @("file", "dir", "readonly", "locked")) {
    # Clear-ClientHashCache alone
    $r = New-Root; Set-CachePathTo $r $how
    $threw = $false; try { Clear-ClientHashCache $r } catch { $threw = $true }
    $pq = Get-Paths $r
    $valid = (Read-HashCache $pq.HashCache).Count -eq 0
    Check (-not $threw -and $valid) "N1: Clear-ClientHashCache with the cache path as '$how' never throws and leaves no usable cache"
    Release-CachePath $r; Remove-Item $r -Recurse -Force

    # Repair-ClientFolder: Client moved aside, Client.old back, whatever the cache path is
    $r = New-RecoveryRoot "repair"; Set-CachePathTo $r $how
    $pq = Get-Paths $r
    $res = $null; $threw = $null; try { $res = Repair-ClientFolder $r } catch { $threw = $_.Exception.Message }
    Check ($null -eq $threw -and $res -eq "old" -and (Read-F (P $pq.Client "TazUO.exe")) -eq "old exe" -and (Read-F (P $pq.Client "Data/keep.txt")) -eq "old data" -and -not (Test-Path $pq.Old)) "N1: Repair-ClientFolder with the cache path as '$how': the Client folder is back ($threw)"
    Release-CachePath $r; Remove-Item $r -Recurse -Force

    # Restore-PreviousClient: stamp, pending marker and skip file settled whatever the cache path is
    $r = New-RecoveryRoot "restore"; Set-CachePathTo $r $how
    $pq = Get-Paths $r
    $threw = $null; try { Restore-PreviousClient $r } catch { $threw = $_.Exception.Message }
    $skip = Read-F $pq.Skip
    Check ($null -eq $threw -and (Read-F (P $pq.Client "TazUO.exe")) -eq "old exe" -and (Read-F (P $pq.Client "Data/mine.txt")) -eq "played since" -and (Read-Stamp $pq.Stamp).Tag -eq "v1" -and -not (Test-Path $pq.Pending) -and $skip -and $skip.Trim() -eq ("v2 " + ("b" * 64))) "N1: Restore-PreviousClient with the cache path as '$how': Client.old back, stamp v1, marker gone, v2 skipped, played-since files kept ($threw)"
    Release-CachePath $r; Remove-Item $r -Recurse -Force
}
# a Client.new that is verified and complete (marker) is also restored whatever the cache path is
$r = New-Root; $pq = Get-Paths $r
Put (P $pq.New "TazUO.exe") "new exe"; Write-ReadyMarker $pq.New "v3" ("c" * 64); Put (Join-Path $pq.HashCache "child.txt") "x"
$res = $null; $threw = $null; try { $res = Repair-ClientFolder $r } catch { $threw = $_.Exception.Message }
Check ($null -eq $threw -and $res -eq "new" -and (Read-Stamp $pq.Stamp).Tag -eq "v3" -and (Read-F $pq.Exe) -eq "new exe") "N1: Repair-ClientFolder restoring a verified Client.new with a folder at the cache path ($threw)"
Remove-Item $r -Recurse -Force
# a full-zip install with a folder at the cache path completes
$sc = New-Scenario; $pq = Get-Paths $sc.Root
Put (Join-Path $pq.HashCache "child.txt") "x"
$threw = $null; try { Install-ClientUpdate $sc.Root $sc.Zip (Get-Sha256 $sc.Zip) "v15" } catch { $threw = $_.Exception.Message }
Check ($null -eq $threw -and (Read-Stamp $pq.Stamp).Tag -eq "v15") "N1: a full-zip install with a folder at the cache path still completes ($threw)"
Remove-Item $sc.Root -Recurse -Force
# N3: a delete that fails is logged, and the file is emptied instead (a read-only folder makes File.Delete fail; the log file is writable)
$r = New-Root; $pq = Get-Paths $r
Set-Content -LiteralPath $pq.HashCache -Value "$HashCacheMagic`n1`t2`t$("a" * 64)`tx.dll"
Set-Content -LiteralPath $pq.Log -Value "start"
& chmod 555 $r
$threw = $false; try { Clear-ClientHashCache $r } catch { $threw = $true }
& chmod 755 $r
$lg = Read-F $pq.Log
Check (-not $threw -and (Read-HashCache $pq.HashCache).Count -eq 0 -and $lg -match "hash cache could not be deleted .*emptied instead") "N3: a cache that cannot be deleted is emptied and the failure is written to launch.log"
Remove-Item $r -Recurse -Force

# 5g. a return value comes back
$rr = Invoke-Background $here "x" "Get-Sha256" @($launcher)
Check ($rr -eq (Get-Sha256 $launcher)) "background: a function's return value comes back"

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$script:pass passed, $script:fail failed"
exit $script:fail
