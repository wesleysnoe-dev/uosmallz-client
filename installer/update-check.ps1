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
#   - Update: download the new client zip, check its SHA256 against the
#     release (asset digest and/or SHA256SUMS.txt), unpack it beside the old
#     one, carry settings.json, Data\ (profiles, macros, gumps) and any other
#     file of the player's across, swap the folders, and roll back on any
#     failure. The previous client stays as Client.old until the next update.
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

if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$Repo       = "wesleysnoe-dev/uosmallz-client"   # allowlist: never read from a file
$AssetName  = "UOSmallz-Client-win-x64.zip"
$SumsName   = "SHA256SUMS.txt"
$TimeoutSec = 6

function Get-Paths([string]$root) {
    return @{
        Root      = $root
        Client    = Join-Path $root "Client"
        New       = Join-Path $root "Client.new"
        Old       = Join-Path $root "Client.old"
        Exe       = Join-Path (Join-Path $root "Client") "TazUO.exe"
        Stamp     = Join-Path $root "client-version.json"
        Skip      = Join-Path $root "client-skipped.txt"
        Log       = Join-Path $root "launch.log"
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
    return @{
        Tag    = [string]$release.tag_name
        Url    = [string]$asset.browser_download_url
        Sha256 = $sha
        Notes  = [string]$release.body
        Name   = [string]$release.name
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

# ---- file checks ---------------------------------------------------------

function Get-Sha256([string]$path) {
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
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
    $old = [IO.Path]::GetFullPath($oldDir).TrimEnd('\', '/')
    foreach ($f in Get-ChildItem -LiteralPath $old -Recurse -File -Force) {
        $rel = $f.FullName.Substring($old.Length + 1)
        $dest = Join-Path $newDir $rel
        $mine = ($rel -eq "settings.json") -or ($rel -match '^Data[\\/]')
        if (-not $mine) {
            if (Test-Path -LiteralPath $dest) { continue }                 # the release's copy wins
            if ($rel -match '\.(dll|exe|so|dylib|pdb)$') { continue }       # program files never carried
            if ($rel -notmatch '[\\/]' -and $rel -match '\.json$') { continue } # TazUO.deps/runtimeconfig etc.
        }
        $dir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    }
}

# Unpack $zip, carry user files, swap. Throws on failure after restoring
# the original Client folder. Returns nothing on success.
function Install-ClientUpdate([string]$root, [string]$zip, [string]$expectedSha, [string]$tag) {
    $p = Get-Paths $root
    if (-not (Test-Sha256 $zip $expectedSha)) {
        throw "SHA256 mismatch for the downloaded client (expected $expectedSha)"
    }
    if (Test-Path -LiteralPath $p.New) { Remove-Item -LiteralPath $p.New -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $p.New -Force
    # a zip with one top folder: use what is inside it
    $top = @(Get-ChildItem -LiteralPath $p.New -Force)
    if ($top.Count -eq 1 -and $top[0].PSIsContainer -and -not (Test-Path -LiteralPath (Join-Path $p.New "TazUO.exe"))) {
        $inner = $top[0].FullName
        foreach ($c in Get-ChildItem -LiteralPath $inner -Force) { Move-Item -LiteralPath $c.FullName -Destination $p.New }
        Remove-Item -LiteralPath $inner -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath (Join-Path $p.New "TazUO.exe"))) {
        Remove-Item -LiteralPath $p.New -Recurse -Force -ErrorAction SilentlyContinue
        throw "the downloaded client has no TazUO.exe"
    }
    if (Test-Path -LiteralPath $p.Client) { Copy-UserFiles $p.Client $p.New }

    if (Test-Path -LiteralPath $p.Old) { Remove-Item -LiteralPath $p.Old -Recurse -Force }
    $movedOld = $false
    try {
        if (Test-Path -LiteralPath $p.Client) {
            Rename-Item -LiteralPath $p.Client -NewName "Client.old"
            $movedOld = $true
        }
        Rename-Item -LiteralPath $p.New -NewName "Client"
        Write-Stamp $p.Stamp $tag $expectedSha
    } catch {
        $err = $_
        # roll back: put the old client back exactly as it was
        try {
            if ($movedOld) {
                if (Test-Path -LiteralPath $p.Client) {
                    if (Test-Path -LiteralPath $p.New) { Remove-Item -LiteralPath $p.Client -Recurse -Force }
                    else { Rename-Item -LiteralPath $p.Client -NewName "Client.new" }
                }
                Rename-Item -LiteralPath $p.Old -NewName "Client"
            }
        } catch { }
        Remove-Item -LiteralPath $p.New -Recurse -Force -ErrorAction SilentlyContinue
        throw $err
    }
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

# A small "Downloading..." window while the zip comes down.
function Show-Busy([string]$text) {
    Add-Type -AssemblyName System.Windows.Forms
    $f = New-Object System.Windows.Forms.Form
    $f.Text = "UO Smallz"
    $f.Size = New-Object System.Drawing.Size(360, 110)
    $f.StartPosition = "CenterScreen"
    $f.FormBorderStyle = "FixedDialog"
    $f.ControlBox = $false
    $f.TopMost = $true
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.AutoSize = $false
    $l.Dock = "Fill"
    $l.TextAlign = "MiddleCenter"
    $f.Controls.Add($l)
    $f.Show()
    [System.Windows.Forms.Application]::DoEvents()
    return $f
}

function Start-Client([string]$root) {
    $p = Get-Paths $root
    if (Test-Path -LiteralPath $p.Exe) {
        Start-Process -FilePath $p.Exe -WorkingDirectory $p.Client
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
        $busy = $null
        try {
            $busy = Show-Busy "Downloading UO Smallz client $($info.Tag)..."
            Invoke-WebRequest -Uri $info.Url -OutFile $zip -Headers @{ "User-Agent" = "UOSmallz-launcher" } -UseBasicParsing
            if ($busy) { $busy.Close(); $busy = $null }
            Install-ClientUpdate $root $zip $info.Sha256 $info.Tag
            Write-LaunchLog $root "updated to $($info.Tag) ($($info.Sha256))"
        } catch {
            Write-LaunchLog $root "update $($info.Tag) failed, old client kept: $($_.Exception.Message)"
            try { Show-Message "The update could not be installed, so your current client was kept.`n`n$($_.Exception.Message)" "OK" "Warning" | Out-Null } catch { }
        } finally {
            if ($busy) { try { $busy.Close() } catch { } }
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-LaunchLog $root "launcher error: $($_.Exception.Message)"
    }
}

if (-not $NoMain) {
    try { Invoke-Launcher $InstallRoot } catch { }
    Start-Client $InstallRoot
}
