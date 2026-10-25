# UO Smallz player installer (Windows, PowerShell 5.1+).
# Installs the UO Smallz game client (patched TazUO), downloads the
# Ultima Online Classic 7.0.23.1 game data if you do not have it, writes the
# client settings for uosmallz.duckdns.org:2593 and makes a desktop shortcut.
# Run it with install.bat. Nothing needs admin rights.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ShardName     = "UO Smallz"
$ShardHost     = "uosmallz.duckdns.org"
$ShardPort     = 2593
# The client comes from the latest uosmallz-client release (asset digest /
# SHA256SUMS.txt checked). If GitHub cannot be asked, the v1 build below is
# the fallback, pinned by hash.
$ClientFallbackTag = "v1"
$ClientFallbackUrl = "https://github.com/wesleysnoe-dev/uosmallz-client/releases/download/v1/UOSmallz-Client-win-x64.zip"
$ClientFallbackSha = "bfb3a6e2501e9344da7646aba0cb84842fc38f56aff5f8a96718e25b46adbe1a"
# Same community mirror and pinned file as the UO Offline installer.
$UODataUrl     = "https://mirror.ashkantra.de/fullclients/7.0.23.1.exe"
$UODataSha256  = "23b0548252bb4e6f39afbddac2e64f8deb862fbfaccb1303b87895d295e01839"
$UODataVersion = "7.0.23.1"
$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
# Run from inside the zip. Opening the zip in Explorer and double-clicking
# install.bat runs it from a temporary folder (%TEMP%\<id>_<name>.zip.<n>\ on
# Windows 11, %TEMP%\Temp1_<name>.zip\ before that) that Windows deletes when
# it is done with the zip, sometimes while the install is still going: the
# download finished, then map-merge.ps1 and update-check.ps1 were gone. So
# the installer first copies its folder to one that stays
# (%LOCALAPPDATA%\UOSmallz-installer) and runs that copy instead.
#   UOSMALLZ_INSTALLER_COPY  where to copy it (tests)
#   UOSMALLZ_RELAUNCH_ONLY=1 copy and report, do not run the copy (tests)
# ---------------------------------------------------------------------------
function Test-ZipTempDir([string]$dir, [string]$temp = [IO.Path]::GetTempPath()) {
  if (-not $dir -or -not $temp) { return $false }
  $d = [IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
  $t = [IO.Path]::GetFullPath($temp).TrimEnd('\', '/')
  if (-not $d.StartsWith($t + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $false }
  foreach ($part in $d.Substring($t.Length + 1).Split([char[]]@('\', '/'))) {
    if ($part -match '(?i)\.zip(\.[0-9a-z]+)?$') { return $true }
  }
  return $false
}

if (Test-ZipTempDir $ScriptDir) {
  $copy = if ($env:UOSMALLZ_INSTALLER_COPY) { $env:UOSMALLZ_INSTALLER_COPY } else { Join-Path $env:LOCALAPPDATA "UOSmallz-installer" }
  $missing = @("install.ps1", "update-check.ps1", "map-merge.ps1", "launch.vbs") | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ScriptDir $_)) }
  if ($missing) {
    Write-Host ""
    Write-Host "[error] The installer is running from inside the zip, and Windows did not unpack all of it ($($missing -join ', ') missing)." -ForegroundColor Red
    Write-Host "        Right-click the zip, choose Extract All, and run install.bat from the extracted folder."
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
  }
  Write-Host "    Running from inside the zip: copying the installer to $copy first."
  New-Item -ItemType Directory -Force -Path $copy | Out-Null
  Copy-Item -Path (Join-Path $ScriptDir "*") -Destination $copy -Recurse -Force
  $again = Join-Path $copy "install.ps1"
  if ($env:UOSMALLZ_RELAUNCH_ONLY -eq "1") { Write-Host "relaunch: $again"; exit 0 }
  # The same PowerShell (5.1 or pwsh) in the same window, so the questions
  # and the "Press Enter to close" stay where the player is looking.
  & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $again
  exit $LASTEXITCODE
}

# Shared with the launcher: release lookup, SHA256, version stamp, settings merge.
. (Join-Path $ScriptDir "update-check.ps1") -NoMain -InstallRoot $ScriptDir

function Say($m)  { Write-Host "    $m" }
function Ok($m)   { Write-Host "[ok] $m" -ForegroundColor Green }
function Step($m) { Write-Host ""; Write-Host "== $m ==" -ForegroundColor Cyan }
function Die($m)  { Write-Host ""; Write-Host "[error] $m" -ForegroundColor Red; Write-Host ""; Read-Host "Press Enter to close"; exit 1 }

function Get-File($url, $out) {
  $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }
  Invoke-WebRequest -Uri $url -OutFile $out -Headers $headers -UseBasicParsing
}

function Find-UOData($roots) {
  foreach ($r in $roots) {
    if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
    if ((Test-Path (Join-Path $r "tiledata.mul")) -and (Test-Path (Join-Path $r "art.mul"))) { return $r }
    $hit = Get-ChildItem -LiteralPath $r -Recurse -Filter "tiledata.mul" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit -and (Test-Path (Join-Path $hit.DirectoryName "art.mul"))) { return $hit.DirectoryName }
  }
  return $null
}


