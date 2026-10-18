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
$ClientZipUrl  = "https://github.com/wesleysnoe-dev/uosmallz-client/releases/download/v1/UOSmallz-Client-win-x64.zip"
# Same community mirror and pinned file as the UO Offline installer.
$UODataUrl     = "https://mirror.ashkantra.de/fullclients/7.0.23.1.exe"
$UODataSha256  = "23b0548252bb4e6f39afbddac2e64f8deb862fbfaccb1303b87895d295e01839"
$UODataVersion = "7.0.23.1"
$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path

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
# Classic Felucca map art: same steps, URL and hash as the UO Offline
# installer (the UO Smallz server uses these map files, so the client must too).
# ---------------------------------------------------------------------------
$InstallT2AMap      = $true
if ($env:INSTALL_CLASSIC_MAP -eq "0") { $InstallT2AMap = $false }
$T2AInstallerUrl    = "https://download.uosecondage.com/UOSA_Client_Setup.exe"
$T2AInstallerSha256 = "674ec3cce9621bd8c1a8f2f69070e64e63191ce73d6f297236bf8f3b89d41ddf"
$T2AMulFiles        = @("map0.mul", "statics0.mul", "staidx0.mul")
# The 2002-area merge (map-merge.ps1) is OFF: the UO Smallz server map is the
# classic swap without the merge, and the client must match it exactly.
# Turn on (UOSMALLZ_MAP_MERGE=1) only if the server map gets merged too.
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

function SwapT2AMap {
  Banner "Installing classic Felucca map art (intact Magincia)"
  if (-not $InstallT2AMap) { Say "The classic map option is off; keeping modern map art."; return }
  if (-not $script:UOData) { Warn "UO data dir not resolved; skipping the classic map swap."; return }

  $backupDir = Join-Path $script:UOData "_backup-modern-map"
  if (Test-Path (Join-Path $backupDir "map0.mul")) {
    Say "Classic map already swapped (modern backup exists). Skipping."
    return
  }

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
      Warn "Could not get 7-Zip; keeping the modern map. Install 7-Zip from https://www.7-zip.org and re-run."
      return
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
    if (-not $srcMap.ContainsKey($f)) { Warn "Classic $f not found after extract; aborting swap (modern map kept)."; return }
  }

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
  New-Item -ItemType Directory -Force -Path $ClientDir, $DataRoot | Out-Null

  # 1. Game client
  Step "Game client (TazUO)"
  $zip = Join-Path $ScriptDir "UOSmallz-Client-win-x64.zip"
  if (-not (Test-Path -LiteralPath $zip)) {
    $zip = Join-Path $InstallRoot "UOSmallz-Client-win-x64.zip"
    Say "Downloading the client (~85 MB)..."
    Get-File $ClientZipUrl $zip
  }
  Say "Unpacking..."
  Expand-Archive -LiteralPath $zip -DestinationPath $ClientDir -Force
  $exe = Join-Path $ClientDir "TazUO.exe"
  if (-not (Test-Path -LiteralPath $exe)) {
    $e = Get-ChildItem -LiteralPath $ClientDir -Recurse -Filter "TazUO.exe" | Select-Object -First 1
    if (-not $e) { Die "TazUO.exe not found after unpacking the client." }
    $exe = $e.FullName
  }
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

  # 2b. Classic map art
  $script:UOData = $uoData
  $T2ASrcDir = Join-Path $InstallRoot "t2a-src"
  SwapT2AMap

  # 3. Settings
  Step "Client settings"
  $dataJson = $uoData.Replace([char]92, [char]47).Replace('"', '\"')
  $json = @"
{
  "username": "",
  "password": "",
  "ip": "$ShardHost",
  "port": $ShardPort,
  "ultimaonlinedirectory": "$dataJson",
  "clientversion": "$UODataVersion",
  "lastservernum": 1,
  "last_server_name": "$ShardName",
  "fps": 60,
  "encryption": 0,
  "saveaccount": false,
  "autologin": false,
  "plugins": []
}
"@
  $settings = Join-Path (Split-Path -Parent $exe) "settings.json"
  [IO.File]::WriteAllText($settings, $json, (New-Object Text.UTF8Encoding($false)))
  Ok "Wrote $settings"

  # 4. Shortcut
  Step "Desktop shortcut"
  $lnkPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "UO Smallz.lnk"
  $wsh = New-Object -ComObject WScript.Shell
  $lnk = $wsh.CreateShortcut($lnkPath)
  $lnk.TargetPath = $exe
  $lnk.WorkingDirectory = Split-Path -Parent $exe
  $lnk.IconLocation = "$exe,0"
  $lnk.Description = "Play on the UO Smallz shard (${ShardHost}:$ShardPort)"
  $lnk.Save()
  Ok "Desktop shortcut: UO Smallz"

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
