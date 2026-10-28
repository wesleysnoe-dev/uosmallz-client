# =========================================================================
# update-check.ps1 - UO Smallz launcher: "is there a newer client?", then play.
#
# The desktop / Start menu shortcut runs launch.vbs, which runs this hidden
# (no console flash). It lives in the install folder, next to Client\.
#
#   - No internet, GitHub down, rate-limited, anything at all goes wrong:
#     say nothing and start the game. A failed check never costs a session.
#   - Up to date: say nothing, start the game.
#   - Behind: one dialog (Update Now / Play Now / Skip This Version). Skip is
#     remembered per version (client-skipped.txt), so it never nags twice.
#   - Update: fetch only the files that changed (the release's file list,
#     checked against SHA256SUMS.txt, says which; they come out of the release
#     zip by byte range), or else download the whole client zip and check its
#     SHA256 against the release (asset digest and/or SHA256SUMS.txt). Either
#     way the new client is built beside the old one, settings.json, Data\
#     (profiles, macros, gumps) and any other file of the player's are carried
#     across, the folders are swapped, and any failure rolls back. The
#     previous client stays as Client.old until the next update.
#   - The launcher updates itself: a higher $LauncherVersion on main replaces
#     this script and launch.vbs, and runs in its place.
#   - HD art: once the client can draw it, offer the pack (Yes / No / Cancel =
#     don't ask again) from the GitHub release hd-art.json names into HDArt
#     beside Client, checked against hd-art.json (SHA-256); again only when
#     hd-art.json names a new one. A broken-off download resumes next time.
#   - HD creatures: the same for the animation packs (creatures, people and
#     clothes, several files of about 1 GB) into HDArt\anim, asked separately.
#   - The update and the HD downloads run in a background runspace
#     (Invoke-Background): the progress window (real bar, Cancel) is handled by
#     the UI thread every 50 ms, so it never goes "Not Responding". Hashes of
#     the installed files are cached (client-hashcache.tsv), and unchanged files
#     are copied in parallel with one [IO.File]::Copy each.
#
# Windows PowerShell 5.1. No token: the repo is public. Patterns (timeout,
# silent failure, dialog, skip, launch.log) follow uo-offline-dev's
# scripts/update-check.ps1.
#
# Dot-source it (". .\update-check.ps1 -NoMain") to load the functions only;
# tests/updater.Tests.ps1 does that.
# =========================================================================
param(
    [switch]$NoMain,
    [string]$InstallRoot
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# GitHub needs TLS 1.2; old .NET defaults on Windows PowerShell 5.1 may not
# offer it, and the check would then fail silently forever.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

# This script's own text, read once at load: background runspaces load their
# functions from it (Invoke-Background), so they run exactly the code this
# process loaded even if the launcher file is replaced meanwhile.
$SelfText = $null
try { if ($PSCommandPath) { $SelfText = [IO.File]::ReadAllText($PSCommandPath) } } catch { }

$Repo       = "wesleysnoe-dev/uosmallz-client"   # allowlist: never read from a file
$AssetName  = "UOSmallz-Client-win-x64.zip"
$SumsName   = "SHA256SUMS.txt"
$TimeoutSec = 6

# HD art (tools/hd-art in uo-offline-dev): the 2x pack (about 0.6 GB) and the
# creature packs (several files of about 1 GB), release assets of this public
# repo. What to expect (file name, size, SHA-256, and the release tag that
# holds them) comes from hd-art.json in this repo over HTTPS, so a download
# that does not match it is thrown away. The URL is always built here from
# $Repo and a tag of the form hd-art-N, never read from a file. A manifest
# without "release" still names the old shard server (hd-art serve, port
# 2595) until every launcher has moved on.
$HdArtManifestUrl = "https://raw.githubusercontent.com/$Repo/main/hd-art.json"
$HdArtLegacyUrl   = "http://uosmallz.duckdns.org:2595/"   # allowlist: never read from a file

# This launcher's version. It updates itself from this repo (Update-LauncherSelf)
# when installer/update-check.ps1 on main carries a higher number, so bump it
# with every change to this file or launch.vbs (the installer workflow refuses
# a change that does not).
$LauncherVersion = 10

# Each release also lists every file of the client zip with its size and
# SHA-256 (the build writes it); an update then fetches only what changed.
$ManifestName = "UOSmallz-Client-win-x64.files.json"

function Get-Paths([string]$root) {
    return @{
        Root      = $root
        Client    = Join-Path $root "Client"
        New       = Join-Path $root "Client.new"
        Old       = Join-Path $root "Client.old"
        Exe       = Join-Path (Join-Path $root "Client") "TazUO.exe"
        Stamp     = Join-Path $root "client-version.json"
        Pending   = Join-Path $root "client-pending.json"
        Skip      = Join-Path $root "client-skipped.txt"
        Log       = Join-Path $root "launch.log"
        HashCache = Join-Path $root "client-hashcache.tsv"
        HdArt      = Join-Path $root "HDArt"
        HdArtNew   = Join-Path $root "HDArt.new"
        HdArtOld   = Join-Path $root "HDArt.old"
        HdArtStamp = Join-Path $root "hdart-version.json"
        HdArtSkip  = Join-Path $root "hdart-skipped.txt"
        HdArtDl    = Join-Path $root "HDArt.download"
        HdAnim      = Join-Path (Join-Path $root "HDArt") "anim"
        HdAnimStamp = Join-Path $root "hdanim-version.json"
        HdAnimSkip  = Join-Path $root "hdanim-skipped.txt"
        HdAnimHashCache = Join-Path $root "hdanim-hashcache.tsv"
    }
}

function Write-LaunchLog([string]$root, [string]$msg) {
    try {
        $log = Join-Path $root "launch.log"
        # keep it small: start over past 256 KB
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 262144) {
            Remove-Item -LiteralPath $log -Force
        }
        Add-Content -LiteralPath $log -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -Encoding UTF8
    } catch { }
}

# ---- work in the background: progress and cancel ---------------------------
# The update and the HD downloads run in a background runspace
# (Invoke-Background) so the window keeps handling messages: "Not Responding"
# came from doing all of it on the UI thread. Inside that runspace
# $global:UoWork is a synchronized hashtable shared with the UI thread:
# Status / Detail / Done / Total feed the progress bar, Cancel is set by the UI,
# and CanCancel is cleared before the folder swap, which is never interrupted.
# Anywhere else (the installer, the tests) it does not exist and every helper
# below does nothing, so the same functions run synchronously as before.

$CancelMessage = "cancelled by the player"
$ProgressMs = 200   # how often a download / hash / unpack loop tells the window and looks for Cancel

function Get-WorkState {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
    param()
    return $global:UoWork
}

# New headline; the bar goes back to "working" (no known total).
function Set-WorkStatus([string]$text) {
    $w = Get-WorkState
    if ($null -eq $w) { return }
    $w.Status = $text; $w.Detail = ""; $w.Done = 0L; $w.Total = 0L
}

function Set-WorkProgress([long]$done, [long]$total, [string]$detail = "") {
    $w = Get-WorkState
    if ($null -eq $w) { return }
    $w.Done = $done; $w.Total = $total; $w.Detail = $detail
}

function Set-WorkCancelable([bool]$yes) {
    $w = Get-WorkState
    if ($null -eq $w) { return }
    $w.CanCancel = $yes
}

function Test-WorkCancelled {
    $w = Get-WorkState
    return ($null -ne $w -and [bool]$w.Cancel -and [bool]$w.CanCancel)
}

# Throws the "player cancelled" exception when Cancel was asked for (and may
# still be honoured). Call it at points where stopping leaves nothing behind.
function Assert-NotCancelled {
    if (Test-WorkCancelled) { throw (New-Object System.OperationCanceledException $CancelMessage) }
}

function Test-IsCancel($err) {
    $e = $err
    if ($err -is [Management.Automation.ErrorRecord]) { $e = $err.Exception }
    while ($e) {
        if ($e -is [System.OperationCanceledException]) { return $true }
        $e = $e.InnerException
    }
    return $false
}

function Format-MB([long]$bytes) { return ("{0:N0} MB" -f ($bytes / 1MB)) }

# A path as .NET wants it: absolute, and relative to where PowerShell is, not
# to the process.
function ConvertTo-FullPath([string]$path) {
    if ([IO.Path]::IsPathRooted($path)) { return $path }
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
}

# Delete a folder tree in one .NET call (Remove-Item -Recurse is several times
# slower on the 15,000 icons). Read-only files get their flag cleared and one
# more try; Remove-Item has the last word. -Quiet swallows a failure.
function Remove-TreeFast([string]$path, [switch]$Quiet) {
    try {
        if (-not (Test-Path -LiteralPath $path)) { return }
        $full = ConvertTo-FullPath $path
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force; return }
        try {
            [IO.Directory]::Delete($full, $true)
        } catch {
            foreach ($f in [IO.Directory]::EnumerateFiles($full, "*", [IO.SearchOption]::AllDirectories)) {
                try { [IO.File]::SetAttributes($f, [IO.FileAttributes]::Normal) } catch { }
            }
            try { [IO.Directory]::Delete($full, $true) } catch { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    } catch {
        if (-not $Quiet) { throw }
    }
}

# ---- hash cache ----------------------------------------------------------------
# Hashing every installed file is what made an update slow (15,314 files, 14,154
# of them icons). The launcher keeps "size, mtime (UTC ticks), SHA-256" per file
# in client-hashcache.tsv beside the client; a file whose size and mtime are the
# same as when it was hashed is not read again. Tab-separated text rather than
# JSON: Windows PowerShell 5.1's ConvertFrom-Json takes seconds on 15,000 rows.
#   line 1: UOSMALLZ-HASHCACHE 1       then  size <TAB> ticks <TAB> sha256 <TAB> path
# A file with a new size or mtime is hashed again; a missing, unreadable or
# foreign cache file is the same as no cache. UOSMALLZ_REHASH=1 ignores it.
$HashCacheMagic = "UOSMALLZ-HASHCACHE 1"
$HashRacyTicks  = 20000000L   # a file touched in the last 2 s is not trusted into the cache

function Read-HashCache([string]$path) {
    $c = @{}
    if ($env:UOSMALLZ_REHASH -eq "1") { return $c }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $c }
    try {
        $first = $true
        foreach ($line in [IO.File]::ReadLines((ConvertTo-FullPath $path))) {
            if ($first) {
                if ($line -ne $HashCacheMagic) { return @{} }
                $first = $false
                continue
            }
            $f = $line.Split([char]9, 4)
            if ($f.Count -ne 4 -or $f[2] -notmatch '^[0-9a-f]{64}$' -or $f[3] -eq "") { continue }
            $c[$f[3]] = @([long]$f[0], [long]$f[1], [string]$f[2])
        }
    } catch { return @{} }
    return $c
}