# ---------------------------------------------------------------------------
# Felucca map art. Since October 2026 the UO Smallz server runs the MODERN
# map (its faction strongholds, spawners and decoration were laid out on it;
# on the classic art the Minax stronghold sits inside a mountain, drawn black)
# with the Magincia island pasted in from the classic art, so the town stands
# intact. The client must have exactly the same files:
#   - an install that has the classic map gets the modern files put back
#     from _backup-modern-map (the classic ones go to _backup-classic-map-retired)
#   - the Magincia island is pasted with map-merge.ps1 -Magincia from the
#     same sources the server's came from: land from the 7.0.23.1 data's own
#     map0x.mul, statics from the UO Second Age client (kept classic files,
#     else downloaded as before)
#   - the result is checked against the server's map files (SHA256 below)
# INSTALL_CLASSIC_MAP=1 still swaps in the whole classic art (it does not
# match the server any more).
# ---------------------------------------------------------------------------
$InstallT2AMap      = ($env:INSTALL_CLASSIC_MAP -eq "1")
$T2AInstallerUrl    = "https://download.uosecondage.com/UOSA_Client_Setup.exe"
$T2AInstallerSha256 = "674ec3cce9621bd8c1a8f2f69070e64e63191ce73d6f297236bf8f3b89d41ddf"
$T2AMulFiles        = @("map0.mul", "statics0.mul", "staidx0.mul")
# The UO Smallz server's Felucca map files (modern + intact Magincia, 2026-10-21).
$ServerMapSha256    = @{
  "map0.mul"     = "64e5a0b530e071da69e5f698680b0e0043a49aa9aa025322781d4f55b4dfcbc4"
  "statics0.mul" = "2e362abf4cc55521bd2f673d6f71577fd7b42f9a3b4c293f5a998a7cfb5657c4"
  "staidx0.mul"  = "e8f9d96eaa33775428cf260b2a70146c8a6e1af98caac554642484718566789d"
}
# The 2002-area merge (map-merge.ps1, classic map only) is OFF; the server is
# not merged. UOSMALLZ_MAP_MERGE=1 runs it after an INSTALL_CLASSIC_MAP=1 swap.
$RunMapMerge        = ($env:UOSMALLZ_MAP_MERGE -eq "1")
function Banner($m) { Step $m }
function Warn($m)   { Write-Host "[warn] $m" -ForegroundColor Yellow }
function Assert-Pinned($path, $sha, $label) {
  $got = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $sha) {
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    Die "Refusing to use ${label}: SHA256 mismatch. The file was deleted. Re-run to download it again."
  }
}
function Invoke-Native([string]$Exe, [string[]]$Arguments = @()) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
  try { $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
  return $out
}

