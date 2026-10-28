# Timing of the changed-files scan and the delta install on a synthetic client the
# size of v14's (15,314 files, 14,150 of them small icons), for any version of the
# launcher, to compare launcher 9 (per-file Test-Path / Get-FileHash / Copy-Item)
# with launcher 10:
#   git show 47e7d958:installer/update-check.ps1 > /tmp/launcher9.ps1
#   pwsh -NoProfile -File tests/launcher-async.Bench.ps1 -Launcher /tmp/launcher9.ps1
#   pwsh -NoProfile -File tests/launcher-async.Bench.ps1                   (this checkout)
# Linux numbers are not Windows numbers (no Defender, a faster file system); the
# ratio is what matters. Needs only Get-ChangedFiles and Install-ClientDelta.
param(
    [string]$Launcher = "",
    [int]$Files = 15314
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $Launcher) { $Launcher = Join-Path (Join-Path $here "..") "installer" | Join-Path -ChildPath "update-check.ps1" }
. $Launcher -NoMain -InstallRoot $here
Add-Type -AssemblyName System.IO.Compression.FileSystem
$sep = [string][IO.Path]::DirectorySeparatorChar
$root = Join-Path ([IO.Path]::GetTempPath()) ("uosz-bench-" + [Guid]::NewGuid().ToString("N"))
$client = Join-Path $root "Client"
$rel = Join-Path $root "release"
function Write-Tree([string]$dir, [int]$variant) {
    $icons = [int]($Files * 0.924); $made = @{}
    for ($i = 0; $i -lt $Files; $i++) {
        if ($i -eq 0) { $r = "TazUO.exe" } elseif ($i -lt 40) { $r = "lib$i.dll" } else { $r = "ExternalImages/art/0x{0:X5}.png" -f $i }
        $path = Join-Path $dir $r.Replace('/', $sep); $d = [IO.Path]::GetDirectoryName($path)
        if (-not $made.ContainsKey($d)) { [void][IO.Directory]::CreateDirectory($d); $made[$d] = 1 }
        $b = New-Object byte[] (300 + ($i * 37) % 700); (New-Object Random ($i * 7919 + 13)).NextBytes($b)
        if ($variant -eq 1 -and ($i % 3000) -eq 5) { $b[0] = 255 - $b[0] }
        [IO.File]::WriteAllBytes($path, $b)
        if ($variant -eq 0) { [IO.File]::SetLastWriteTimeUtc($path, (Get-Date).AddDays(-3).ToUniversalTime()) }
    }
}
Write-Tree $client 0; Write-Tree $rel 1
[IO.File]::WriteAllText((Join-Path $client "settings.json"), "{}")
$full = (Resolve-Path $rel).Path
$list = Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object { [ordered]@{ path = $_.FullName.Substring($full.Length + 1).Replace('\', '/'); size = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower() } }
$manifest = Read-ClientManifest ([ordered]@{ tag = "v15"; files = @($list) } | ConvertTo-Json -Depth 4)
$zip = Join-Path $root "c.zip"; [IO.Compression.ZipFile]::CreateFromDirectory($rel, $zip)
Write-Stamp (Join-Path $root "client-version.json") "v14" ("a" * 64)
$reader = {
    param([long]$from, [int]$count)
    $fs = [IO.File]::OpenRead($zip)
    try { [void]$fs.Seek($from, [IO.SeekOrigin]::Begin); $buf = New-Object byte[] $count; $got = 0
        while ($got -lt $count) { $n = $fs.Read($buf, $got, $count - $got); $got += $n } } finally { $fs.Dispose() }
    return , $buf
}.GetNewClosure()
Write-Host "launcher: $Launcher ($(@($manifest.Files).Count) files)"
$cache = @{}
$scan = $null; $has = (Get-Command Get-ChangedFiles).Parameters.ContainsKey("cache")
$t1 = [Diagnostics.Stopwatch]::StartNew()
if ($has) { $changed = Get-ChangedFiles $client $manifest $cache } else { $changed = Get-ChangedFiles $client $manifest }
Write-Host ("scan, first run : {0,6:N2} s  ({1} changed)" -f $t1.Elapsed.TotalSeconds, @($changed).Count)
$t2 = [Diagnostics.Stopwatch]::StartNew()
if ($has) { $changed = Get-ChangedFiles $client $manifest $cache } else { $changed = Get-ChangedFiles $client $manifest }
Write-Host ("scan, second run: {0,6:N2} s  ({1} changed)" -f $t2.Elapsed.TotalSeconds, @($changed).Count)
$t3 = [Diagnostics.Stopwatch]::StartNew()
$zsha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
[void](Install-ClientDelta $root $manifest $changed (Get-Item $zip).Length $reader $zsha "v15")
Write-Host ("delta install   : {0,6:N2} s  (copy of the unchanged files, fetch, user files, swap, delete of the old Client.old)" -f $t3.Elapsed.TotalSeconds)
Remove-Item -LiteralPath $root -Recurse -Force