# Never throws: a cache that cannot be saved only costs the next run a rehash.
function Write-HashCache([string]$path, [hashtable]$cache) {
    $tmp = "$path.tmp"
    try {
        $full = ConvertTo-FullPath $tmp
        $sw = New-Object IO.StreamWriter($full, $false, (New-Object Text.UTF8Encoding($false)))
        try {
            $sw.Write($HashCacheMagic + "`n")
            foreach ($k in $cache.Keys) {
                if ($k.IndexOf([char]9) -ge 0 -or $k.IndexOf([char]10) -ge 0 -or $k.IndexOf([char]13) -ge 0) { continue }
                $e = $cache[$k]
                $sw.Write("$($e[0])`t$($e[1])`t$($e[2])`t$k`n")
            }
        } finally { $sw.Dispose() }
        if (Test-Path -LiteralPath $path) { [IO.File]::Delete((ConvertTo-FullPath $path)) }
        [IO.File]::Move($full, (ConvertTo-FullPath $path))
        return $true
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Set-CacheEntry([hashtable]$cache, [string]$key, [long]$size, [long]$ticks, [string]$sha) {
    $cache[$key] = @($size, $ticks, $sha)
}

# The SHA-256 of $path, from the cache when its size and mtime still match,
# else hashed (and cached, unless the file changed or is too fresh to trust).
function Get-CachedSha256([hashtable]$cache, [string]$key, [string]$path) {
    $fi = New-Object IO.FileInfo (ConvertTo-FullPath $path)
    $size = $fi.Length; $ticks = $fi.LastWriteTimeUtc.Ticks
    $e = $cache[$key]
    if ($e -and $e[0] -eq $size -and $e[1] -eq $ticks) { return [string]$e[2] }
    $sha = Get-Sha256 $path
    $fi.Refresh()
    if ($fi.Length -eq $size -and $fi.LastWriteTimeUtc.Ticks -eq $ticks -and ([DateTime]::UtcNow.Ticks - $ticks) -gt $HashRacyTicks) {
        Set-CacheEntry $cache $key $size $ticks $sha
    }
    return $sha
}

# Is $path the file ($size bytes, $sha) says it should be?
function Test-FileMatchesCached([hashtable]$cache, [string]$key, [string]$path, [long]$size, [string]$sha) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    if ((New-Object IO.FileInfo (ConvertTo-FullPath $path)).Length -ne $size) { return $false }
    return (Get-CachedSha256 $cache $key $path) -eq $sha.ToLower()
}

# ---- many files at once ----------------------------------------------------------
# $worker is { param($queue, $sh, $ctx) }: it takes items off the queue until it
# is empty or $sh.Abort, puts one result per item in $sh.Results, and counts in
# $sh.Done. The workers below are self-contained (they run in pooled runspaces
# that have none of this script's functions). One thread runs it right here.

function Get-WorkerCount {
    $n = [Math]::Max(2, [Math]::Min(6, [Environment]::ProcessorCount))
    $e = [Environment]::GetEnvironmentVariable("UOSMALLZ_THREADS")
    if ($e -match '^\d{1,2}$' -and [int]$e -ge 1) { $n = [int]$e }
    return $n
}

# Hash the files of @{ Key; Path } items; one @{ Key; Size; Ticks; Sha; Stable }
# per item. Stable = size and mtime did not move while it was read (and it is
# not brand new), so it may go in the cache.
$HashWorker = {
    param($queue, $sh, $ctx)
    $ErrorActionPreference = "Stop"
    $hasher = [Security.Cryptography.SHA256]::Create()
    $w = $sh.Work
    $item = $null
    try {
        while (-not $sh.Abort) {
            if ($w -and $w.Cancel -and $w.CanCancel) { $sh.Cancelled = $true; $sh.Abort = $true; break }
            if (-not $queue.TryDequeue([ref]$item)) { break }
            $fi = New-Object System.IO.FileInfo $item.Path
            $size = $fi.Length; $ticks = $fi.LastWriteTimeUtc.Ticks
            $fs = New-Object System.IO.FileStream($item.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite, 65536)
            try { $bytes = $hasher.ComputeHash($fs) } finally { $fs.Dispose() }
            $fi.Refresh()
            $stable = ($fi.Length -eq $size) -and ($fi.LastWriteTimeUtc.Ticks -eq $ticks) -and (([DateTime]::UtcNow.Ticks - $ticks) -gt 20000000L)
            $sha = [BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
            $sh.Results.Enqueue(@{ Key = $item.Key; Size = $size; Ticks = $ticks; Sha = $sha; Stable = $stable })
            [Threading.Monitor]::Enter($sh.Lock)
            try { $sh.Done = $sh.Done + 1; $n = $sh.Done } finally { [Threading.Monitor]::Exit($sh.Lock) }
            if ($w -and ($n % 50) -eq 0) { $w.Done = [long]$n; $w.Total = [long]$sh.Total; $w.Detail = "$n of $($sh.Total)" }
        }
    } catch {
        if (-not $sh.Error) { $sh.Error = $_.Exception.Message }
        $sh.Abort = $true
    } finally { $hasher.Dispose() }
}

# Copy @{ Key; Src; Dst; Size; Sha } items (the destination folders exist
# already) with one [IO.File]::Copy each, and check the size that arrived.
$CopyWorker = {
    param($queue, $sh, $ctx)
    $ErrorActionPreference = "Stop"
    $w = $sh.Work
    $item = $null
    try {
        while (-not $sh.Abort) {
            if ($w -and $w.Cancel -and $w.CanCancel) { $sh.Cancelled = $true; $sh.Abort = $true; break }
            if (-not $queue.TryDequeue([ref]$item)) { break }
            [System.IO.File]::Copy($item.Src, $item.Dst, $true)
            $fi = New-Object System.IO.FileInfo $item.Dst
            if ($fi.Length -ne $item.Size) { throw "the copy of $($item.Key) is $($fi.Length) bytes, not $($item.Size)" }
            $ticks = $fi.LastWriteTimeUtc.Ticks
            $sh.Results.Enqueue(@{ Key = $item.Key; Size = $fi.Length; Ticks = $ticks; Sha = $item.Sha; Stable = (([DateTime]::UtcNow.Ticks - $ticks) -gt 20000000L) })
            [Threading.Monitor]::Enter($sh.Lock)
            try { $sh.Done = $sh.Done + 1; $n = $sh.Done } finally { [Threading.Monitor]::Exit($sh.Lock) }
            if ($w -and ($n % 50) -eq 0) { $w.Done = [long]$n; $w.Total = [long]$sh.Total; $w.Detail = "$n of $($sh.Total)" }
        }
    } catch {
        if (-not $sh.Error) { $sh.Error = $_.Exception.Message }
        $sh.Abort = $true
    }
}

# Run $worker over $items on $threads threads (0 = Get-WorkerCount) and return
# the results. Throws the first worker's error, or the "cancelled" exception.
function Invoke-FileWorkers([object[]]$items, [scriptblock]$worker, $ctx = $null, [int]$threads = 0) {
    $total = @($items).Count
    if ($total -eq 0) { return @() }
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    foreach ($i in $items) { $queue.Enqueue($i) }
    $results = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $sh = [hashtable]::Synchronized(@{
        Done = 0; Total = $total; Abort = $false; Cancelled = $false; Error = $null
        Results = $results; Lock = (New-Object object); Work = (Get-WorkState)
    })
    if ($threads -le 0) { $threads = Get-WorkerCount }
    if ($threads -gt $total) { $threads = $total }
    $pool = $null; $jobs = @()
    try {
        if ($threads -le 1) {
            & $worker $queue $sh $ctx
        } else {
            $pool = [runspacefactory]::CreateRunspacePool(1, $threads)
            $pool.Open()
            for ($t = 0; $t -lt $threads; $t++) {
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($worker.ToString()).AddArgument($queue).AddArgument($sh).AddArgument($ctx)
                $jobs += , @{ PS = $ps; Handle = $ps.BeginInvoke() }
            }
            foreach ($j in $jobs) {
                while (-not $j.Handle.IsCompleted) { Start-Sleep -Milliseconds 20 }
                try { [void]$j.PS.EndInvoke($j.Handle) } catch { if (-not $sh.Error) { $sh.Error = $_.Exception.Message }; $sh.Abort = $true }
            }
        }
    } finally {
        $sh.Abort = $true
        foreach ($j in $jobs) { try { $j.PS.Dispose() } catch { } }
        if ($pool) { try { $pool.Close(); $pool.Dispose() } catch { } }
    }
    if ($sh.Cancelled) { throw (New-Object System.OperationCanceledException $CancelMessage) }
    if ($sh.Error) { throw [string]$sh.Error }
    return $results.ToArray()
}

# ---- version stamp -------------------------------------------------------

function Read-Stamp([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return @{ Tag = [string]$j.tag; Sha256 = ([string]$j.sha256).ToLower() }
    } catch { return $null }
}

function Write-Stamp([string]$path, [string]$tag, [string]$sha) {
    $obj = [ordered]@{ tag = $tag; sha256 = $sha.ToLower(); installed = (Get-Date).ToString("s") }
    $json = $obj | ConvertTo-Json
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}

# "v2" / "v2.1" / "2" -> [version]; anything else -> $null
function ConvertTo-TagVersion([string]$tag) {
    if ($tag -match '^[vV]?(\d+)(\.\d+){0,3}$') {
        $s = $tag.TrimStart('v', 'V')
        if ($s -notmatch '\.') { $s = "$s.0" }
        try { return [version]$s } catch { return $null }
    }
    return $null
}

# Is the release (tag, sha) newer than what is installed?
#   - both tags numeric: newer only when the release's number is higher;
#     the same number with a different zip (re-published assets) also counts
#   - otherwise: any difference in tag or sha counts
#   - no stamp / unknown: offered (the player can Skip)
function Test-IsNewer($local, [string]$remoteTag, [string]$remoteSha) {
    if ([string]::IsNullOrWhiteSpace($remoteTag)) { return $false }
    if ($null -eq $local -or [string]::IsNullOrWhiteSpace($local.Tag) -or $local.Tag -eq "unknown") { return $true }
    $lv = ConvertTo-TagVersion $local.Tag
    $rv = ConvertTo-TagVersion $remoteTag
    $shaDiffers = (-not [string]::IsNullOrWhiteSpace($remoteSha)) -and
                  (-not [string]::IsNullOrWhiteSpace($local.Sha256)) -and
                  ($remoteSha.ToLower() -ne $local.Sha256.ToLower())
    if ($lv -and $rv) {
        if ($rv -gt $lv) { return $true }
        if ($rv -lt $lv) { return $false }
        return $shaDiffers
    }
    return ($remoteTag -ne $local.Tag) -or $shaDiffers
}

# ---- release lookup ------------------------------------------------------

function Get-WebHeaders { return @{ "User-Agent" = "UOSmallz-launcher"; "Accept" = "application/vnd.github+json" } }

# Parse "sha256  name" lines; return the hash for $name or $null.
function Get-ShaFromSums([string]$text, [string]$name) {
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$' -and $Matches[2] -eq $name) {
            return $Matches[1].ToLower()
        }
    }
    return $null
}

# From a releases/latest object: tag, download URL, expected SHA256 (lower
# case, or $null when the release publishes none). $SumsText is the content
# of SHA256SUMS.txt when available. When both are present they must agree.
function Get-UpdateInfo($release, [string]$sumsText) {
    if ($null -eq $release -or [string]::IsNullOrWhiteSpace([string]$release.tag_name)) { return $null }
    $asset = @($release.assets | Where-Object { $_.name -eq $AssetName }) | Select-Object -First 1
    if ($null -eq $asset) { return $null }
    $digestSha = $null
    if ($asset.PSObject.Properties.Name -contains "digest" -and ([string]$asset.digest) -match '^sha256:([0-9a-fA-F]{64})$') {
        $digestSha = $Matches[1].ToLower()
    }
    $sumsSha = $null
    if ($sumsText) { $sumsSha = Get-ShaFromSums $sumsText $AssetName }
    if ($digestSha -and $sumsSha -and $digestSha -ne $sumsSha) {
        throw "release digest and SHA256SUMS.txt disagree for $AssetName"
    }
    $sha = $digestSha
    if (-not $sha) { $sha = $sumsSha }

    # The file list, when the release has one, checked the same way. Without a
    # SHA-256 for it (or with two that disagree) there is no changed-files update.
    $manifestUrl = $null; $manifestSha = $null
    $m = @($release.assets | Where-Object { $_.name -eq $ManifestName }) | Select-Object -First 1
    if ($m) {
        $mDigest = $null
        if ($m.PSObject.Properties.Name -contains "digest" -and ([string]$m.digest) -match '^sha256:([0-9a-fA-F]{64})$') { $mDigest = $Matches[1].ToLower() }
        $mSums = $null
        if ($sumsText) { $mSums = Get-ShaFromSums $sumsText $ManifestName }
        if (-not ($mDigest -and $mSums -and $mDigest -ne $mSums)) {
            $manifestSha = $mDigest
            if (-not $manifestSha) { $manifestSha = $mSums }
            if ($manifestSha) { $manifestUrl = [string]$m.browser_download_url }
        }
    }
    return @{
        Tag    = [string]$release.tag_name
        Url    = [string]$asset.browser_download_url
        Sha256 = $sha
        Notes  = [string]$release.body
        Name   = [string]$release.name
        ManifestUrl    = $manifestUrl
        ManifestSha256 = $manifestSha
    }
}

function Get-LatestRelease {
    $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers (Get-WebHeaders) -TimeoutSec $TimeoutSec
    $sums = $null
    $sumsAsset = @($r.assets | Where-Object { $_.name -eq $SumsName }) | Select-Object -First 1
    if ($sumsAsset) {
        try {
            $sums = (Invoke-WebRequest -Uri $sumsAsset.browser_download_url -Headers @{ "User-Agent" = "UOSmallz-launcher" } -TimeoutSec $TimeoutSec -UseBasicParsing).Content
            if ($sums -is [byte[]]) { $sums = [Text.Encoding]::UTF8.GetString($sums) }
        } catch { $sums = $null }
    }
    return Get-UpdateInfo $r $sums
}

