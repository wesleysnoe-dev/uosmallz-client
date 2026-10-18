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
