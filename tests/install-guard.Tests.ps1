# Plain-assert tests for install.ps1's run-from-inside-the-zip guard (no Pester needed).
#   pwsh -NoProfile -File tests/install-guard.Tests.ps1      (or Windows PowerShell 5.1)
# Exit code = number of failures.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$installer = (Resolve-Path (Join-Path $here "..\installer")).Path
$installPs1 = Join-Path $installer "install.ps1"

$script:fail = 0; $script:pass = 0
function Check([bool]$cond, [string]$name) {
    if ($cond) { $script:pass++; Write-Host "ok   $name" } else { $script:fail++; Write-Host "FAIL $name" -ForegroundColor Red }
}

# Test-ZipTempDir, taken out of install.ps1 without running the installer.
$ast = [Management.Automation.Language.Parser]::ParseFile($installPs1, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq "Test-ZipTempDir" }, $true) | Select-Object -First 1
Check ($null -ne $fn) "install.ps1 defines Test-ZipTempDir"
. ([ScriptBlock]::Create($fn.Extent.Text))

$temp = Join-Path ([IO.Path]::GetTempPath()) ""
Check (Test-ZipTempDir (Join-Path $temp "53f0fd5e-a5c5_uosmallz-client-main.zip.f9b\uosmallz-client-main\installer")) "Windows 11 zip temp folder (<id>_<name>.zip.<n>) is caught"
Check (Test-ZipTempDir (Join-Path $temp "Temp1_UOSmallz-Installer-win.zip\installer")) "older Windows zip temp folder (Temp1_<name>.zip) is caught"
Check (Test-ZipTempDir (Join-Path $temp "Temp2_UOSmallz-Installer-win.ZIP")) "case does not matter"
Check (-not (Test-ZipTempDir (Join-Path $temp "uosz-unzipped\installer"))) "an ordinary folder in Temp is left alone"
Check (-not (Test-ZipTempDir "C:\Users\me\Downloads\UOSmallz-Installer-win.zip\installer" $temp)) "a folder named like a zip outside Temp is left alone"
Check (-not (Test-ZipTempDir (Join-Path $env:LOCALAPPDATA "UOSmallz-installer"))) "the stable copy itself never relaunches again"
Check (-not (Test-ZipTempDir (Join-Path $temp "my.zipper\installer"))) "'.zipper' is not a zip"
Check (-not (Test-ZipTempDir "")) "no folder: no"

# End to end: the real install.ps1 run from a fake zip temp folder.
$ps = (Get-Process -Id $PID).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ("uosz-guard-" + [Guid]::NewGuid().ToString("N"))
$zipDir = Join-Path $root "abc123_uosmallz-client-main.zip.f9b\uosmallz-client-main\installer"
$copy = Join-Path $root "stable copy"
New-Item -ItemType Directory -Force -Path $zipDir | Out-Null
Copy-Item -Path (Join-Path $installer "*") -Destination $zipDir -Recurse -Force
$empty = Join-Path $root "empty.txt"; Set-Content -LiteralPath $empty "" -NoNewline

function Run-Installer([string]$dir) {
    $out = Join-Path $root ("out-" + [Guid]::NewGuid().ToString("N") + ".txt")
    $env:UOSMALLZ_INSTALLER_COPY = $copy
    $env:UOSMALLZ_RELAUNCH_ONLY = "1"
    try {
        $p = Start-Process -FilePath $ps -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$(Join-Path $dir 'install.ps1')`"") `
            -RedirectStandardOutput $out -RedirectStandardInput $empty -NoNewWindow -Wait -PassThru
    } finally {
        Remove-Item Env:\UOSMALLZ_INSTALLER_COPY, Env:\UOSMALLZ_RELAUNCH_ONLY -ErrorAction SilentlyContinue
    }
    return @{ Code = $p.ExitCode; Text = (Get-Content -LiteralPath $out -Raw) }
}

$r = Run-Installer $zipDir
Check ($r.Code -eq 0) "from inside the zip: the guard copies and relaunches (exit $($r.Code))"
Check ($r.Text -match [regex]::Escape("relaunch: $(Join-Path $copy 'install.ps1')")) "it relaunches the copy, not the temp folder"
$names = @(Get-ChildItem -LiteralPath $installer -File | ForEach-Object Name)
$copied = @($names | Where-Object { Test-Path -LiteralPath (Join-Path $copy $_) })
Check ($copied.Count -eq $names.Count) "every installer file is in the stable copy ($($copied.Count)/$($names.Count))"

Remove-Item -LiteralPath (Join-Path $zipDir "map-merge.ps1") -Force
Remove-Item -LiteralPath $copy -Recurse -Force
$r = Run-Installer $zipDir
Check ($r.Code -eq 1 -and $r.Text -match "map-merge.ps1 missing" -and $r.Text -match "Extract All") "files already gone: it stops and says to Extract All"
Check (-not (Test-Path -LiteralPath $copy)) "and copies nothing"

Remove-Item -LiteralPath $root -Recurse -Force

Write-Host ""
Write-Host "$script:pass passed, $script:fail failed"
exit $script:fail