# Download $url to $out with real timeouts: $ConnectSec to get a response,
# $StallSec without a single byte arriving, $TotalSec overall. On any
# failure the partial file is deleted and the error is thrown. -Resume: a
# partial $out is kept on failure, and the next call asks for the rest
# (Range); a server that answers with the whole file starts it over.
function Save-UrlWithTimeout([string]$url, [string]$out, [int]$ConnectSec = 30, [int]$StallSec = 30, [int]$TotalSec = 1800, [switch]$Resume) {
    $resp = $null; $in = $null; $fs = $null
    try {
        $have = 0L
        if ($Resume -and (Test-Path -LiteralPath $out)) { $have = (Get-Item -LiteralPath $out).Length }
        $req = [Net.HttpWebRequest]::Create($url)
        $req.UserAgent = "UOSmallz-launcher"
        $req.AllowAutoRedirect = $true
        $req.Timeout = $ConnectSec * 1000
        $req.ReadWriteTimeout = $StallSec * 1000
        if ($have -gt 0) { $req.AddRange([long]$have) }
        try {
            $resp = $req.GetResponse()
        } catch {
            # 416: what is there is already the whole file (or more); the
            # checksum decides.
            $ex = $_.Exception
            while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
            $r = $null
            if ($ex) { $r = $ex.Response }
            if ($have -gt 0 -and $r -and [int]$r.StatusCode -eq 416) { $r.Dispose(); return }
            throw
        }
        $in = $resp.GetResponseStream()
        if ($have -gt 0 -and [int]$resp.StatusCode -eq 206) {
            $fs = New-Object IO.FileStream($out, [IO.FileMode]::Append, [IO.FileAccess]::Write)
        } else {
            $fs = [IO.File]::Create($out)
        }
        $buf = New-Object byte[] 65536
        $sw = [Diagnostics.Stopwatch]::StartNew()
        # progress and Cancel for the window (nothing when run inline). A Cancel
        # leaves a -Resume partial in place, like any other broken-off download.
        $work = Get-WorkState
        $got = 0L; $expect = 0L
        if ($work) {
            if ($have -gt 0 -and [int]$resp.StatusCode -eq 206) { $got = $have }
            if ($resp.ContentLength -gt 0) { $expect = $got + $resp.ContentLength }
        }
        $tick = [Diagnostics.Stopwatch]::StartNew()
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $n)
            if ($sw.Elapsed.TotalSeconds -gt $TotalSec) { throw "download took longer than $TotalSec s" }
            if ($work) {
                $got += $n
                if ($tick.ElapsedMilliseconds -ge $ProgressMs) {
                    $tick.Restart()
                    Assert-NotCancelled
                    if ($expect -gt 0) { Set-WorkProgress $got $expect "$(Format-MB $got) of $(Format-MB $expect)" }
                    else { Set-WorkProgress 0 0 (Format-MB $got) }
                }
            }
        }
    } catch {
        $err = $_
        if ($fs) { try { $fs.Dispose() } catch { }; $fs = $null }
        if (-not $Resume) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
        throw $err
    } finally {
        if ($fs) { $fs.Dispose() }
        if ($in) { $in.Dispose() }
        if ($resp) { $resp.Dispose() }
    }
}

# ---- file checks ---------------------------------------------------------

# Streams the file through SHA-256 (Get-FileHash is the same, minus progress and
# Cancel, which a 1 GB .uoanim needs).
function Get-Sha256([string]$path) {
    $full = ConvertTo-FullPath $path
    $work = Get-WorkState
    $hasher = [Security.Cryptography.SHA256]::Create()
    $fs = New-Object IO.FileStream($full, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, 1048576)
    try {
        $len = $fs.Length
        $buf = New-Object byte[] 4194304
        $done = 0L
        $tick = [Diagnostics.Stopwatch]::StartNew()
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            [void]$hasher.TransformBlock($buf, 0, $n, $null, 0)
            $done += $n
            if ($work -and $len -gt 8MB -and $tick.ElapsedMilliseconds -ge $ProgressMs) {
                $tick.Restart()
                Assert-NotCancelled
                Set-WorkProgress $done $len "checking $(Format-MB $done) of $(Format-MB $len)"
            }
        }
        [void]$hasher.TransformFinalBlock($buf, 0, 0)
        return ([BitConverter]::ToString($hasher.Hash).Replace("-", "").ToLowerInvariant())
    } finally {
        $fs.Dispose()
        $hasher.Dispose()
    }
}

function Test-Sha256([string]$path, [string]$expected) {
    if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
    return (Get-Sha256 $path) -eq $expected.ToLower()
}

# Is a TazUO.exe from this Client folder running?
function Get-ClientProcess([string]$clientDir) {
    $full = [IO.Path]::GetFullPath($clientDir).TrimEnd('\', '/')
    return @(Get-Process -Name "TazUO" -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -and ([IO.Path]::GetFullPath($_.Path)).StartsWith($full, [StringComparison]::OrdinalIgnoreCase) } catch { $false }
    })
}

# ---- the swap ------------------------------------------------------------

# Copy the player's files from the old client into the new one:
#   - settings.json and everything under Data\ (profiles, macros, gumps,
#     journal, per-server settings) always win over the zip
#   - any other file the new zip does not have (screenshots, Legion scripts
#     the player added, logs) is copied too, except program files
function Copy-UserFiles([string]$oldDir, [string]$newDir) {
    $old = (ConvertTo-FullPath $oldDir).TrimEnd('\', '/')
    $newFull = ConvertTo-FullPath $newDir
    $made = New-Object 'System.Collections.Generic.HashSet[string]'
    $n = 0
    Set-WorkStatus "Carrying your settings and files over..."
    # one lazy walk and plain .NET calls per file: Get-ChildItem + Test-Path +
    # Copy-Item per file took most of the time on 15,000 files
    foreach ($src in [IO.Directory]::EnumerateFiles($old, "*", [IO.SearchOption]::AllDirectories)) {
        $n++
        if (($n % 500) -eq 0) { Assert-NotCancelled; Set-WorkProgress 0 0 "$n files checked" }
        $rel = $src.Substring($old.Length + 1)
        $dest = [IO.Path]::Combine($newFull, $rel)
        $mine = ($rel -eq "settings.json") -or ($rel -match '^Data[\\/]')
        if (-not $mine) {
            if ([IO.File]::Exists($dest)) { continue }                      # the release's copy wins
            if ($rel -match '\.(dll|exe|so|dylib|pdb)$') { continue }       # program files never carried
            if ($rel -notmatch '[\\/]' -and $rel -match '\.json$') { continue } # TazUO.deps/runtimeconfig etc.
        }
        $dir = [IO.Path]::GetDirectoryName($dest)
        if ($made.Add($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
        if ([IO.File]::Exists($dest)) { [IO.File]::SetAttributes($dest, [IO.FileAttributes]::Normal) }
        [IO.File]::Copy($src, $dest, $true)
    }
}

# ---- startup recovery ----------------------------------------------------

$ReadyMarkerName = ".uosmallz-ready.json"

function Write-ReadyMarker([string]$dir, [string]$tag, [string]$sha) {
    Write-Stamp (Join-Path $dir $ReadyMarkerName) $tag $sha
}

# A launch that finds no usable Client (killed between the two renames of
# a swap, or a half-deleted folder) puts one back before anything else.
# The rule:
#   1. Client.old wins when it has TazUO.exe: it is the client that already
#      ran on this PC (known good). The stamp still names it, because the
#      stamp is written only after a finished swap; the new version is
#      simply offered again.
#   2. Otherwise Client.new, but only when it is complete and verified: it
#      has TazUO.exe and the ready marker, which is written after the zip's
#      SHA256 check, the unpack and the copy of the player's files. Its
#      marker becomes the stamp.
#   3. Otherwise nothing can be done (the player re-runs install.bat).
# A Client folder without TazUO.exe is moved aside (Client.broken-<time>),
# never deleted, since it may hold the player's Data\.
# Returns "ok", "old", "new" or "none".
function Repair-ClientFolder([string]$root) {
    $p = Get-Paths $root
    if (Test-Path -LiteralPath $p.Exe) { return "ok" }
    $oldOk = Test-Path -LiteralPath (Join-Path $p.Old "TazUO.exe")
    $newMarker = $null
    if (Test-Path -LiteralPath (Join-Path $p.New "TazUO.exe")) {
        $newMarker = Read-Stamp (Join-Path $p.New $ReadyMarkerName)
        if ($newMarker -and [string]::IsNullOrWhiteSpace($newMarker.Sha256)) { $newMarker = $null }
    }
    if (-not $oldOk -and -not $newMarker) {
        Write-LaunchLog $root "recovery: no usable Client, Client.old or verified Client.new"
        return "none"
    }
    if (Test-Path -LiteralPath $p.Client) {
        $aside = "Client.broken-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        Rename-Item -LiteralPath $p.Client -NewName $aside
        Write-LaunchLog $root "recovery: Client had no TazUO.exe, moved to $aside"
    }
    if ($oldOk) {
        Rename-Item -LiteralPath $p.Old -NewName "Client"
        $pend = Read-Pending $p.Pending
        if ($pend) {
            if ($pend.PrevTag) { Write-Stamp $p.Stamp $pend.PrevTag $pend.PrevSha }
            Remove-Item -LiteralPath $p.Pending -Force -ErrorAction SilentlyContinue
        }
        Write-LaunchLog $root "recovery: restored Client.old (the last client that ran)"
        return "old"
    }
    Rename-Item -LiteralPath $p.New -NewName "Client"
    Write-Stamp $p.Stamp $newMarker.Tag $newMarker.Sha256
    Remove-Item -LiteralPath (Join-Path $p.Client $ReadyMarkerName) -Force -ErrorAction SilentlyContinue
    Write-LaunchLog $root "recovery: restored the verified Client.new ($($newMarker.Tag))"
    return "new"
}

# ---- unconfirmed update (client-pending.json) -----------------------------
# Written at swap time. Client.old is deleted only on a LATER run, after a
# launch of the new client was seen to start and stay up for
# $HealthySeconds. If the new client dies sooner, the player is offered the
# previous one back.

$HealthySeconds = 20

function Write-Pending([string]$path, [string]$tag, [string]$sha, $prev, [bool]$ok) {
    $pt = ""; $ps = ""
    if ($prev) { $pt = [string]$prev.Tag; $ps = [string]$prev.Sha256 }
    $obj = [ordered]@{ tag = $tag; sha256 = $sha; prev_tag = $pt; prev_sha256 = $ps; launched_ok = $ok; swapped = (Get-Date).ToString("s") }
    [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}

function Read-Pending([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        return @{ Tag = [string]$j.tag; Sha256 = [string]$j.sha256; PrevTag = [string]$j.prev_tag; PrevSha = [string]$j.prev_sha256; Ok = [bool]$j.launched_ok }
    } catch { return @{ Tag = ""; Sha256 = ""; PrevTag = ""; PrevSha = ""; Ok = $false } }
}

# Start of a run: an update whose launch was already seen healthy is
# final; Client.old and the marker go. Returns $true when it cleaned up.
function Confirm-PendingUpdate([string]$root) {
    $p = Get-Paths $root
    $pend = Read-Pending $p.Pending
    if ($null -eq $pend) { return $false }
    if (-not (Test-Path -LiteralPath $p.Old)) {
        # nothing left to protect (Client.old removed by hand): stop waiting
        Remove-Item -LiteralPath $p.Pending -Force
        Write-LaunchLog $root "update $($pend.Tag): no Client.old any more, pending marker dropped"
        return $true
    }
    if (-not $pend.Ok) { return $false }
    if (Test-Path -LiteralPath $p.Old) { Remove-TreeFast $p.Old }
    Remove-Item -LiteralPath $p.Pending -Force
    Write-LaunchLog $root "update $($pend.Tag) confirmed by a good launch: Client.old removed"
    return $true
}

# Did the client start and stay up? $proc from Start-Process -PassThru.
function Test-LaunchHealthy($proc, [int]$seconds = $HealthySeconds) {
    if ($null -eq $proc) { return $false }
    if (-not $proc.WaitForExit($seconds * 1000)) { return $true }   # still running
    return $false
}

function Set-PendingLaunchOk([string]$root) {
    $p = Get-Paths $root
    $pend = Read-Pending $p.Pending
    if ($null -eq $pend) { return }
    Write-Pending $p.Pending $pend.Tag $pend.Sha256 @{ Tag = $pend.PrevTag; Sha256 = $pend.PrevSha } $true
    Write-LaunchLog $root "update $($pend.Tag): client started and stayed up ${HealthySeconds}s; Client.old goes on the next start"
}

# Put the previous client back after a failed update. The player's files
# (settings.json, Data\) from the failed client are carried into it first,
# so nothing played since the swap is lost. The failed client is kept as
# Client.failed-<time>; its version is remembered as skipped.
function Restore-PreviousClient([string]$root) {
    $p = Get-Paths $root
    if (-not (Test-Path -LiteralPath (Join-Path $p.Old "TazUO.exe"))) { throw "no previous client (Client.old) to go back to" }
    $pend = Read-Pending $p.Pending
    $aside = $null
    if (Test-Path -LiteralPath $p.Client) {
        Copy-UserFiles $p.Client $p.Old
        $aside = "Client.failed-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        Rename-Item -LiteralPath $p.Client -NewName $aside
    }
    try {
        Rename-Item -LiteralPath $p.Old -NewName "Client"
    } catch {
        if ($aside) { Rename-Item -LiteralPath (Join-Path $root $aside) -NewName "Client" }
        throw
    }
    if ($pend) {
        if ($pend.PrevTag) { Write-Stamp $p.Stamp $pend.PrevTag $pend.PrevSha }
        if ($pend.Tag) { Set-Content -LiteralPath $p.Skip -Value "$($pend.Tag) $($pend.Sha256.ToLower())" -Encoding ASCII }
    }
    Remove-Item -LiteralPath $p.Pending -Force -ErrorAction SilentlyContinue
    Write-LaunchLog $root "rolled back to the previous client ($($pend.PrevTag)); $($pend.Tag) skipped"
}

# Unpack $zip into $dest (created) one entry at a time, so the progress bar and
# Cancel work (Expand-Archive and ExtractToDirectory give neither, and Expand-
# Archive is very slow on 15,000 files). "\" and "/" both separate; an entry
# that would land outside $dest is refused.
function Expand-ZipTo([string]$zip, [string]$dest) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $sep = [IO.Path]::DirectorySeparatorChar
    $destFull = (ConvertTo-FullPath $dest).TrimEnd('\', '/')
    [void][IO.Directory]::CreateDirectory($destFull)
    $prefix = $destFull + $sep
    $za = [IO.Compression.ZipFile]::OpenRead((ConvertTo-FullPath $zip))
    try {
        $all = 0L
        foreach ($e in $za.Entries) { $all += $e.Length }
        $done = 0L; $count = 0
        $made = New-Object 'System.Collections.Generic.HashSet[string]'
        $tick = [Diagnostics.Stopwatch]::StartNew()
        foreach ($e in $za.Entries) {
            Assert-NotCancelled
            $name = $e.FullName.Replace('\', '/')
            if ($name.StartsWith("/") -or $name -match '(^|/)\.\.(/|$)' -or $name -match '^[A-Za-z]:') { throw "the zip has an unsafe path ($name)" }
            $target = [IO.Path]::GetFullPath([IO.Path]::Combine($destFull, $name.Replace('/', $sep)))
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "the zip has an unsafe path ($name)" }
            if ($name.EndsWith("/")) { [void][IO.Directory]::CreateDirectory($target); continue }
            $d = [IO.Path]::GetDirectoryName($target)
            if ($made.Add($d)) { [void][IO.Directory]::CreateDirectory($d) }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            $done += $e.Length; $count++
            if ($tick.ElapsedMilliseconds -ge $ProgressMs) {
                $tick.Restart()
                Set-WorkProgress $done $all ("$(Format-MB $done) of $(Format-MB $all)")
            }
        }
    } finally { $za.Dispose() }
}

# Unpack $zip, carry user files, swap. Throws on failure after restoring
# the original Client folder. Returns nothing on success.
function Install-ClientUpdate([string]$root, [string]$zip, [string]$expectedSha, [string]$tag) {
    $p = Get-Paths $root
    Set-WorkStatus "Checking the download..."
    if (-not (Test-Sha256 $zip $expectedSha)) {
        throw "SHA256 mismatch for the downloaded client (expected $expectedSha)"
    }
    Set-WorkStatus "Unpacking the new client..."
    if (Test-Path -LiteralPath $p.New) { Remove-TreeFast $p.New }
    try {
        Expand-ZipTo $zip $p.New
        # a zip with one top folder: use what is inside it
        $top = @(Get-ChildItem -LiteralPath $p.New -Force)
        if ($top.Count -eq 1 -and $top[0].PSIsContainer -and -not (Test-Path -LiteralPath (Join-Path $p.New "TazUO.exe"))) {
            $inner = $top[0].FullName
            foreach ($c in Get-ChildItem -LiteralPath $inner -Force) { Move-Item -LiteralPath $c.FullName -Destination $p.New }
            Remove-TreeFast $inner
        }
    } catch {
        # a half-unpacked Client.new (disk full, antivirus, Cancel) never stays behind
        Remove-TreeFast $p.New -Quiet
        throw
    }
    Complete-ClientUpdate $root $expectedSha $tag
}

# Client.new holds the new client's program files (unpacked from the zip, or
# put together from the installed client and the changed files): the player's
# files go in, it is marked ready, and it is swapped in. Throws on failure
# after restoring the original Client folder.
function Complete-ClientUpdate([string]$root, [string]$expectedSha, [string]$tag) {
    $p = Get-Paths $root
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $p.New "TazUO.exe"))) {
            throw "the downloaded client has no TazUO.exe"
        }
        # The player's files never come from a zip: a settings.json or Data\
        # shipped by mistake is dropped before the player's are copied in.
        foreach ($mine in @("settings.json", "Data")) {
            $m = Join-Path $p.New $mine
            if (Test-Path -LiteralPath $m) { Remove-TreeFast $m }
        }
        if (Test-Path -LiteralPath $p.Client) { Copy-UserFiles $p.Client $p.New }
        # Last point where Cancel is honoured: from the ready marker on, the
        # swap runs to its end (or rolls back), never half-way.
        Assert-NotCancelled
        Set-WorkCancelable $false
        Set-WorkStatus "Finishing the update..."
        # Client.new is now complete and its zip verified: say so, for the
        # startup recovery (Repair-ClientFolder) if we are killed mid-swap.
        Write-ReadyMarker $p.New $tag $expectedSha
    } catch {
        # a half-unpacked Client.new (disk full, antivirus, Cancel) never stays behind
        Remove-TreeFast $p.New -Quiet
        throw
    }

    # An older Client.old (from an update already confirmed by a good launch,
    # or a re-install) makes way. The launcher never gets here while an
    # update is still unconfirmed (see Invoke-Launcher).
    if (Test-Path -LiteralPath $p.Old) { Remove-TreeFast $p.Old }
    $prev = Read-Stamp $p.Stamp
    $movedOld = $false
    try {
        if (Test-Path -LiteralPath $p.Client) {
            Rename-Item -LiteralPath $p.Client -NewName "Client.old"
            $movedOld = $true
        }
        Rename-Item -LiteralPath $p.New -NewName "Client"
        Write-Stamp $p.Stamp $tag $expectedSha
        Remove-Item -LiteralPath (Join-Path $p.Client $ReadyMarkerName) -Force -ErrorAction SilentlyContinue
        # Client.old stays until this client has started and kept running
        # once (Confirm-PendingUpdate on a later run).
        if ($movedOld) { Write-Pending $p.Pending $tag $expectedSha $prev $false }
    } catch {
        $err = $_
        # roll back: put the old client back exactly as it was
        try {
            if ($movedOld) {
                if (Test-Path -LiteralPath $p.Client) {
                    if (Test-Path -LiteralPath $p.New) { Remove-TreeFast $p.Client }
                    else { Rename-Item -LiteralPath $p.Client -NewName "Client.new" }
                }
                Rename-Item -LiteralPath $p.Old -NewName "Client"
            }
        } catch { }
        Remove-TreeFast $p.New -Quiet
        throw $err
    }
}

