<#
  map-merge.ps1 - puts the areas Felucca had in 2003 into the classic map.

  The classic Felucca map art UO Offline installs (intact Magincia) is the
  1998-99 world. The map audit found three areas from 2002 missing from it:
  the Solen hives (a flat square of grass), the Minax faction stronghold
  (bare ground) and the Council of Mages stronghold (open sea), and
  Khaldun with none of its decoration. This copies exactly those areas from
  the modern map the installer backed up (_backup-modern-map) into the map
  in use. Magincia and everything else stay classic.

    - Close the server and ClassicUO first (the map files must not be open).
    - Your current map files are copied to _backup-classic-map first.
      Running it again starts from that copy, so it is safe to repeat.
    - Undo:  run-map-merge.bat -Revert   (puts the backup back)
    - Leave Khaldun's decoration out:  run-map-merge.bat -NoKhaldun

  The server and ClassicUO read the same files, so both see the change.

  -Magincia (October 2026): the other way round. The shard now runs on the
  MODERN map, where Felucca Magincia is bare ground (EA's ruins are
  decoration, not map art), but its vendors, props, faction town stone and
  sigil monolith and the bots' Magincia data were all laid out for the
  intact town. This copies the whole Magincia island (3520-3839,
  2016-2311) from the classic map files into the modern map in use:
    - source: _backup-classic-map-retired (the installer keeps the classic
      files there when it puts the modern map back), else _backup-classic-map,
      or the folder -From names (the UO Smallz installer assembles the
      server's source there: map0x.mul land, classic statics)
    - the map in use is copied to _backup-before-magincia first; running it
      again starts from that copy, so it is safe to repeat
    - Undo:  run-map-merge.bat -Magincia -Revert
    - magincia-paste.txt in the data folder records that it was done
#>
param(
  [string]$DataDir = "",
  [switch]$Revert,
  [switch]$NoKhaldun,
  [switch]$Magincia,
  [string]$From = "",
  [switch]$NoPause
)
$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSEdition -eq "Core" -and $env:WINDIR) {
  $winPs = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
  if (Test-Path $winPs) {
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
    if ($DataDir) { $argList += @("-DataDir", $DataDir) }
    if ($Revert) { $argList += "-Revert" }
    if ($NoKhaldun) { $argList += "-NoKhaldun" }
    if ($Magincia) { $argList += "-Magincia" }
    if ($From) { $argList += @("-From", $From) }
    if ($NoPause) { $argList += "-NoPause" }
    & $winPs @argList
    exit $LASTEXITCODE
  }
}

function Done($code) { if (-not $NoPause) { Read-Host "Press Enter to close" | Out-Null }; exit $code }
function Fail($m) { Write-Host $m -ForegroundColor Red; Done 1 }

$MapMergeSource = @'
// MapMerge.cs - copies chosen 8x8 blocks from one Felucca map set into
// another (map0.mul, staidx0.mul, statics0.mul). C# 5 for Windows
// PowerShell 5.1's compiler.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

