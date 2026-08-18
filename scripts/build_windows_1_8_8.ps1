[CmdletBinding()]
param(
    [string]$Python = "python",
    [switch]$SkipToolDownload
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$BuildRoot = Join-Path $RepoRoot "build"
$DistRoot = Join-Path $RepoRoot "dist"
$ToolRoot = Join-Path $BuildRoot "windows-tools"
$HelperSource = Join-Path $ToolRoot "Helpers"
$PyInstallerDist = Join-Path $BuildRoot "windows-pyinstaller-dist"
$PyInstallerWork = Join-Path $BuildRoot "windows-pyinstaller-work"
$PackageName = "YT-Downloader-Pro-v1.8.8-Windows-x64"
$PackageRoot = Join-Path $DistRoot $PackageName
$ArchivePath = Join-Path $DistRoot "$PackageName.zip"
$SelfTestReport = Join-Path $DistRoot "windows-self-test.json"
$VersionFile = Join-Path $BuildRoot "windows-version-info.txt"

function Invoke-WindowedSelfTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath,
        [Parameter(Mandatory = $true)]
        [string]$ReportPath
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $ExecutablePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    [void]$psi.ArgumentList.Add('--self-test')
    [void]$psi.ArgumentList.Add('--self-test-report')
    [void]$psi.ArgumentList.Add([string]$ReportPath)

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($psi)
        if ($null -eq $process) {
            throw "Unable to start packaged Windows self-test: $ExecutablePath"
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Packaged Windows self-test failed. Report: $ReportPath"
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

Set-Location $RepoRoot
New-Item -ItemType Directory -Force -Path $BuildRoot, $DistRoot | Out-Null

if (-not $SkipToolDownload) {
    & $Python "scripts/fetch_windows_tools.py" --output $HelperSource
    if ($LASTEXITCODE -ne 0) { throw "Pinned Windows helper acquisition failed." }
}

& $Python "scripts/generate_windows_icon.py" --source "assets/AppIcon-1024.png" --output "assets/AppIcon.ico"
if ($LASTEXITCODE -ne 0) { throw "Windows icon generation failed." }

@"
VSVersionInfo(
  ffi=FixedFileInfo(filevers=(1, 8, 8, 0), prodvers=(1, 8, 8, 0), mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0, date=(0, 0)),
  kids=[StringFileInfo([StringTable('040904B0', [
    StringStruct('CompanyName', 'YT Downloader Pro'),
    StringStruct('FileDescription', 'YT Downloader Pro'),
    StringStruct('FileVersion', '1.8.8.0'),
    StringStruct('InternalName', 'YT Downloader Pro'),
    StringStruct('OriginalFilename', 'YT Downloader Pro.exe'),
    StringStruct('ProductName', 'YT Downloader Pro'),
    StringStruct('ProductVersion', '1.8.8')
  ])]), VarFileInfo([VarStruct('Translation', [1033, 1200])])]
)
"@ | Set-Content -Path $VersionFile -Encoding ascii

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $PyInstallerDist, $PyInstallerWork, $PackageRoot
Remove-Item -Force -ErrorAction SilentlyContinue $ArchivePath, $SelfTestReport

& $Python -m PyInstaller `
    --noconfirm `
    --clean `
    --windowed `
    --onedir `
    --name "YT Downloader Pro" `
    --icon "assets/AppIcon.ico" `
    --hidden-import yt_dlp_ejs `
    --collect-data yt_dlp_ejs `
    --version-file $VersionFile `
    --distpath $PyInstallerDist `
    --workpath $PyInstallerWork `
    "YT_downloader_188_windows.py"
if ($LASTEXITCODE -ne 0) { throw "PyInstaller Windows build failed." }

Copy-Item -Recurse (Join-Path $PyInstallerDist "YT Downloader Pro") $PackageRoot
New-Item -ItemType Directory -Force -Path (Join-Path $PackageRoot "Helpers") | Out-Null
Copy-Item (Join-Path $HelperSource "ffmpeg.exe") (Join-Path $PackageRoot "Helpers/ffmpeg.exe")
Copy-Item (Join-Path $HelperSource "ffprobe.exe") (Join-Path $PackageRoot "Helpers/ffprobe.exe")
Copy-Item (Join-Path $HelperSource "deno.exe") (Join-Path $PackageRoot "Helpers/deno.exe")
Copy-Item "README-Windows.txt" (Join-Path $PackageRoot "README-Windows.txt")
Copy-Item "THIRD_PARTY_NOTICES.md" (Join-Path $PackageRoot "THIRD_PARTY_NOTICES.txt")
New-Item -ItemType Directory -Force -Path (Join-Path $PackageRoot "tools") | Out-Null
Copy-Item -Recurse "tools/licenses" (Join-Path $PackageRoot "tools/licenses")

& $Python "scripts/check_windows_package.py" $PackageRoot --package-name $PackageName
if ($LASTEXITCODE -ne 0) { throw "Static Windows package check failed." }

$PackagedExe = Join-Path $PackageRoot "YT Downloader Pro.exe"
Invoke-WindowedSelfTest -ExecutablePath $PackagedExe -ReportPath $SelfTestReport
if (-not (Test-Path -LiteralPath $SelfTestReport -PathType Leaf)) {
    throw "Packaged self-test did not create report: $SelfTestReport"
}
$selfTest = Get-Content -LiteralPath $SelfTestReport -Raw | ConvertFrom-Json
if ($selfTest.status -ne 'ok') {
    throw "Packaged self-test did not report status ok: $SelfTestReport"
}

Compress-Archive -Path $PackageRoot -DestinationPath $ArchivePath -CompressionLevel Optimal
& $Python "scripts/check_windows_package.py" $ArchivePath --package-name $PackageName
if ($LASTEXITCODE -ne 0) { throw "Final Windows ZIP check failed." }

Write-Host "Created $ArchivePath"
Write-Host "Self-test report $SelfTestReport"