# ---- updating only what changed -------------------------------------------
# A release also publishes UOSmallz-Client-win-x64.files.json: every file of the
# client zip with its size and SHA-256, itself checked against SHA256SUMS.txt.
# The launcher hashes the installed client and fetches only the files that
# differ, straight out of the release zip on GitHub by byte range: the zip's
# central directory (at its end) says where each file is. A client update is
# then a few MB instead of the whole zip (v4 -> v5 -> v6 changed 8 to 10 of 764
# files, about 9 MB of 90). Every fetched file is checked against the list.
# Anything unexpected (no list, no byte ranges, zip64, a mismatch) throws, and
# the launcher downloads the full zip as before.

$DeltaMaxShare = 0.6   # more than this share of the client changed: the full zip
# Each changed file is its own small request (local file header, then the
# data): v9's 14,027 icons took about 15 minutes at roughly 15 files/s, where
# the whole 133 MB zip takes a minute or two. So the changed-files update is
# also skipped when it would take longer than the full zip by this estimate
# (seconds per file plus bytes at the assumed speed, against the zip's bytes
# at that speed), and always above $DeltaMaxFiles files. A higher assumed
# speed favours the full zip, so it is set on the fast side.
$DeltaMaxFiles      = 2000
$DeltaSecPerFile    = 0.07          # measured: ~15 files/s
$DeltaAssumedBps    = 4MB           # bytes per second


# The file list's JSON -> @{ Tag; Files = @(@{ Path; Size; Sha256 }) }. Paths are
# relative, with "/", and may not climb out of the client folder.
function Read-ClientManifest([string]$text) {
    $j = $text | ConvertFrom-Json
    $files = New-Object Collections.ArrayList   # += on an array is quadratic: 15,000 entries
    foreach ($f in @($j.files)) {
        $path = ([string]$f.path).Replace('\', '/')
        $sha = ([string]$f.sha256).ToLower()
        if ($path -eq "" -or $path.StartsWith("/") -or $path -match '(^|/)\.\.(/|$)' -or $path.Contains(":") -or $sha -notmatch '^[0-9a-f]{64}$') {
            throw "the file list has a bad entry ($path)"
        }
        [void]$files.Add(@{ Path = $path; Size = [long]$f.size; Sha256 = $sha })
    }
    $files = [object[]]$files.ToArray()
    if ($files.Count -eq 0) { throw "the file list is empty" }
    if (-not ($files | Where-Object { $_.Path -eq "TazUO.exe" })) { throw "the file list has no TazUO.exe" }
    return @{ Tag = [string]$j.tag; Files = $files }
}

function Get-LocalPath([string]$dir, [string]$rel) { return Join-Path $dir ($rel.Replace('/', [string][IO.Path]::DirectorySeparatorChar)) }

# The files whose installed copy is missing or different. One stat per file
# says missing / wrong size; a file of the right size is compared by SHA-256,
# taken from $cache (see Read-HashCache) while its size and mtime are what they
# were when it was hashed, else read - on several threads - and entered in
# $cache. $cache is changed in place (stale rows dropped); saving it is up to the
# caller. No $cache = hash everything, as before.
function Get-ChangedFiles([string]$clientDir, $manifest, $cache = $null) {
    if ($null -eq $cache) { $cache = @{} }
    $files = $manifest.Files
    $count = @($files).Count
    Set-WorkStatus "Checking the installed files..."
    $verdict = New-Object 'int[]' $count      # 0 same, 1 changed, 2 to hash
    $toHash = New-Object Collections.ArrayList
    $cached = 0
    for ($i = 0; $i -lt $count; $i++) {
        if (($i % 250) -eq 0) { Assert-NotCancelled; Set-WorkProgress $i $count "$i of $count files" }
        $f = $files[$i]
        $local = Get-LocalPath $clientDir $f.Path
        $fi = New-Object IO.FileInfo $local
        if (-not $fi.Exists -or $fi.Length -ne $f.Size) { $verdict[$i] = 1; continue }
        $e = $cache[$f.Path]
        if ($e -and $e[0] -eq $fi.Length -and $e[1] -eq $fi.LastWriteTimeUtc.Ticks) {
            $cached++
            if ($e[2] -ne $f.Sha256) { $verdict[$i] = 1 }
            continue
        }
        $verdict[$i] = 2
        [void]$toHash.Add(@{ Key = $f.Path; Path = $local; Index = $i })
    }
    if ($toHash.Count -gt 0) {
        Set-WorkStatus "Checking the installed files ($($toHash.Count) not seen before)..."
        $byKey = @{}
        foreach ($h in $toHash) { $byKey[$h.Key] = $h.Index }
        foreach ($r in (Invoke-FileWorkers $toHash.ToArray() $HashWorker $null)) {
            $i = $byKey[$r.Key]
            if ($r.Sha -ne $files[$i].Sha256) { $verdict[$i] = 1 } else { $verdict[$i] = 0 }
            if ($r.Stable) { Set-CacheEntry $cache $r.Key $r.Size $r.Ticks $r.Sha } else { $cache.Remove($r.Key) }
        }
    }
    # rows for files the release no longer lists are of no use
    $keep = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in $files) { [void]$keep.Add($f.Path) }
    foreach ($k in @($cache.Keys)) { if (-not $keep.Contains($k)) { $cache.Remove($k) } }
    $changed = New-Object Collections.ArrayList
    for ($i = 0; $i -lt $count; $i++) { if ($verdict[$i] -ne 0) { [void]$changed.Add($files[$i]) } }
    $script:LastScan = @{ Files = $count; Cached = $cached; Hashed = $toHash.Count; Changed = $changed.Count }
    return , ([object[]]$changed.ToArray())
}