public static class MapMerge
{
    // rects: x1, y1, x2, y2, mode (0 land+statics, 1 land+statics only where
    // the target block is empty placeholder, 2 statics only), repeated.
    public static string Run(string classicDir, string modernDir, string outDir, int[] rects, string[] names, int height)
    {
        int bh = height >> 3;
        byte[] cMap = File.ReadAllBytes(Path.Combine(classicDir, "map0.mul"));
        byte[] mMap = File.ReadAllBytes(Path.Combine(modernDir, "map0.mul"));
        byte[] cIdx = File.ReadAllBytes(Path.Combine(classicDir, "staidx0.mul"));
        byte[] cSta = File.ReadAllBytes(Path.Combine(classicDir, "statics0.mul"));
        byte[] mIdx = File.ReadAllBytes(Path.Combine(modernDir, "staidx0.mul"));
        byte[] mSta = File.ReadAllBytes(Path.Combine(modernDir, "statics0.mul"));
        int cbw = (int)(cMap.Length / 196L / bh);
        int mbw = (int)(mMap.Length / 196L / bh);
        int blocks = cbw * bh;
        var land = new bool[blocks];
        var stat = new bool[blocks];
        var log = new StringBuilder();
        log.AppendFormat("map in use: {0} blocks wide; modern: {1} blocks wide\r\n", cbw, mbw);

        for (int r = 0; r + 4 < rects.Length; r += 5)
        {
            int x1 = rects[r] >> 3, y1 = rects[r + 1] >> 3, x2 = rects[r + 2] >> 3, y2 = rects[r + 3] >> 3, mode = rects[r + 4];
            int copied = 0, skipped = 0;
            for (int bx = x1; bx <= x2; bx++)
            {
                for (int by = y1; by <= y2; by++)
                {
                    if (bx < 0 || by < 0 || bx >= cbw || bx >= mbw || by >= bh)
                    {
                        continue;
                    }
                    int b = bx * bh + by;
                    if (mode == 1 && !IsPlaceholder(cMap, cIdx, b))
                    {
                        skipped++;
                        continue;
                    }
                    if (mode != 2)
                    {
                        land[b] = true;
                    }
                    stat[b] = true;
                    copied++;
                }
            }
            log.AppendFormat("{0}: {1} blocks copied{2}\r\n", names[r / 5], copied,
                mode == 1 ? " (" + skipped + " left as they were: not placeholder ground)" : mode == 2 ? " (decoration only)" : "");
        }

        // Land: the classic file with the chosen blocks replaced.
        var outMap = (byte[])cMap.Clone();
        for (int b = 0; b < blocks; b++)
        {
            if (land[b])
            {
                Buffer.BlockCopy(mMap, b * 196, outMap, b * 196, 196);
            }
        }

        // Statics: rebuilt block by block from one file or the other.
        var outIdx = new byte[blocks * 12];
        using (var ms = new MemoryStream(cSta.Length + 1024 * 1024))
        {
            for (int b = 0; b < blocks; b++)
            {
                byte[] idx = stat[b] ? mIdx : cIdx;
                byte[] sta = stat[b] ? mSta : cSta;
                int lookup = -1, length = -1, extra = 0;
                long io = (long)b * 12;
                if (io + 12 <= idx.Length)
                {
                    int lu = BitConverter.ToInt32(idx, (int)io);
                    int len = BitConverter.ToInt32(idx, (int)io + 4);
                    extra = BitConverter.ToInt32(idx, (int)io + 8);
                    if (lu >= 0 && len > 0 && (long)lu + len <= sta.Length)
                    {
                        lookup = (int)ms.Position;
                        length = len;
                        ms.Write(sta, lu, len);
                    }
                }
                BitConverter.GetBytes(lookup).CopyTo(outIdx, b * 12);
                BitConverter.GetBytes(length).CopyTo(outIdx, b * 12 + 4);
                BitConverter.GetBytes(extra).CopyTo(outIdx, b * 12 + 8);
            }
            Directory.CreateDirectory(outDir);
            File.WriteAllBytes(Path.Combine(outDir, "map0.mul"), outMap);
            File.WriteAllBytes(Path.Combine(outDir, "staidx0.mul"), outIdx);
            File.WriteAllBytes(Path.Combine(outDir, "statics0.mul"), ms.ToArray());
        }
        return log.ToString();
    }

