<#
================================================================================
 01b-cuda-vs-integration.ps1 - Copy CUDA MSBuild integration into VS Build Tools
================================================================================
 Why: when CUDA Toolkit is installed but Visual Studio (or VS Build Tools) was
 not detected at install time, the four MSBuild .props/.targets/.xml/.dll files
 do not get copied into VS's BuildCustomizations folder. Without those files,
 CMake's "Visual Studio 17 2022" generator fails with "No CUDA toolset found".

 This script:
   1. Locates the latest CUDA Toolkit and the latest VS 2022 (any edition).
   2. Copies the four files from CUDA\extras\visual_studio_integration\
      MSBuildExtensions to VS\MSBuild\Microsoft\VC\v170\BuildCustomizations.
   3. Verifies the copy.

 Run elevated:
   powershell -ExecutionPolicy Bypass -File .\install\01b-cuda-vs-integration.ps1
================================================================================
#>

$ErrorActionPreference = 'Stop'

function Write-Section($t) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host (" " + $t)              -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

# Admin?
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: must run as Administrator." -ForegroundColor Red
    exit 1
}

Write-Section "01b - CUDA + Visual Studio integration fix"

# ---- Locate CUDA ----
$cudaRoots = Get-ChildItem 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA' -Directory -ErrorAction SilentlyContinue |
             Sort-Object Name -Descending
if (-not $cudaRoots) {
    Write-Host "ERROR: No CUDA Toolkit found under 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'." -ForegroundColor Red
    exit 1
}
$cudaRoot = $cudaRoots[0].FullName
$cudaVer  = $cudaRoots[0].Name
$cudaExt  = Join-Path $cudaRoot 'extras\visual_studio_integration\MSBuildExtensions'
if (-not (Test-Path $cudaExt)) {
    Write-Host "ERROR: $cudaExt not found." -ForegroundColor Red
    Write-Host "       The CUDA Toolkit install seems incomplete (missing visual_studio_integration)." -ForegroundColor Red
    exit 1
}
Write-Host "CUDA Toolkit: $cudaRoot ($cudaVer)" -ForegroundColor Green

# ---- Locate VS 2022 ----
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Host "ERROR: vswhere.exe not found." -ForegroundColor Red
    exit 1
}
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    Write-Host "ERROR: VS 2022 with C++ workload not detected." -ForegroundColor Red
    exit 1
}
Write-Host "VS 2022:      $vsPath" -ForegroundColor Green

$vsCustomDir = Join-Path $vsPath 'MSBuild\Microsoft\VC\v170\BuildCustomizations'
if (-not (Test-Path $vsCustomDir)) {
    # Try old layout (just in case)
    $vsCustomDirAlt = Join-Path $vsPath 'Common7\IDE\VC\VCTargets\BuildCustomizations'
    if (Test-Path $vsCustomDirAlt) {
        $vsCustomDir = $vsCustomDirAlt
    } else {
        Write-Host "ERROR: BuildCustomizations folder not found in VS." -ForegroundColor Red
        Write-Host "       Tried: $vsCustomDir" -ForegroundColor Red
        Write-Host "       Tried: $vsCustomDirAlt" -ForegroundColor Red
        exit 1
    }
}
Write-Host "Target dir:   $vsCustomDir" -ForegroundColor Green

# ---- List source files ----
Write-Section "Files to copy"
$sources = Get-ChildItem $cudaExt -File
foreach ($f in $sources) {
    Write-Host "  $($f.Name)  ($([math]::Round($f.Length/1KB,1)) KB)"
}

# ---- Copy ----
Write-Section "Copying"
foreach ($f in $sources) {
    $dest = Join-Path $vsCustomDir $f.Name
    Copy-Item -Path $f.FullName -Destination $dest -Force
    Write-Host "  copied -> $dest"
}

# ---- Verify ----
Write-Section "Verification"
$expectedNames = @(
    "CUDA $($cudaVer.TrimStart('v')).props",
    "CUDA $($cudaVer.TrimStart('v')).targets",
    "CUDA $($cudaVer.TrimStart('v')).xml",
    "Nvda.Build.CudaTasks.$($cudaVer.TrimStart('v')).dll"
)
$ok = $true
foreach ($n in $expectedNames) {
    $p = Join-Path $vsCustomDir $n
    if (Test-Path $p) {
        Write-Host "  OK: $n" -ForegroundColor Green
    } else {
        Write-Host "  MISSING: $n  (expected at $p)" -ForegroundColor Yellow
        $ok = $false
    }
}

if ($ok) {
    Write-Section "Done. Re-run 02-build-whisper.ps1 now."
} else {
    Write-Section "Some expected files are missing - the version naming might differ."
    Write-Host "Check the contents of:" -ForegroundColor Yellow
    Write-Host "  $vsCustomDir" -ForegroundColor Yellow
    Get-ChildItem $vsCustomDir | ForEach-Object { Write-Host "    $($_.Name)" }
}