# Byte ranges of a release asset. GitHub answers the download address with a
# redirect to a signed address that serves ranges (206); it is followed once.
# Returns @{ Total; Read } where Read is { param([long]$from, [int]$count) }
# returning exactly that many bytes.
function New-RangeReader([string]$url) {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.UserAgent = "UOSmallz-launcher"
    $req.AllowAutoRedirect = $true
    $req.Timeout = 30000
    $req.ReadWriteTimeout = 30000
    $req.AddRange([long]0, [long]0)
    $resp = $req.GetResponse()
    try {
        if ([int]$resp.StatusCode -ne 206) { throw "the download server does not answer byte ranges" }
        if ([string]$resp.Headers["Content-Range"] -notmatch '/(\d+)\s*$') { throw "the download server sent no size" }
        $total = [long]$Matches[1]
        $final = $resp.ResponseUri.AbsoluteUri
    } finally { $resp.Dispose() }
    $read = {
        param([long]$from, [int]$count)
        $r = [Net.HttpWebRequest]::Create($final)
        $r.UserAgent = "UOSmallz-launcher"
        $r.Timeout = 30000
        $r.ReadWriteTimeout = 30000
        $r.AddRange($from, $from + $count - 1)
        $resp = $r.GetResponse()
        try {
            if ([int]$resp.StatusCode -ne 206) { throw "the download server did not answer a byte range" }
            $s = $resp.GetResponseStream()
            $buf = New-Object byte[] $count
            $got = 0
            while ($got -lt $count) {
                $n = $s.Read($buf, $got, $count - $got)
                if ($n -le 0) { throw "the download stopped early" }
                $got += $n
            }
        } finally { $resp.Dispose() }
        return , $buf
    }.GetNewClosure()
    return @{ Total = $total; Read = $read }
}