function RemoveUosaLeftovers {
  param([Parameter(Mandatory)][string]$ExtractDir, [switch]$WhatIfOnly)

  $found = @()

  $roots = @(
    [Environment]::GetFolderPath("Desktop"),
    [Environment]::GetFolderPath("CommonDesktopDirectory"),
    [Environment]::GetFolderPath("Programs"),
    [Environment]::GetFolderPath("CommonPrograms")
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

  $wsh = New-Object -ComObject WScript.Shell

  foreach ($root in $roots) {
    $links = Get-ChildItem -Path $root -Filter *.lnk -Recurse -ErrorAction SilentlyContinue
    foreach ($lnk in $links) {
      $target = $null
      try { $target = $wsh.CreateShortcut($lnk.FullName).TargetPath } catch { continue }
      if (-not $target) { continue }

      if ($target.StartsWith($ExtractDir, [StringComparison]::OrdinalIgnoreCase)) {
        $found += $lnk.FullName
        if (-not $WhatIfOnly) { Remove-Item $lnk.FullName -Force -ErrorAction SilentlyContinue }
      }
    }
  }

  # Its Start-Menu folder, in whichever profile it landed in. Only if empty
  # after the shortcuts above went, so a folder holding anything else stays.
  foreach ($progs in @([Environment]::GetFolderPath("Programs"), [Environment]::GetFolderPath("CommonPrograms"))) {
    if (-not $progs) { continue }
    $dir = Join-Path $progs "Ultima Online"
    if ((Test-Path $dir) -and -not (Get-ChildItem $dir -Recurse -File -ErrorAction SilentlyContinue)) {
      $found += $dir
      if (-not $WhatIfOnly) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }

  if ($WhatIfOnly) { return $found }

  foreach ($f in $found) { Say "Removed leftover: $f" }

  # And the client itself. The swap is idempotent through the backup folder
  # it leaves behind, so nothing needs these files again.
  if (Test-Path $ExtractDir) {
    Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    Say "Removed the extracted UO Second Age client."
  }

  Ok "Cleaned up after the UOSA installer ($($found.Count) shortcut(s))."
}

# The three classic map files from the UO Second Age client, extracted to
# $T2ASrcDir\uosa-install: a table file name -> path, or $null (warned).
# RemoveUosaLeftovers puts the extract away once they have been copied.
function Get-ClassicMapFiles {
  # 1. Obtain the UOSA installer (cached so re-runs don't re-download ~349 MB).
  New-Item -ItemType Directory -Force -Path $T2ASrcDir | Out-Null
  $uosaExe = Join-Path $T2ASrcDir "UOSA_Client_Setup.exe"
  if (-not (Test-Path $uosaExe)) {
    Say "Downloading UO Second Age client (~349 MB, EA content via uosecondage.com) for its classic map art..."
    $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }
    Invoke-WebRequest -Uri $T2AInstallerUrl -OutFile $uosaExe -Headers $headers
  } else { Say "UOSA installer already cached at $uosaExe." }
  Assert-Pinned $uosaExe $T2AInstallerSha256 "the UO Second Age installer (UOSA_Client_Setup.exe)"

  # 2. Extract ONLY the three map files with 7-Zip. The UOSA setup is never
  #    run: it carries Razor and UO Auto-Map installers that it launches even
  #    when silent. Without an installed 7-Zip, a private copy is fetched
  #    (pinned 7zr.exe unpacks the pinned 7-Zip package; its 7z.exe reads NSIS).
  $extractDir = Join-Path $T2ASrcDir "uosa-install"
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null

  $sevenZipExe = $null
  foreach ($c in @((Join-Path $env:ProgramFiles "7-Zip\7z.exe"), (Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe"))) {
    if ($c -and (Test-Path -LiteralPath $c)) { $sevenZipExe = $c; break }
  }
  if (-not $sevenZipExe) { $g = Get-Command 7z -ErrorAction SilentlyContinue; if ($g) { $sevenZipExe = $g.Source } }

  $haveMuls = $true
  foreach ($f in $T2AMulFiles) { if (-not (Test-Path (Join-Path $extractDir $f))) { $haveMuls = $false } }

  if (-not $haveMuls) {
    if (-not $sevenZipExe) {
      $szDir = Join-Path $T2ASrcDir "7zip"
      $szExe = Join-Path $szDir "7z.exe"
      if (-not (Test-Path -LiteralPath $szExe)) {
        Say "Fetching 7-Zip (portable, ~2 MB) to read the map files..."
        New-Item -ItemType Directory -Force -Path $szDir | Out-Null
        $hdr = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" }
        $zr  = Join-Path $T2ASrcDir "7zr.exe"
        $pkg = Join-Path $T2ASrcDir "7z2409-x64.exe"
        Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $zr -Headers $hdr -UseBasicParsing
        Assert-Pinned $zr "256feca8e274e5da655e2a284fabafd9f554365eb164862089dacd4e8276d282" "7zr.exe"
        Invoke-WebRequest -Uri "https://www.7-zip.org/a/7z2409-x64.exe" -OutFile $pkg -Headers $hdr -UseBasicParsing
        Assert-Pinned $pkg "bdd1a33de78618d16ee4ce148b849932c05d0015491c34887846d431d29f308e" "7z2409-x64.exe"
        & $zr x -y "-o$szDir" $pkg 7z.exe 7z.dll 2>&1 | Out-Null
        Remove-Item -LiteralPath $zr, $pkg -Force -ErrorAction SilentlyContinue
      }
      if (Test-Path -LiteralPath $szExe) { $sevenZipExe = $szExe }
    }
    if (-not $sevenZipExe) {
      Warn "Could not get 7-Zip to read the classic map files. Install 7-Zip from https://www.7-zip.org and re-run."
      return $null
    }
    Say "Extracting the classic map files with 7-Zip..."
    & $sevenZipExe (@("x", "-y", "-r", "-o$extractDir", $uosaExe) + $T2AMulFiles) 2>&1 | Out-Null
  }

  # Locate the three muls (they may sit in a subfolder of the archive).
  $srcMap = @{}
  foreach ($f in $T2AMulFiles) {
    $hit = Get-ChildItem -Path $extractDir -Recurse -Filter $f -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { $srcMap[$f] = $hit.FullName }
  }
  foreach ($f in $T2AMulFiles) {
    if (-not $srcMap.ContainsKey($f)) { Warn "Classic $f not found after extract."; return $null }
  }
  return $srcMap
}

function SwapT2AMap {
  if (-not $script:UOData) { Warn "UO data dir not resolved; skipping the map step."; return }
  if (-not $InstallT2AMap) { UseServerMap; return }
  Banner "Installing classic Felucca map art (INSTALL_CLASSIC_MAP=1)"
  Warn "The UO Smallz server runs the modern map with intact Magincia: with the whole classic art, parts of your map will not match it."

  $backupDir = Join-Path $script:UOData "_backup-modern-map"
  if (Test-Path (Join-Path $backupDir "map0.mul")) {
    Say "Classic map already swapped (modern backup exists). Skipping."
    return
  }
  $extractDir = Join-Path $T2ASrcDir "uosa-install"
  $srcMap = Get-ClassicMapFiles
  if (-not $srcMap) { Warn "Aborting the classic map swap (modern map kept)."; return }

  # 3. Back up the modern files (the 3 swapped + radarcol/tiledata for safety).
  New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
  foreach ($f in @("map0.mul", "statics0.mul", "staidx0.mul", "radarcol.mul", "tiledata.mul")) {
    $live = Join-Path $script:UOData $f
    if (Test-Path $live) { Copy-Item $live (Join-Path $backupDir $f) -Force }
  }
  Ok "Backed up modern map -> $backupDir"

  # 4. Copy the classic files over the live data dir.
  foreach ($f in $T2AMulFiles) { Copy-Item $srcMap[$f] (Join-Path $script:UOData $f) -Force }

  # 5. Put away what the UOSA installer left lying about.
  #
  # We wanted three map files. Run silently, that installer also lays down a
  # complete, working UO Second Age client and drops shortcuts on the desktop
  # for it. People click those, arrive at the real Second Age login server,
  # and cannot work out why they are not on their own shard.
  RemoveUosaLeftovers $extractDir
  Ok "Classic Felucca map art installed (intact Magincia). Revert: copy _backup-modern-map\* back over the data dir."

  # 6. The classic art is the 1998-99 world. Put back the areas Felucca had
  #    by 2003 (Solen hives, the Minax and Council of Mages strongholds,
  #    Khaldun's decoration) from the modern backup: tools\map-audit\
  #    map-merge.ps1, which keeps its own backup (_backup-classic-map).
  $merge = Join-Path $ScriptDir "map-merge.ps1"
  if ($RunMapMerge -and (Test-Path $merge)) {
    Say "Adding the 2002 areas the classic map lacks (Solen hives, faction strongholds, Khaldun)..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $merge -DataDir $script:UOData -NoPause
    if ($LASTEXITCODE -eq 0) { Ok "Solen hives, Minax and Council of Mages strongholds and Khaldun added to the classic map." }
    else { Warn "The area merge did not run; run map-merge.ps1 -DataDir <your UO folder> later (game closed)." }
  }
}

# The server's map: modern art with intact Magincia (see the top of the file).
function UseServerMap {
  Banner "Felucca map art (the server's: modern map, intact Magincia)"
  if (-not (RestoreModernMap)) { return }
  PasteMagincia
  Test-ServerMap
}

# An install that has the classic map: put the modern map files back from
# _backup-modern-map. The classic files go to _backup-classic-map-retired
# (PasteMagincia takes Magincia's statics from there), and the modern backup
# folder is renamed, so INSTALL_CLASSIC_MAP=1 later swaps again from scratch.
# $false when the files are in use (the game is open).
function RestoreModernMap {
  $backupDir = Join-Path $script:UOData "_backup-modern-map"
  if (-not (Test-Path (Join-Path $backupDir "map0.mul"))) { Say "Modern Felucca map art in use."; return $true }
  foreach ($f in $T2AMulFiles) {
    $p = Join-Path $script:UOData $f
    try { $s = [System.IO.File]::Open($p, 'Open', 'ReadWrite', 'None'); $s.Close() }
    catch { Warn "$f is in use: close the game, then run install.bat again to get the server's map."; return $false }
  }
  $retired = Join-Path $script:UOData "_backup-classic-map-retired"
  New-Item -ItemType Directory -Force -Path $retired | Out-Null
  foreach ($f in $T2AMulFiles) {
    Copy-Item (Join-Path $script:UOData $f) (Join-Path $retired $f) -Force
    Copy-Item (Join-Path $backupDir $f) (Join-Path $script:UOData $f) -Force
  }
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  Rename-Item $backupDir "_backup-modern-map.restored-$stamp"
  Ok "Modern Felucca map art put back (the classic files are in _backup-classic-map-retired)."
  return $true
}

# Intact Magincia on the modern map, pasted the way the server's was: the
# island's land from map0x.mul (in the 7.0.23.1 data), its statics from the
# UO Second Age client. They are put together in _magincia-source for
# map-merge.ps1 -Magincia -From. Once (magincia-paste.txt); undo with
# map-merge.ps1 -Magincia -Revert -DataDir <your UO folder>.
function PasteMagincia {
  if (Test-Path (Join-Path $script:UOData "magincia-paste.txt")) { Say "Intact Magincia already on the map."; return }
  $retired = Join-Path $script:UOData "_backup-classic-map-retired"
  $statics = @{}
  $extractDir = $null
  if ((Test-Path (Join-Path $retired "statics0.mul")) -and (Test-Path (Join-Path $retired "staidx0.mul"))) {
    foreach ($f in $T2AMulFiles) { $statics[$f] = Join-Path $retired $f }
  } else {
    $extractDir = Join-Path $T2ASrcDir "uosa-install"
    $statics = Get-ClassicMapFiles
    if (-not $statics) { Warn "Magincia stays bare ground (not as on the server). Run install.bat again to retry."; return }
  }
  $src = Join-Path $script:UOData "_magincia-source"
  New-Item -ItemType Directory -Force -Path $src | Out-Null
  Copy-Item $statics["statics0.mul"] (Join-Path $src "statics0.mul") -Force
  Copy-Item $statics["staidx0.mul"] (Join-Path $src "staidx0.mul") -Force
  $land = Join-Path $script:UOData "map0x.mul"
  if (Test-Path $land) { Copy-Item $land (Join-Path $src "map0.mul") -Force }
  else {
    Warn "No map0x.mul in your UO folder: Magincia's land comes from the classic map instead (the shore water depth differs from the server's)."
    Copy-Item $statics["map0.mul"] (Join-Path $src "map0.mul") -Force
  }
  Say "Putting intact Magincia onto the modern map..."
  $merge = Join-Path $ScriptDir "map-merge.ps1"
  $out = @(Invoke-Native "powershell.exe" @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $merge, "-Magincia", "-From", $src, "-DataDir", $script:UOData, "-NoPause"))
  $code = $LASTEXITCODE
  Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
  if ($extractDir) { RemoveUosaLeftovers $extractDir }
  if ($code -eq 0) { Ok "Intact Magincia added to the modern map." }
  else {
    foreach ($l in $out) { Say $l }
    Warn "The Magincia paste did not run (close the game); run install.bat again."
  }
}

function Test-ServerMap {
  $off = @($T2AMulFiles | Where-Object {
    (Get-FileHash -LiteralPath (Join-Path $script:UOData $_) -Algorithm SHA256).Hash.ToLower() -ne $ServerMapSha256[$_]
  })
  if ($off.Count -eq 0) { Ok "Your map files match the UO Smallz server's." }
  else { Warn "Your $($off -join ', ') differ from the server's: some places may look different in game (another UO data version?)." }
}

try {
  Write-Host ""
  Write-Host "  UO Smallz installer" -ForegroundColor Yellow
  Write-Host "  Shard: ${ShardHost}:$ShardPort"
  Write-Host ""

  $default = Join-Path $env:LOCALAPPDATA "UOSmallz"
  $ans = Read-Host "Install folder [$default] (Enter = default)"
  if ([string]::IsNullOrWhiteSpace($ans)) { $InstallRoot = $default } else { $InstallRoot = $ans.Trim().Trim('"') }
  $ClientDir = Join-Path $InstallRoot "Client"
  $DataRoot  = Join-Path $InstallRoot "UOData"
  New-Item -ItemType Directory -Force -Path $InstallRoot, $DataRoot | Out-Null

  # 1. Game client
  Step "Game client (TazUO)"
  $clientTag = $ClientFallbackTag; $clientUrl = $ClientFallbackUrl; $clientSha = $ClientFallbackSha
  try {
    $rel = Get-LatestRelease
    if ($rel -and $rel.Sha256) { $clientTag = $rel.Tag; $clientUrl = $rel.Url; $clientSha = $rel.Sha256 }
    elseif ($rel) { Warn "The latest release publishes no SHA256; using the pinned $ClientFallbackTag client." }
  } catch {
    Warn "Could not ask GitHub for the latest client ($($_.Exception.Message)); using the pinned $ClientFallbackTag client."
  }
  Say "Client release: $clientTag"
  $zip = Join-Path $ScriptDir "UOSmallz-Client-win-x64.zip"
  if ((Test-Path -LiteralPath $zip) -and -not (Test-Sha256 $zip $clientSha)) {
    if (Test-Sha256 $zip $ClientFallbackSha) { $clientTag = $ClientFallbackTag; $clientSha = $ClientFallbackSha }
    else { Warn "The client zip next to the installer is not a known build; downloading instead."; $zip = $null }
  } elseif (-not (Test-Path -LiteralPath $zip)) { $zip = $null }
  if (-not $zip) {
    $zip = Join-Path $InstallRoot "UOSmallz-Client-win-x64.zip"
    Say "Downloading the client (~85 MB)..."
    Save-UrlWithTimeout $clientUrl $zip
    if (-not (Test-Sha256 $zip $clientSha)) {
      Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
      Die "The client download did not match its SHA256. It was deleted; nothing was changed. Try again later."
    }
  }
  Ok "Client zip SHA256 verified ($clientTag)"
  if (@(Get-ClientProcess $ClientDir).Count -gt 0) { Die "UO Smallz is running. Close the game and run install.bat again." }
  # A client left half-swapped by an interrupted update is put back first,
  # so the player's Data\ is where the swap below expects it.
  $rep = Repair-ClientFolder $InstallRoot
  if ($rep -eq "old" -or $rep -eq "new") { Ok "Repaired an interrupted client update ($rep copy restored)" }
  Say "Unpacking beside the current client (your settings.json and Data\ profiles are kept)..."
  # Unpacks to Client.new (the zip's own settings.json / Data\ dropped),
  # copies the player's files across, then swaps Client -> Client.old and
  # Client.new -> Client; any failure puts the old client back.
  try { Install-ClientUpdate $InstallRoot $zip $clientSha $clientTag }
  catch { Die "Installing the client failed, your previous client was kept: $($_.Exception.Message)" }
  $exe = Join-Path $ClientDir "TazUO.exe"
  Ok "Client: $exe"

  # 2. UO game data
  Step "Ultima Online game data ($UODataVersion)"
  $uoData = Find-UOData @($DataRoot)
  if (-not $uoData) {
    Say "You need the Ultima Online Classic game files ($UODataVersion)."
    Say "If you already have them, type that folder. Otherwise press Enter and the"
    Say "installer downloads them (~930 MB, from a community mirror; EA content)."
    $own = Read-Host "Your UO folder (Enter = download)"
    if (-not [string]::IsNullOrWhiteSpace($own)) {
      $uoData = Find-UOData @($own.Trim().Trim('"'))
      if (-not $uoData) { Die "No tiledata.mul / art.mul found in $own." }
    }
  }
  if (-not $uoData) {
    $sfx = Join-Path $DataRoot "$UODataVersion.exe"
    if (Test-Path -LiteralPath $sfx) {
      $h = (Get-FileHash -LiteralPath $sfx -Algorithm SHA256).Hash.ToLower()
      if ($h -ne $UODataSha256) { Remove-Item -LiteralPath $sfx -Force }
    }
    if (-not (Test-Path -LiteralPath $sfx)) {
      Say "Downloading (5-15 minutes)..."
      Get-File $UODataUrl $sfx
    }
    $h = (Get-FileHash -LiteralPath $sfx -Algorithm SHA256).Hash.ToLower()
    if ($h -ne $UODataSha256) {
      Remove-Item -LiteralPath $sfx -Force
      Die "The game data download did not match the expected file (SHA256). Nothing was run. Try again later."
    }
    Ok "Download verified."
    $target = Join-Path $DataRoot $UODataVersion
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Say "Extracting (a few minutes)..."
    Start-Process -FilePath $sfx -ArgumentList "-s2 -y `"-d$target`"" -Wait
    $uoData = Find-UOData @($DataRoot)
    if (-not $uoData) {
      Say "Silent extraction did not work; a setup window will open."
      Say "Click through it and install into: $target"
      Start-Process -FilePath $sfx -WorkingDirectory $target -Wait
      $uoData = Find-UOData @($DataRoot, $target)
    }
    if (-not $uoData) { Die "Could not find the extracted game data (tiledata.mul)." }
    Remove-Item -LiteralPath $sfx -Force -ErrorAction SilentlyContinue
  }
  Ok "UO data: $uoData"

  # 2b. Map art: the server's (modern, intact Magincia)
  $script:UOData = $uoData
  $T2ASrcDir = Join-Path $InstallRoot "t2a-src"
  SwapT2AMap

  # 3. Settings
  Step "Client settings"
  $defaults = [ordered]@{
    username              = ""
    password              = ""
    ip                    = $ShardHost
    port                  = $ShardPort
    ultimaonlinedirectory = $uoData.Replace([char]92, [char]47)
    clientversion         = $UODataVersion
    lastservernum         = 1
    last_server_name      = $ShardName
    fps                   = 60
    encryption            = 0
    saveaccount           = $false
    autologin             = $false
    plugins               = @()
  }
  $settings = Join-Path (Split-Path -Parent $exe) "settings.json"
  $set = @(Merge-ClientSettings $settings $defaults)
  if ($set.Count -eq 0) { Ok "Kept your settings.json as it is ($settings)" }
  else { Ok "settings.json: set $($set -join ', ') ($settings)" }

  # 3b. Version stamp and launcher (update check at every start). A launcher
  # that has already updated itself past this installer's is kept.
  $haveLauncher = Join-Path $InstallRoot "update-check.ps1"
  $mineVer = Get-LauncherVersionOf ([IO.File]::ReadAllText((Join-Path $ScriptDir "update-check.ps1")))
  $haveVer = 0
  if (Test-Path -LiteralPath $haveLauncher) { $haveVer = Get-LauncherVersionOf ([IO.File]::ReadAllText($haveLauncher)) }
  if ($haveVer -gt $mineVer) {
    Ok "Launcher kept (yours is newer: $haveVer; client $clientTag)"
  } else {
    foreach ($f in @("update-check.ps1", "launch.vbs")) {
      Copy-Item -LiteralPath (Join-Path $ScriptDir $f) -Destination (Join-Path $InstallRoot $f) -Force
    }
    Ok "Launcher installed (version $mineVer, client $clientTag)"
  }

  # 4. Shortcut
  Step "Shortcuts"
  # The shortcuts run launch.vbs (no console window), which runs the update
  # check and then the game. Without Windows Script Host, they run the check
  # through PowerShell directly (a console may flash briefly).
  $wsh = New-Object -ComObject WScript.Shell
  $wscript = Join-Path $env:SystemRoot "System32\wscript.exe"
  $vbs = Join-Path $InstallRoot "launch.vbs"
  $ps = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
  $startMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "UO Smallz.lnk"
  foreach ($lnkPath in @((Join-Path ([Environment]::GetFolderPath("Desktop")) "UO Smallz.lnk"), $startMenu)) {
    $lnk = $wsh.CreateShortcut($lnkPath)
    if (Test-Path -LiteralPath $wscript) {
      $lnk.TargetPath = $wscript
      $lnk.Arguments = "`"$vbs`""
    } else {
      $lnk.TargetPath = $ps
      $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $InstallRoot 'update-check.ps1')`""
    }
    $lnk.WorkingDirectory = $InstallRoot
    $lnk.IconLocation = "$exe,0"
    $lnk.Description = "Play on the UO Smallz shard (${ShardHost}:$ShardPort)"
    $lnk.Save()
  }
  Ok "Shortcuts: UO Smallz (desktop and Start menu)"

  Write-Host ""
  Write-Host "Done! Double-click 'UO Smallz' on your desktop." -ForegroundColor Green
  Write-Host "New player? Type any new username and password at the login screen;"
  Write-Host "the account is created the first time you log in."
  Write-Host ""
  $go = Read-Host "Start the game now? (Y/n)"
  if ($go -notmatch '^[nN]') { Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe) }
} catch {
  Die $_.Exception.Message
}