    // Plain grass or black void with nothing on it: the stand-in the old map
    // has where a later area was built.
    private static bool IsPlaceholder(byte[] map, byte[] idx, int b)
    {
        int o = b * 196 + 4;
        for (int c = 0; c < 64; c++)
        {
            int id = (map[o + c * 3] | (map[o + c * 3 + 1] << 8)) & 0x3FFF;
            bool grass = id >= 0x0003 && id <= 0x0006;
            bool voidTile = id <= 0x0002 || id == 0x0244;
            if (!grass && !voidTile)
            {
                return false;
            }
        }
        long io = (long)b * 12;
        if (io + 12 <= idx.Length)
        {
            int lu = BitConverter.ToInt32(idx, (int)io);
            int len = BitConverter.ToInt32(idx, (int)io + 4);
            if (lu >= 0 && len > 0)
            {
                return false;
            }
        }
        return true;
    }
}

'@

Add-Type -TypeDefinition $MapMergeSource

# ---------------------------------------------------------------- folders
$root = Join-Path ([Environment]::GetFolderPath("UserProfile")) "uo-modernuo"
function Find-DataDir {
  $cands = @()
  $cfg = Join-Path $root "ModernUO\Distribution\Configuration\modernuo.json"
  if (Test-Path $cfg) {
    try { $j = Get-Content $cfg -Raw | ConvertFrom-Json; if ($j.dataDirectories) { $cands += @($j.dataDirectories) } } catch { }
  }
  $cands += (Join-Path $root "UOData\7.0.23.1\7.0.23.1")
  $cands += (Join-Path $root "UOData\7.0.23.1")
  foreach ($c in $cands) { if ($c -and (Test-Path (Join-Path $c "map0.mul"))) { return $c } }
  return $null
}
if (-not $DataDir) { $DataDir = Find-DataDir }
if (-not $DataDir -or -not (Test-Path (Join-Path $DataDir "map0.mul"))) {
  Fail "Could not find the UO data folder with map0.mul. Run again with -DataDir `"<that folder>`"."
}
$files = @("map0.mul", "staidx0.mul", "statics0.mul")
$modern = Join-Path $DataDir "_backup-modern-map"
$classic = Join-Path $DataDir "_backup-classic-map"
Write-Host "UO data folder: $DataDir"

# ---------------------------------------------------------------- not open?
foreach ($f in $files) {
  $p = Join-Path $DataDir $f
  try {
    $s = [System.IO.File]::Open($p, 'Open', 'ReadWrite', 'None'); $s.Close()
  } catch {
    Fail "$f is in use. Close the ModernUO server and ClassicUO, then run this again."
  }
}

# ---------------------------------------------------------------- Magincia
if ($Magincia) {
  $before = Join-Path $DataDir "_backup-before-magincia"
  if ($Revert) {
    if (-not (Test-Path (Join-Path $before "map0.mul"))) { Fail "No _backup-before-magincia folder: nothing to put back." }
    foreach ($f in $files) { Copy-Item (Join-Path $before $f) (Join-Path $DataDir $f) -Force }
    Remove-Item (Join-Path $DataDir "magincia-paste.txt") -ErrorAction SilentlyContinue
    Write-Host "Put the map back as it was before the Magincia paste." -ForegroundColor Green
    Done 0
  }
  $src = $null
  if ($From) {
    if (-not (Test-Path (Join-Path $From "map0.mul"))) { Fail "No map0.mul in $From to copy Magincia from." }
    $src = $From
  }
  foreach ($c in @("_backup-classic-map-retired", "_backup-classic-map")) {
    if ($src) { break }
    $d = Join-Path $DataDir $c
    if (Test-Path (Join-Path $d "map0.mul")) { $src = $d; break }
  }
  if (-not $src) {
    Fail "No classic map files (_backup-classic-map-retired or _backup-classic-map) to copy Magincia from."
  }
  if (Test-Path (Join-Path $DataDir "_backup-modern-map\map0.mul")) {
    Fail "The classic map is in use (_backup-modern-map exists): Magincia is already intact. Nothing to do."
  }
  if (-not (Test-Path (Join-Path $before "map0.mul"))) {
    New-Item -ItemType Directory -Force -Path $before | Out-Null
    foreach ($f in $files) { Copy-Item (Join-Path $DataDir $f) (Join-Path $before $f) -Force }
    Write-Host "Backed up the map in use to $before"
  } else {
    Write-Host "Starting from the earlier backup in $before"
  }
  # x1, y1, x2, y2, mode: the island and its shore, whole 8x8 blocks.
  $mrects = @(3520, 2016, 3839, 2311, 0)
  $tmp = Join-Path $DataDir "_merge-tmp"
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  Write-Host "Copying intact Magincia from $src ..."
  $log = [MapMerge]::Run($before, $src, $tmp, [int[]]$mrects, [string[]]@("Magincia (intact, from the classic map)"), 4096)
  foreach ($f in $files) { Copy-Item (Join-Path $tmp $f) (Join-Path $DataDir $f) -Force }
  Remove-Item $tmp -Recurse -Force
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
  "Magincia paste $stamp from $src`r`n$log" | Set-Content (Join-Path $DataDir "magincia-paste.txt") -Encoding UTF8
  Write-Host $log
  Write-Host "Done. Start the server: it notices the new map and rebuilds its path caches by itself." -ForegroundColor Green
  Done 0
}

# ---------------------------------------------------------------- revert
if ($Revert) {
  if (-not (Test-Path (Join-Path $classic "map0.mul"))) { Fail "No _backup-classic-map folder: nothing to put back." }
  foreach ($f in $files) { Copy-Item (Join-Path $classic $f) (Join-Path $DataDir $f) -Force }
  Write-Host "Put the classic map back as it was before the merge." -ForegroundColor Green
  Done 0
}

if (-not (Test-Path (Join-Path $modern "map0.mul"))) {
  Fail "No _backup-modern-map folder: the modern map to copy the areas from isn't there. (It is made when the installer swaps in the classic map.)"
}

# ---------------------------------------------------------------- backup
if (-not (Test-Path (Join-Path $classic "map0.mul"))) {
  New-Item -ItemType Directory -Force -Path $classic | Out-Null
  foreach ($f in $files) { Copy-Item (Join-Path $DataDir $f) (Join-Path $classic $f) -Force }
  Write-Host "Backed up the map in use to $classic"
} else {
  Write-Host "Starting from the earlier backup in $classic"
}

# ---------------------------------------------------------------- merge
# x1, y1, x2, y2, mode   (0 land + decoration, 1 only over placeholder
# ground, 2 decoration only). Tile coordinates, Felucca.
$rects = @(
  5632, 1776, 5943, 2047, 1,   # Solen hives (SpellHelper.IsSolenHiveLoc box, whole blocks)
  1088, 2560, 1175, 2623, 0,   # Minax stronghold (Rectangle2D 1097,2570,70,50 and a margin)
  4440, 1480, 4495, 1575, 0    # Council of Mages stronghold (4450-4485, 1487-1569)
)
$names = @("Solen hives", "Minax stronghold", "Council of Mages stronghold")
if (-not $NoKhaldun) {
  $rects += @(5376, 1280, 5631, 1511, 2)  # Khaldun region 5381-5628, 1284-1509: its decoration
  $names += "Khaldun decoration"
}

$tmp = Join-Path $DataDir "_merge-tmp"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Write-Host "Merging (reads about 250 MB, takes a few seconds)..."
$log = [MapMerge]::Run($classic, $modern, $tmp, [int[]]$rects, [string[]]$names, 4096)
foreach ($f in $files) { Copy-Item (Join-Path $tmp $f) (Join-Path $DataDir $f) -Force }
Remove-Item $tmp -Recurse -Force

$stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
"Map merge $stamp`r`n$log" | Set-Content (Join-Path $DataDir "map-merge-log.txt") -Encoding UTF8
Write-Host ""
Write-Host $log
Write-Host "Done. Start the server: it notices the new map and rebuilds its path caches by itself." -ForegroundColor Green
Write-Host "Undo any time with run-map-merge.bat -Revert"
Done 0