# The zip's central directory: entry name ("/" separators) -> @{ Method; Comp;
# Size; Offset }.
function Get-ZipDirectory([long]$total, [scriptblock]$read) {
    $tailLen = [int][Math]::Min($total, 65557L)
    [byte[]]$tail = & $read ($total - $tailLen) $tailLen
    $eocd = -1
    for ($i = $tail.Length - 22; $i -ge 0; $i--) {
        if ([BitConverter]::ToUInt32($tail, $i) -eq 0x06054b50) { $eocd = $i; break }
    }
    if ($eocd -lt 0) { throw "the zip has no end of central directory" }
    $count = [BitConverter]::ToUInt16($tail, $eocd + 10)
    $cdSize = [BitConverter]::ToUInt32($tail, $eocd + 12)
    $cdOff = [BitConverter]::ToUInt32($tail, $eocd + 16)
    if ($count -eq 0xFFFF -or $cdSize -eq 0xFFFFFFFF -or $cdOff -eq 0xFFFFFFFF) { throw "zip64 is not read here" }
    [byte[]]$cd = & $read ([long]$cdOff) ([int]$cdSize)
    $entries = @{}
    $o = 0
    for ($n = 0; $n -lt $count; $n++) {
        if ([BitConverter]::ToUInt32($cd, $o) -ne 0x02014b50) { throw "the zip's directory is damaged" }
        $nl = [BitConverter]::ToUInt16($cd, $o + 28)
        $name = [Text.Encoding]::UTF8.GetString($cd, $o + 46, $nl).Replace('\', '/')
        $entries[$name] = @{
            Method = [int][BitConverter]::ToUInt16($cd, $o + 10)
            Comp   = [long][BitConverter]::ToUInt32($cd, $o + 20)
            Size   = [long][BitConverter]::ToUInt32($cd, $o + 24)
            Offset = [long][BitConverter]::ToUInt32($cd, $o + 42)
        }
        $o += 46 + $nl + [BitConverter]::ToUInt16($cd, $o + 30) + [BitConverter]::ToUInt16($cd, $o + 32)
    }
    return $entries
}

# One file's bytes out of the zip (stored or deflated).
function Read-ZipEntry($entry, [string]$name, [scriptblock]$read) {
    if ($entry.Method -ne 0 -and $entry.Method -ne 8) { throw "$name is packed in a way this launcher does not read ($($entry.Method))" }
    [byte[]]$head = & $read $entry.Offset 30
    if ([BitConverter]::ToUInt32($head, 0) -ne 0x04034b50) { throw "the zip's header for $name is damaged" }
    $skip = 30 + [BitConverter]::ToUInt16($head, 26) + [BitConverter]::ToUInt16($head, 28)
    [byte[]]$data = New-Object byte[] 0
    if ($entry.Comp -gt 0) { $data = & $read ($entry.Offset + $skip) ([int]$entry.Comp) }
    if ($entry.Method -eq 0) { return , $data }
    $in = New-Object IO.MemoryStream (, $data)
    $z = New-Object IO.Compression.DeflateStream ($in, [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream
    try { $z.CopyTo($out) } finally { $z.Dispose() }
    return , $out.ToArray()
}

function Get-BytesSha256([byte[]]$bytes) {
    $h = [Security.Cryptography.SHA256]::Create()
    try { return (($h.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "") } finally { $h.Dispose() }
}

# Client.new from the installed client's unchanged files and the changed ones
# out of the zip, then the usual swap (Complete-ClientUpdate). Returns the bytes
# fetched. Throws, leaving no Client.new, on anything unexpected. The unchanged
# files are copied first, in parallel, one [IO.File]::Copy each into folders made
# once; then the changed ones are fetched. $cache (optional, from
# Get-ChangedFiles) gets a row per file of the new client and is saved after
# the swap, so the next update starts from a warm cache.
function Install-ClientDelta([string]$root, $manifest, $changed, [long]$total, [scriptblock]$read, [string]$zipSha, [string]$tag, $cache = $null) {
    $p = Get-Paths $root
    if (Test-Path -LiteralPath $p.New) { Remove-TreeFast $p.New }
    $fetched = 0L
    $rows = @{}
    try {
        $dir = Get-ZipDirectory $total $read
        $want = @{}
        foreach ($f in $changed) {
            if ($null -eq $dir[$f.Path]) { throw "$($f.Path) is not in the release zip" }
            $want[$f.Path] = $true
        }
        $newFull = ConvertTo-FullPath $p.New
        $clientFull = ConvertTo-FullPath $p.Client
        $dirs = New-Object 'System.Collections.Generic.HashSet[string]'
        $copy = New-Object Collections.ArrayList
        foreach ($f in $manifest.Files) {
            $dest = Get-LocalPath $newFull $f.Path
            [void]$dirs.Add([IO.Path]::GetDirectoryName($dest))
            if (-not $want.ContainsKey($f.Path)) {
                [void]$copy.Add(@{ Key = $f.Path; Src = (Get-LocalPath $clientFull $f.Path); Dst = $dest; Size = $f.Size; Sha = $f.Sha256 })
            }
        }
        foreach ($d in $dirs) { [void][IO.Directory]::CreateDirectory($d) }
        Set-WorkStatus "Copying the $($copy.Count) files that did not change..."
        foreach ($r in (Invoke-FileWorkers $copy.ToArray() $CopyWorker $null)) { if ($r.Stable) { $rows[$r.Key] = $r } }
        $n = 0
        foreach ($f in $changed) {
            Assert-NotCancelled
            $n++
            Set-WorkStatus "Downloading the changed files ($n of $(@($changed).Count))..."
            Set-WorkProgress ($n - 1) @($changed).Count $f.Path
            $e = $dir[$f.Path]
            [byte[]]$bytes = Read-ZipEntry $e $f.Path $read
            $fetched += $e.Comp
            if ($bytes.Length -ne $f.Size -or (Get-BytesSha256 $bytes) -ne $f.Sha256) { throw "$($f.Path) from the zip does not match the file list" }
            $dest = Get-LocalPath $newFull $f.Path
            [IO.File]::WriteAllBytes($dest, $bytes)
            $fi = New-Object IO.FileInfo $dest
            $ticks = $fi.LastWriteTimeUtc.Ticks
            # written here from bytes just checked against the list: no need for the 2 s caution
            $rows[$f.Path] = @{ Size = $fi.Length; Ticks = $ticks; Sha = $f.Sha256 }
        }
    } catch {
        Remove-TreeFast $p.New -Quiet
        throw
    }
    Complete-ClientUpdate $root $zipSha $tag
    if ($null -ne $cache) {
        foreach ($k in $rows.Keys) { Set-CacheEntry $cache $k $rows[$k].Size $rows[$k].Ticks $rows[$k].Sha }
        [void](Write-HashCache $p.HashCache $cache)
    }
    return $fetched
}

# The release's file list (checked against its SHA-256), what changed, and
# the update from those files only. Returns the bytes fetched; throws when the
# full download should be used instead.
# Why the changed-files update should not be used for $count files of $bytes
# bytes when the full zip is $zipBytes (0 = not known yet), or $null when it
# is the faster way. UOSMALLZ_DELTA_MAX_FILES overrides $DeltaMaxFiles.
function Get-DeltaRefusal([int]$count, [long]$bytes, [long]$zipBytes) {
    $max = $DeltaMaxFiles
    $env = [Environment]::GetEnvironmentVariable("UOSMALLZ_DELTA_MAX_FILES")
    if ($env -match '^\d{1,7}$') { $max = [int]$env }
    if ($count -gt $max) { return "$count files changed (more than $max)" }
    if ($zipBytes -gt 0) {
        $deltaSec = $count * $DeltaSecPerFile + $bytes / $DeltaAssumedBps
        $fullSec = $zipBytes / $DeltaAssumedBps
        if ($deltaSec -gt $fullSec) {
            return ("{0} files would take about {1:N0} s one by one, the full zip about {2:N0} s" -f $count, $deltaSec, $fullSec)
        }
    }
    return $null
}

function Invoke-ClientDelta([string]$root, $info) {
    $p = Get-Paths $root
    if (-not $info.ManifestUrl -or -not $info.ManifestSha256) { throw "the release has no checked file list" }
    if (-not (Test-Path -LiteralPath $p.Exe)) { throw "no installed client to update from" }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("uosmallz-files-" + [Guid]::NewGuid().ToString("N") + ".json")
    try {
        Save-UrlWithTimeout $info.ManifestUrl $tmp 30 30 120
        if (-not (Test-Sha256 $tmp $info.ManifestSha256)) { throw "the file list does not match its SHA-256" }
        $manifest = Read-ClientManifest ([IO.File]::ReadAllText($tmp))
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    if ($manifest.Tag -and $manifest.Tag -ne $info.Tag) { throw "the file list is for $($manifest.Tag), not $($info.Tag)" }
    # hashes of the installed files, kept between updates (see Read-HashCache)
    $scanTimer = [Diagnostics.Stopwatch]::StartNew()
    $cache = Read-HashCache $p.HashCache
    $changed = Get-ChangedFiles $p.Client $manifest $cache
    [void](Write-HashCache $p.HashCache $cache)   # a scan that is followed by a refusal or a failure still pays off next time
    $scan = $script:LastScan
    Write-LaunchLog $root ("update $($info.Tag): checked $($scan.Files) files in {0:N1} s ($($scan.Cached) from the hash cache, $($scan.Hashed) hashed), $($scan.Changed) changed" -f $scanTimer.Elapsed.TotalSeconds)
    $all = 0L; $chg = 0L
    foreach ($f in $manifest.Files) { $all += $f.Size }
    foreach ($f in $changed) { $chg += $f.Size }
    if ($all -gt 0 -and $chg / $all -gt $DeltaMaxShare) { throw "most of the client changed" }
    $why = Get-DeltaRefusal $changed.Count $chg 0
    if ($why) { throw $why }
    $reader = New-RangeReader $info.Url
    $why = Get-DeltaRefusal $changed.Count $chg $reader.Total
    if ($why) { throw $why }
    return Install-ClientDelta $root $manifest $changed $reader.Total $reader.Read $info.Sha256 $info.Tag $cache
}

# ---- the launcher updates itself -------------------------------------------
# At each start: when installer/update-check.ps1 on main carries a higher
# $LauncherVersion than this one, it and launch.vbs (from that same commit, so
# they belong together) replace the installed ones, after the new script is
# checked to parse. Launcher fixes then reach every player without a client
# release or a new installer. Same source and trust as the installer itself:
# this public repo, over HTTPS.

function Get-LauncherVersionOf([string]$text) {
    if ($text -match '(?m)^\$LauncherVersion\s*=\s*(\d+)') { return [int]$Matches[1] }
    return 0
}

function Test-LauncherScript([string]$text) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
    return ($null -eq $errors -or $errors.Count -eq 0) -and $text.Contains("function Invoke-Launcher")
}

# Returns $true when the launcher files were replaced (the caller starts the
# new one). Silent on any failure: the installed launcher goes on.
function Update-LauncherSelf([string]$root) {
    $h = Get-WebHeaders
    $h["Accept"] = "application/vnd.github.sha"
    # Windows PowerShell hands this media type back as bytes, not text.
    $body = (Invoke-WebRequest -Uri "https://api.github.com/repos/$Repo/commits/main" -Headers $h -TimeoutSec $TimeoutSec -UseBasicParsing).Content
    if ($body -is [byte[]]) { $body = [Text.Encoding]::ASCII.GetString($body) }
    $commit = ([string]$body).Trim()
    if ($commit -notmatch '^[0-9a-f]{40}$') { throw "unexpected answer for the latest commit" }
    $base = "https://raw.githubusercontent.com/$Repo/$commit/installer/"
    $tmpPs1 = Join-Path $root "update-check.ps1.download"
    $tmpVbs = Join-Path $root "launch.vbs.download"
    try {
        Save-UrlWithTimeout ($base + "update-check.ps1") $tmpPs1 15 15 60
        $text = [IO.File]::ReadAllText($tmpPs1)
        $v = Get-LauncherVersionOf $text
        if ($v -le $LauncherVersion) { return $false }
        if (-not (Test-LauncherScript $text)) { throw "launcher $v on main does not parse; not installed" }
        Save-UrlWithTimeout ($base + "launch.vbs") $tmpVbs 15 15 60
        if (-not ([IO.File]::ReadAllText($tmpVbs)).Contains("update-check.ps1")) { throw "launch.vbs on main is not the launcher; not installed" }
        Move-Item -LiteralPath $tmpVbs -Destination (Join-Path $root "launch.vbs") -Force
        Move-Item -LiteralPath $tmpPs1 -Destination (Join-Path $root "update-check.ps1") -Force
        Write-LaunchLog $root "launcher updated itself: $LauncherVersion -> $v (commit $($commit.Substring(0, 7)))"
        return $true
    } finally {
        Remove-Item -LiteralPath $tmpPs1, $tmpVbs -Force -ErrorAction SilentlyContinue
    }
}

# The client zip (checked against the release's SHA-256) carries this launcher
# in launcher\: after an update, the launcher files in the install folder are
# replaced by those when they are newer, so a client release brings launcher
# changes to an install that has not updated itself. Never an older or equal
# one: the launcher may already have updated itself past that release. This
# run goes on with the code it already loaded; the next start uses the new one.
function Update-LauncherFiles([string]$root) {
    $p = Get-Paths $root
    $src = Join-Path $p.Client "launcher"
    $changed = @()
    $zipPs1 = Join-Path $src "update-check.ps1"
    $havePs1 = Join-Path $root "update-check.ps1"
    if ((Test-Path -LiteralPath $zipPs1) -and (Test-Path -LiteralPath $havePs1) -and
        (Get-LauncherVersionOf ([IO.File]::ReadAllText($zipPs1))) -le (Get-LauncherVersionOf ([IO.File]::ReadAllText($havePs1)))) {
        return $changed
    }
    foreach ($f in @("update-check.ps1", "launch.vbs")) {
        $from = Join-Path $src $f
        $to = Join-Path $root $f
        if (-not (Test-Path -LiteralPath $from)) { continue }
        if ((Test-Path -LiteralPath $to) -and (Get-Sha256 $from) -eq (Get-Sha256 $to)) { continue }
        Copy-Item -LiteralPath $from -Destination "$to.new" -Force
        Move-Item -LiteralPath "$to.new" -Destination $to -Force
        $changed += $f
    }
    return $changed
}

# ---- client settings (used by install.ps1) -------------------------------

# Create settings.json, or fill in only what an existing one lacks. A
# player's own ip / port / window / fps are never overwritten. The UO data
# folder is also set when the existing one no longer exists on disk.
# Returns the names of the keys it set ("(new file)" for a fresh file).
function Merge-ClientSettings([string]$path, $defaults) {
    $enc = New-Object Text.UTF8Encoding($false)
    $obj = $null
    if (Test-Path -LiteralPath $path) {
        try { $obj = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $obj = $null }
        if ($null -eq $obj) {
            $bak = "$path.unreadable-" + (Get-Date -Format "yyyyMMdd-HHmmss")
            Copy-Item -LiteralPath $path -Destination $bak -Force
        }
    }
    if ($null -eq $obj) {
        [IO.File]::WriteAllText($path, ($defaults | ConvertTo-Json -Depth 10), $enc)
        return @("(new file)")
    }
    $changed = @()
    foreach ($k in @("ip", "port", "ultimaonlinedirectory", "clientversion")) {
        if (-not $defaults.Contains($k)) { continue }
        $has = $obj.PSObject.Properties.Name -contains $k
        $cur = $null
        if ($has) { $cur = $obj.$k }
        $missing = (-not $has) -or ($null -eq $cur) -or ([string]$cur -eq "") -or ($k -eq "port" -and [int]$cur -eq 0)
        if ($k -eq "ultimaonlinedirectory" -and -not $missing) {
            $missing = -not (Test-Path -LiteralPath ([string]$cur))
        }
        if ($missing) {
            if ($has) { $obj.$k = $defaults[$k] } else { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] }
            $changed += $k
        }
    }
    if ($changed.Count -gt 0) {
        [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 10), $enc)
    }
    return $changed
}

# ---- HD art --------------------------------------------------------------
# The pack lives in HDArt beside Client (the client reads it from there), so a
# client update never copies it. hdart-version.json holds the SHA-256 of the
# pack installed; hdart-skipped.txt the one the player said not to ask about.

# Only a client with the HD art patch (patches/client/0003) draws the pack at
# the art's own size; an older one would draw every item twice as big.
function Test-ClientDrawsHdArt([string]$clientDir) {
    $dll = Join-Path $clientDir "ClassicUO.Renderer.dll"
    if (-not (Test-Path -LiteralPath $dll)) { return $false }
    return [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($dll)).Contains("ScaledTexture2D")
}

# Where the files hd-art.json lists come from: "release": "hd-art-N" -> that
# release of $Repo; no "release" -> the old shard server; anything else ->
# $null (nothing is offered).
function Get-HdArtBaseUrl($manifest) {
    if ($null -eq $manifest) { return $null }
    $rel = $null
    if ($manifest.PSObject.Properties.Name -contains "release") { $rel = [string]$manifest.release }
    if ($null -eq $rel) { return $HdArtLegacyUrl }
    if ($rel -cmatch '^hd-art-[0-9]{1,6}$') { return "https://github.com/$Repo/releases/download/$rel/" }
    return $null
}

# A partial download's name carries the SHA-256 it is meant to have, so a
# change in hd-art.json never resumes into the old file.
function Get-HdPartPath([string]$dest, [string]$sha) { return "$dest.$($sha.Substring(0, 12)).part" }

# hd-art.json { "release", "file", "size", "sha256" } -> what to download, or
# $null when it is missing or not what it should be.
function Get-HdArtInfo($manifest) {
    if ($null -eq $manifest) { return $null }
    $file = [string]$manifest.file
    $sha = ([string]$manifest.sha256).ToLower()
    $size = 0L
    try { $size = [long]$manifest.size } catch { return $null }
    $base = Get-HdArtBaseUrl $manifest
    if ($null -eq $base) { return $null }
    if ($file -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$' -or $sha -notmatch '^[0-9a-f]{64}$' -or $size -le 0) { return $null }
    return @{ File = $file; Url = $base + $file; Size = $size; Sha256 = $sha }
}

function Read-HdArtStamp([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return ([string](Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).sha256).ToLower() } catch { return $null }
}

function Write-HdArtStamp([string]$path, [string]$sha) {
    $json = [ordered]@{ sha256 = $sha.ToLower(); installed = (Get-Date).ToString("s") } | ConvertTo-Json
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
}

# Check the zip, unpack it beside the installed pack, then swap. On any failure
# the pack that was there stays. HDArt\anim (the creatures) moves across.
function Install-HdArt([string]$root, [string]$zip, [string]$expectedSha) {
    $p = Get-Paths $root
    Set-WorkStatus "Checking the HD art..."
    if (-not (Test-Sha256 $zip $expectedSha)) { throw "the download does not match hd-art.json (SHA-256)" }
    Set-WorkStatus "Unpacking the HD art..."
    foreach ($d in @($p.HdArtNew, $p.HdArtOld)) {
        if (Test-Path -LiteralPath $d) { Remove-TreeFast $d }
    }
    try {
        Expand-ZipTo $zip $p.HdArtNew
        if (-not (Test-Path -LiteralPath (Join-Path $p.HdArtNew "art"))) { throw "the pack has no art folder" }
    } catch {
        $err = $_
        Remove-TreeFast $p.HdArtNew -Quiet
        throw $err
    }
    Set-WorkCancelable $false   # the swap below is never interrupted
    Set-WorkStatus "Finishing the HD art..."

    $animNew = Join-Path $p.HdArtNew "anim"
    $movedAnim = $false
    if ((Test-Path -LiteralPath $p.HdAnim) -and -not (Test-Path -LiteralPath $animNew)) {
        Move-Item -LiteralPath $p.HdAnim -Destination $animNew
        $movedAnim = $true
    }
    try {
        if (Test-Path -LiteralPath $p.HdArt) { Rename-Item -LiteralPath $p.HdArt -NewName "HDArt.old" }
        Rename-Item -LiteralPath $p.HdArtNew -NewName "HDArt"
    } catch {
        $err = $_
        if ((Test-Path -LiteralPath $p.HdArtOld) -and -not (Test-Path -LiteralPath $p.HdArt)) { Rename-Item -LiteralPath $p.HdArtOld -NewName "HDArt" }
        if ($movedAnim -and (Test-Path -LiteralPath $animNew)) { Move-Item -LiteralPath $animNew -Destination $p.HdAnim }
        throw $err
    }
    Write-HdArtStamp $p.HdArtStamp $expectedSha
    Remove-TreeFast $p.HdArtOld -Quiet
}

# ---- HD creatures --------------------------------------------------------
# Creatures, people and clothes: .uoanim packs in HDArt\anim, which the client
# (HdAnimations) finds by the pixels of each frame. hd-art.json lists them under
# "creatures" with size and SHA-256; several files, so a broken download costs
# only one. hdanim-version.json holds the set installed, hdanim-skipped.txt the
# set the player said not to ask about.

function Test-ClientDrawsHdCreatures([string]$clientDir) {
    $dll = Join-Path $clientDir "ClassicUO.Assets.dll"
    if (-not (Test-Path -LiteralPath $dll)) { return $false }
    return [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($dll)).Contains("HdAnimations")
}

# hd-art.json "creatures": { "files": [ { "file", "size", "sha256" } ] } -> the
# files, their total size and an id for the set; $null when missing or not
# what it should be.
function Get-HdCreaturesInfo($manifest) {
    if ($null -eq $manifest -or $null -eq $manifest.creatures) { return $null }
    $base = Get-HdArtBaseUrl $manifest
    if ($null -eq $base) { return $null }
    $files = @()
    foreach ($f in @($manifest.creatures.files)) {
        if ($null -eq $f) { continue }
        $name = [string]$f.file
        $sha = ([string]$f.sha256).ToLower()
        $size = 0L
        try { $size = [long]$f.size } catch { return $null }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.uoanim$' -or $sha -notmatch '^[0-9a-f]{64}$' -or $size -le 0) { return $null }
        $files += , @{ File = $name; Url = $base + $name; Size = $size; Sha256 = $sha }
    }
    if ($files.Count -eq 0) { return $null }
    $total = 0L
    foreach ($f in $files) { $total += $f.Size }
    $joined = [Text.Encoding]::UTF8.GetBytes((($files | ForEach-Object { $_.Sha256 }) -join ","))
    $hasher = [Security.Cryptography.SHA256]::Create()
    $id = (($hasher.ComputeHash($joined) | ForEach-Object { $_.ToString("x2") }) -join "")
    $hasher.Dispose()
    return @{ Files = $files; Size = $total; Id = $id }
}

# Each file into HDArt\anim: kept when it is already there and right, else
# downloaded beside it as .part, checked, and moved in. Files the set no longer
# names go once all of it is in. $onFile gets (index, count, info) before each
# download. Throws on the first failure; what is in place stays.
function Install-HdCreatures([string]$root, $info, [scriptblock]$onFile = $null) {
    $p = Get-Paths $root
    New-Item -ItemType Directory -Path $p.HdAnim -Force | Out-Null
    # 1 GB files: their hashes are kept (size + mtime) so a part that is in place
    # is not read again on every offer
    $cache = Read-HashCache $p.HdAnimHashCache
    for ($i = 0; $i -lt $info.Files.Count; $i++) {
        $f = $info.Files[$i]
        $dest = Join-Path $p.HdAnim $f.File
        Assert-NotCancelled
        Set-WorkStatus "Checking the HD creatures, part $($i + 1) of $($info.Files.Count)..."
        if (Test-FileMatchesCached $cache $f.File $dest $f.Size $f.Sha256) { continue }
        if ($onFile) { & $onFile ($i + 1) $info.Files.Count $f }
        $part = Get-HdPartPath $dest $f.Sha256
        Set-WorkStatus "Downloading the HD creatures, part $($i + 1) of $($info.Files.Count) ($(Format-MB $f.Size))..."
        Save-UrlWithTimeout $f.Url $part 30 60 14400 -Resume
        if ((Get-Item -LiteralPath $part).Length -lt $f.Size) { throw "$($f.File) broke off; the rest is fetched next time" }
        Set-WorkStatus "Checking the HD creatures, part $($i + 1) of $($info.Files.Count)..."
        if (-not (Test-Sha256 $part $f.Sha256)) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            throw "$($f.File) does not match hd-art.json (SHA-256)"
        }
        Move-Item -LiteralPath $part -Destination $dest -Force
        $fi = New-Object IO.FileInfo (ConvertTo-FullPath $dest)
        if (([DateTime]::UtcNow.Ticks - $fi.LastWriteTimeUtc.Ticks) -gt $HashRacyTicks) {
            Set-CacheEntry $cache $f.File $fi.Length $fi.LastWriteTimeUtc.Ticks $f.Sha256
        } else { $cache.Remove($f.File) }
        [void](Write-HashCache $p.HdAnimHashCache $cache)
    }
    $keep = @($info.Files | ForEach-Object { $_.File })
    Get-ChildItem -LiteralPath $p.HdAnim -File | Where-Object { $keep -notcontains $_.Name } | Remove-Item -Force
    foreach ($k in @($cache.Keys)) { if ($keep -notcontains $k) { $cache.Remove($k) } }
    [void](Write-HashCache $p.HdAnimHashCache $cache)
    Write-HdArtStamp $p.HdAnimStamp $info.Id
}

function Invoke-HdCreatures([string]$root, $manifest) {
    $p = Get-Paths $root
    if (-not (Test-ClientDrawsHdCreatures $p.Client)) { return }   # the client update brings that first
    $info = Get-HdCreaturesInfo $manifest
    if ($null -eq $info) { return }   # no creatures in hd-art.json (yet)
    if ((Read-HdArtStamp $p.HdAnimStamp) -eq $info.Id) { return }
    if ((Test-Path -LiteralPath $p.HdAnimSkip) -and ((Get-Content -LiteralPath $p.HdAnimSkip -Raw).Trim() -eq $info.Id)) { return }

    $gb = [math]::Round($info.Size / 1GB, 1)
    $what = "HD creatures for UO Smallz are available"
    if (Test-Path -LiteralPath $p.HdAnimStamp) { $what = "Updated HD creatures for UO Smallz are available" }
    $a = Show-Message ("${what}: sharper monsters, animals, people and the clothes they wear, drawn at their normal size. " +
        "It is a $gb GB download from GitHub, in $($info.Files.Count) parts; a part that breaks off is fetched again next time.`n`n" +
        "Yes = download it now (the game starts afterwards)`nNo = not now (you are asked again next time)`n" +
        "Cancel = don't ask again for this version") "YesNoCancel" "Question"
    Write-LaunchLog $root "HD creatures $($info.Id.Substring(0, 12)) offered: $a"
    if ($a -eq "Cancel") { Set-Content -LiteralPath $p.HdAnimSkip -Value $info.Id -Encoding ASCII; return }
    if ($a -ne "Yes") { return }

    while ((Get-ClientProcess $p.Client).Count -gt 0) {
        $r = Show-Message "UO Smallz is still running. Close the game, then press Retry.`n`nCancel plays without the HD creatures." "RetryCancel" "Warning"
        if ($r -ne "Retry") { Write-LaunchLog $root "HD creatures: client running, player cancelled"; return }
    }

    try {
        # in the background, with the progress window (see Invoke-Background)
        [void](Invoke-Background $root "Checking the HD creatures..." "Invoke-HdCreaturesWork" @($root, $info))
        Write-LaunchLog $root "HD creatures installed ($($info.Id))"
    } catch [System.OperationCanceledException] {
        Write-LaunchLog $root "HD creatures cancelled by the player, parts already in place kept"
    } catch {
        Write-LaunchLog $root "HD creatures failed, parts already in place kept: $($_.Exception.Message)"
        try { Show-Message "The HD creatures could not all be downloaded; the parts that arrived are kept and the rest is fetched next time.`n`n$($_.Exception.Message)" "OK" "Warning" | Out-Null } catch { }
    }
}

# After the client check: offer the pack when the client can draw it and
# hd-art.json names one this install doesn't have, then the creatures. Silent
# on any failure.
function Invoke-HdArt([string]$root) {
    $p = Get-Paths $root
    try {
        if (-not (Test-ClientDrawsHdArt $p.Client)) { return }   # the client update brings that first
        try {
            $manifest = Invoke-RestMethod -Uri $HdArtManifestUrl -Headers @{ "User-Agent" = "UOSmallz-launcher" } -TimeoutSec $TimeoutSec
        } catch {
            Write-LaunchLog $root "HD art check skipped: $($_.Exception.Message)"
            return
        }
        Invoke-HdArtPack $root (Get-HdArtInfo $manifest)
        try { Invoke-HdCreatures $root $manifest } catch { Write-LaunchLog $root "HD creatures error: $($_.Exception.Message)" }
    } catch {
        Write-LaunchLog $root "HD art error: $($_.Exception.Message)"
    }
}

# The pack into HDArt.download beside Client, resuming a part left from an
# earlier try; parts of any other pack go. Returns the checked zip; a
# download that does not match hd-art.json is deleted and thrown.
function Save-HdArtPack([string]$root, $info) {
    $p = Get-Paths $root
    New-Item -ItemType Directory -Path $p.HdArtDl -Force | Out-Null
    $part = Get-HdPartPath (Join-Path $p.HdArtDl $info.File) $info.Sha256
    Get-ChildItem -LiteralPath $p.HdArtDl -File | Where-Object { $_.FullName -ne $part } | Remove-Item -Force
    Save-UrlWithTimeout $info.Url $part 30 60 14400 -Resume
    if ((Get-Item -LiteralPath $part).Length -lt $info.Size) { throw "the download broke off; the rest is fetched next time" }
    if (-not (Test-Sha256 $part $info.Sha256)) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        throw "the download does not match hd-art.json (SHA-256)"
    }
    return $part
}

function Invoke-HdArtPack([string]$root, $info) {
    $p = Get-Paths $root
    try {
        if ($null -eq $info) { Write-LaunchLog $root "HD art check: hd-art.json missing or not valid"; return }
        if ((Read-HdArtStamp $p.HdArtStamp) -eq $info.Sha256) { return }
        if ((Test-Path -LiteralPath $p.HdArtSkip) -and ((Get-Content -LiteralPath $p.HdArtSkip -Raw).Trim() -eq $info.Sha256)) { return }

        $mb = [math]::Round($info.Size / 1MB)
        $what = "HD art for UO Smallz is available"
        if (Test-Path -LiteralPath $p.HdArt) { $what = "Updated HD art for UO Smallz is available" }
        $a = Show-Message ("${what}: sharper items, buildings, windows and ground, drawn at their normal size " +
            "(the difference shows most when you zoom in). It is a $mb MB download from GitHub.`n`n" +
            "Yes = download it now (the game starts afterwards)`nNo = not now (you are asked again next time)`n" +
            "Cancel = don't ask again for this version") "YesNoCancel" "Question"
        Write-LaunchLog $root "HD art $($info.Sha256.Substring(0, 12)) offered: $a"
        if ($a -eq "Cancel") { Set-Content -LiteralPath $p.HdArtSkip -Value $info.Sha256 -Encoding ASCII; return }
        if ($a -ne "Yes") { return }

        while ((Get-ClientProcess $p.Client).Count -gt 0) {
            $r = Show-Message "UO Smallz is still running. Close the game, then press Retry.`n`nCancel plays without the HD art." "RetryCancel" "Warning"
            if ($r -ne "Retry") { Write-LaunchLog $root "HD art: client running, player cancelled"; return }
        }

        $done = $false
        try {
            # download, check, unpack and swap in the background, with the progress window
            [void](Invoke-Background $root "Downloading the HD art ($mb MB)..." "Invoke-HdArtPackWork" @($root, $info))
            $done = $true
            Write-LaunchLog $root "HD art installed ($($info.Sha256))"
        } catch [System.OperationCanceledException] {
            Write-LaunchLog $root "HD art cancelled by the player, nothing changed (a broken-off download resumes next time)"
        } catch {
            Write-LaunchLog $root "HD art failed, nothing changed: $($_.Exception.Message)"
            try { Show-Message "The HD art could not be installed, so the game runs with the art it had.`n`n$($_.Exception.Message)" "OK" "Warning" | Out-Null } catch { }
        } finally {
            # a pack that is in goes; a broken-off one stays to resume
            if ($done) { Remove-TreeFast (Get-Paths $root).HdArtDl -Quiet }
        }
    } catch {
        Write-LaunchLog $root "HD art error: $($_.Exception.Message)"
    }
}

# ---- UI ------------------------------------------------------------------

function Show-UpdateDialog($info, $local) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "UO Smallz - client update available"
    $form.Size = New-Object System.Drawing.Size(560, 420)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true   # hidden launcher: never open behind everything

    $have = "unknown"
    if ($local -and $local.Tag) { $have = $local.Tag }
    $notes = $info.Notes
    if ([string]::IsNullOrWhiteSpace($notes)) { $notes = "(no release notes)" }
    $body = "A new UO Smallz client is available: $($info.Tag) (you have $have).`r`n`r`n" + $notes +
        "`r`n`r`nUpdating replaces the game client only. Your settings, characters' profiles, " +
        "macros and window layout are kept. The previous client is kept as Client.old."

    $text = New-Object System.Windows.Forms.RichTextBox
    $text.ReadOnly = $true
    $text.ScrollBars = "Vertical"
    $text.Location = New-Object System.Drawing.Point(14, 14)
    $text.Size = New-Object System.Drawing.Size(520, 300)
    $text.BackColor = [System.Drawing.Color]::White
    $text.Text = $body -replace "`r`n", "`n"
    $form.Controls.Add($text)

    $mk = {
        param($label, $x, $w, $result)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $label
        $b.Location = New-Object System.Drawing.Point($x, 328)
        $b.Size = New-Object System.Drawing.Size($w, 30)
        $b.DialogResult = $result
        $form.Controls.Add($b)
        return $b
    }
    $btnUpdate = & $mk "Update Now" 14 120 ([System.Windows.Forms.DialogResult]::Yes)
    $btnLater  = & $mk "Play Now" 144 120 ([System.Windows.Forms.DialogResult]::No)
    $null      = & $mk "Skip This Version" 274 140 ([System.Windows.Forms.DialogResult]::Ignore)
    $form.AcceptButton = $btnUpdate
    $form.CancelButton = $btnLater
    $answer = $form.ShowDialog()
    $form.Dispose()
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { return "update" }
    if ($answer -eq [System.Windows.Forms.DialogResult]::Ignore) { return "skip" }
    return "later"
}

function Show-Message([string]$text, [string]$buttons = "OK", [string]$icon = "Information") {
    Add-Type -AssemblyName System.Windows.Forms
    return [System.Windows.Forms.MessageBox]::Show($text, "UO Smallz", $buttons, $icon).ToString()
}

# The progress window while work runs in the background: status line, a real
# progress bar (a moving one while no total is known), detail line, Cancel.
# The window is only ever touched from the thread that made it. Closing it
# (Alt+F4) is a Cancel request, never a close, while work is running.
function Show-Busy([string]$text) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "UO Smallz"
    $f.ClientSize = New-Object System.Drawing.Size(420, 128)
    $f.StartPosition = "CenterScreen"
    $f.FormBorderStyle = "FixedDialog"
    $f.ControlBox = $false
    $f.MinimizeBox = $false
    $f.MaximizeBox = $false
    $f.TopMost = $true
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $false
    $l.Location = New-Object System.Drawing.Point(14, 12)
    $l.Size = New-Object System.Drawing.Size(392, 34)
    $f.Controls.Add($l)
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Location = New-Object System.Drawing.Point(14, 50)
    $bar.Size = New-Object System.Drawing.Size(392, 20)
    $bar.Style = "Marquee"
    $bar.MarqueeAnimationSpeed = 30
    $bar.Minimum = 0
    $bar.Maximum = 1000
    $f.Controls.Add($bar)
    $d = New-Object System.Windows.Forms.Label
    $d.AutoSize = $false
    $d.Location = New-Object System.Drawing.Point(14, 76)
    $d.Size = New-Object System.Drawing.Size(290, 36)
    $f.Controls.Add($d)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = "Cancel"
    $b.Location = New-Object System.Drawing.Point(316, 82)
    $b.Size = New-Object System.Drawing.Size(90, 28)
    $f.Controls.Add($b)
    $f.Tag = @{ Label = $l; Bar = $bar; Detail = $d; Button = $b; CancelRequested = $false; Allow = $false; Mode = "marquee"; Status = $text; DetailText = ""; CanCancel = $true }
    $b.Add_Click({ param($s, $e) $s.FindForm().Tag.CancelRequested = $true })
    $f.Add_FormClosing({ param($s, $e) if (-not $s.Tag.Allow) { $e.Cancel = $true; $s.Tag.CancelRequested = $true } })
    $f.Show()
    [System.Windows.Forms.Application]::DoEvents()
    return $f
}

# Copy the shared state onto the window and let it handle its messages.
# Cancel from the window goes into the state (only while cancelling is allowed).
function Update-Busy($form, $state) {
    if ($null -eq $form) { return }
    $ui = $form.Tag
    $status = [string]$state.Status
    if ($status -ne $ui.Status) { $ui.Status = $status; $ui.Label.Text = $status }
    $detail = [string]$state.Detail
    if ($detail -ne $ui.DetailText) { $ui.DetailText = $detail; $ui.Detail.Text = $detail }
    $total = [long]$state.Total
    if ($total -gt 0) {
        if ($ui.Mode -ne "bar") { $ui.Bar.Style = "Continuous"; $ui.Mode = "bar" }
        $v = [int][Math]::Min(1000L, [Math]::Max(0L, [long](1000.0 * [double]$state.Done / [double]$total)))
        if ($ui.Bar.Value -ne $v) { $ui.Bar.Value = $v }
    } elseif ($ui.Mode -ne "marquee") {
        $ui.Bar.Style = "Marquee"; $ui.Mode = "marquee"
    }
    $can = [bool]$state.CanCancel
    if ($can -ne $ui.CanCancel) { $ui.CanCancel = $can; $ui.Button.Enabled = $can }
    if ($ui.CancelRequested -and $can -and -not $state.Cancel) {
        $state.Cancel = $true
        $ui.Button.Enabled = $false
        $ui.Button.Text = "Cancelling..."
    }
    $ui.CancelRequested = $false
    [System.Windows.Forms.Application]::DoEvents()
}

function Close-Busy($form) {
    if ($null -eq $form) { return }
    try { $form.Tag.Allow = $true; $form.Close(); $form.Dispose() } catch { }
}

# What a background runspace runs: load this launcher's functions from its own
# text (read once at start, so a launcher replaced on disk meanwhile cannot
# change them mid-update), run one function, and report in $UoWork.
$BackgroundRunner = {
    param($selfText, $root, $command, $argList)
    $ErrorActionPreference = "Stop"
    $w = $UoWork
    try {
        $sb = [scriptblock]::Create($selfText)
        . $sb -NoMain -InstallRoot $root
        $r = & $command @argList
        $w.Result = $r
    } catch {
        $x = $_.Exception
        $c = $false
        while ($x) { if ($x -is [System.OperationCanceledException]) { $c = $true }; $x = $x.InnerException }
        $w.Cancelled = $c
        $w.Error = $_.Exception.Message
        $w.ErrorDetail = ($_ | Out-String)
    } finally {
        $w.Finished = $true
    }
}

# Run the function $command (by name, with $argList) in a background runspace
# while this thread shows the progress window and handles its messages about
# every 50 ms. Returns what the function returns. Throws what it threw (same
# message; OperationCanceledException when the player cancelled) so callers
# keep their try/catch and rollback exactly as when the work ran inline.
# $command must not touch any window. Without a window (Show-Busy answers $null,
# as in the tests) it just waits.
function Invoke-Background([string]$root, [string]$status, [string]$command, [object[]]$argList = @()) {
    if ($null -eq $SelfText) {
        # no text to load the functions from: do it here, as before
        return (& $command @argList)
    }
    $state = [hashtable]::Synchronized(@{
        Status = $status; Detail = ""; Done = 0L; Total = 0L
        Cancel = $false; CanCancel = $true
        Finished = $false; Cancelled = $false; Error = $null; ErrorDetail = $null; Result = $null
    })
    $busy = $null; $rs = $null; $ps = $null; $async = $null
    try {
        $busy = Show-Busy $status
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable("UoWork", $state)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($BackgroundRunner.ToString()).AddArgument($SelfText).AddArgument($root).AddArgument($command).AddArgument($argList)
        $async = $ps.BeginInvoke()
        while (-not $async.IsCompleted) {
            Update-Busy $busy $state
            Start-Sleep -Milliseconds 50
        }
        try { [void]$ps.EndInvoke($async) } catch { if (-not $state.Error) { $state.Error = $_.Exception.Message } }
        if (-not $state.Error -and $ps.Streams.Error.Count -gt 0 -and -not $state.Finished) { $state.Error = [string]$ps.Streams.Error[0] }
    } finally {
        if ($async -and -not $async.IsCompleted) {
            # an unexpected exit from the loop above: ask it to stop, give it time
            # to reach a safe point (never in the middle of the folder swap)
            $state.Cancel = $true
            [void]$async.AsyncWaitHandle.WaitOne(60000)
            if (-not $async.IsCompleted) { try { $ps.Stop() } catch { } }
        }
        Close-Busy $busy
        if ($ps) { try { $ps.Dispose() } catch { } }
        if ($rs) { try { $rs.Close(); $rs.Dispose() } catch { } }
    }
    if ($state.Cancelled) { throw (New-Object System.OperationCanceledException $CancelMessage) }
    if ($state.Error) { throw (New-Object System.Exception ([string]$state.Error)) }
    return $state.Result
}

# The jobs Invoke-Background runs. Each takes plain arguments and returns a
# plain value, so it also runs inline.

# The client update: only the changed files when the release lists them, else
# the full zip. The caller handles the failure (old client kept) and Cancel.
function Invoke-ClientUpdateWork([string]$root, $info, [string]$zip) {
    $done = $false
    if ($info.ManifestUrl) {
        try {
            Set-WorkStatus "Updating UO Smallz client to $($info.Tag) (only the files that changed)..."
            $fetched = Invoke-ClientDelta $root $info
            $done = $true
            Write-LaunchLog $root "updated to $($info.Tag) ($($info.Sha256)) by fetching the changed files only: $([math]::Round($fetched / 1MB, 1)) MB"
        } catch {
            if (Test-IsCancel $_) { throw }
            Write-LaunchLog $root "update $($info.Tag): changed-files update not used, downloading the full client ($($_.Exception.Message))"
        }
    }
    if (-not $done) {
        Set-WorkStatus "Downloading UO Smallz client $($info.Tag)..."
        Save-UrlWithTimeout $info.Url $zip
        Install-ClientUpdate $root $zip $info.Sha256 $info.Tag
        Write-LaunchLog $root "updated to $($info.Tag) ($($info.Sha256))"
    }
}

# The HD art pack: download (resumable), check, unpack, swap.
function Invoke-HdArtPackWork([string]$root, $info) {
    Set-WorkStatus "Downloading the HD art ($(Format-MB $info.Size))..."
    $zip = Save-HdArtPack $root $info
    Set-WorkStatus "Unpacking the HD art..."
    Install-HdArt $root $zip $info.Sha256
}

function Invoke-HdCreaturesWork([string]$root, $info) {
    Install-HdCreatures $root $info
}

function Start-Client([string]$root) {
    $p = Get-Paths $root
    if (Test-Path -LiteralPath $p.Exe) {
        return Start-Process -FilePath $p.Exe -WorkingDirectory $p.Client -PassThru
    } else {
        Write-LaunchLog $root "TazUO.exe not found at $($p.Exe)"
        try { Show-Message "The game client was not found in $($p.Client). Run install.bat again." "OK" "Error" | Out-Null } catch { }
    }
}

# ---- main ----------------------------------------------------------------

function Invoke-Launcher([string]$root) {
    $p = Get-Paths $root
    try {
        $local = Read-Stamp $p.Stamp
        if (Test-Path -LiteralPath $p.Pending) {
            # the last update has not had a good launch yet: settle that first
            Write-LaunchLog $root "update check deferred: the last update is not confirmed yet"
            return
        }
        try {
            $info = Get-LatestRelease
        } catch {
            Write-LaunchLog $root "update check skipped: $($_.Exception.Message)"
            return
        }
        if ($null -eq $info) { Write-LaunchLog $root "update check: no $AssetName on the latest release"; return }
        if (-not (Test-IsNewer $local $info.Tag $info.Sha256)) { return }

        $skipKey = "$($info.Tag) $($info.Sha256)"
        if ((Test-Path -LiteralPath $p.Skip) -and ((Get-Content -LiteralPath $p.Skip -Raw).Trim() -eq $skipKey)) { return }
        if (-not $info.Sha256) {
            Write-LaunchLog $root "update $($info.Tag) publishes no SHA256 (no digest, no $SumsName): not offered"
            return
        }

        $choice = Show-UpdateDialog $info $local
        Write-LaunchLog $root "update $($info.Tag) offered: $choice"
        if ($choice -eq "skip") { Set-Content -LiteralPath $p.Skip -Value $skipKey -Encoding ASCII; return }
        if ($choice -ne "update") { return }

        while ((Get-ClientProcess $p.Client).Count -gt 0) {
            $a = Show-Message "UO Smallz is still running. Close the game, then press Retry.`n`nCancel plays without updating." "RetryCancel" "Warning"
            if ($a -ne "Retry") { Write-LaunchLog $root "update $($info.Tag): client running, player cancelled"; return }
        }

        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("uosmallz-update-" + [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $zip = Join-Path $tmp $AssetName
        try {
            # All of it runs in a background runspace while this thread keeps the
            # progress window alive (Invoke-Background): only the files that
            # changed when the release lists its files, the full zip when that is
            # not possible (Invoke-ClientUpdateWork). A failure there comes back
            # here as the same exception, after the swap's own rollback.
            [void](Invoke-Background $root "Updating UO Smallz client to $($info.Tag)..." "Invoke-ClientUpdateWork" @($root, $info, $zip))
            try {
                $l = Update-LauncherFiles $root
                if ($l.Count -gt 0) { Write-LaunchLog $root "launcher updated: $($l -join ', ')" }
            } catch { Write-LaunchLog $root "launcher not updated: $($_.Exception.Message)" }
        } catch [System.OperationCanceledException] {
            Write-LaunchLog $root "update $($info.Tag) cancelled by the player, old client kept"
        } catch {
            Write-LaunchLog $root "update $($info.Tag) failed, old client kept: $($_.Exception.Message)"
            try { Show-Message "The update could not be installed, so your current client was kept.`n`n$($_.Exception.Message)" "OK" "Warning" | Out-Null } catch { }
        } finally {
            Remove-TreeFast $tmp -Quiet
        }
    } catch {
        Write-LaunchLog $root "launcher error: $($_.Exception.Message)"
    }
}

# After launching: while an update is unconfirmed, watch the client. Up for
# $HealthySeconds = good (Client.old goes on the next start). Gone sooner =
# offer the previous client back.
function Watch-PendingLaunch([string]$root, $proc) {
    $p = Get-Paths $root
    $pend = Read-Pending $p.Pending
    if ($null -eq $pend -or $pend.Ok) { return }
    if (Test-LaunchHealthy $proc) { Set-PendingLaunchOk $root; return }
    $code = "?"
    try { if ($proc) { $code = $proc.ExitCode } } catch { }
    Write-LaunchLog $root "update $($pend.Tag): the client closed within ${HealthySeconds}s (exit $code)"
    if (-not (Test-Path -LiteralPath (Join-Path $p.Old "TazUO.exe"))) { return }
    $prevName = $pend.PrevTag
    if (-not $prevName) { $prevName = "the previous version" }
    $a = Show-Message ("The updated UO Smallz client ($($pend.Tag)) closed right after it started.`n`n" +
        "Go back to $prevName? Your settings and characters' profiles are kept.`n`n" +
        "Yes = go back and start it now. No = keep $($pend.Tag) (you will be asked again if it happens again).") "YesNo" "Warning"
    if ($a -ne "Yes") { return }
    try {
        Restore-PreviousClient $root
        [void](Start-Client $root)
    } catch {
        Write-LaunchLog $root "rollback failed: $($_.Exception.Message)"
        try { Show-Message "Going back did not work: $($_.Exception.Message)`n`nClient.old is still there; run install.bat to repair." "OK" "Error" | Out-Null } catch { }
    }
}

if (-not $NoMain) {
    try { [void](Repair-ClientFolder $InstallRoot) } catch { Write-LaunchLog $InstallRoot "recovery failed: $($_.Exception.Message)" }
    try { [void](Confirm-PendingUpdate $InstallRoot) } catch { Write-LaunchLog $InstallRoot "cleanup failed: $($_.Exception.Message)" }
    # A newer launcher on main replaces this one and runs in its place.
    try {
        if (Update-LauncherSelf $InstallRoot) {
            $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
            Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
                "-File", "`"$(Join-Path $InstallRoot 'update-check.ps1')`"")
            return
        }
    } catch { Write-LaunchLog $InstallRoot "launcher self-update skipped: $($_.Exception.Message)" }
    try { Invoke-Launcher $InstallRoot } catch { }
    try { Invoke-HdArt $InstallRoot } catch { }
    $proc = Start-Client $InstallRoot
    try { Watch-PendingLaunch $InstallRoot $proc } catch { Write-LaunchLog $InstallRoot "launch watch failed: $($_.Exception.Message)" }
}
