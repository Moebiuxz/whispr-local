<#
================================================================================
 02-build-whisper.ps1 - Clone and build whisper.cpp with CUDA for sm_120
================================================================================
 Run in elevated PowerShell:
   cd <repo-root>
   powershell -ExecutionPolicy Bypass -File .\install\02-build-whisper.ps1

 What it does:
   1. Clones ggml-org/whisper.cpp into bin\whisper.cpp.
   2. Configures the build with CMake (Visual Studio 17 2022 generator):
        -DGGML_CUDA=ON
        -DCMAKE_CUDA_ARCHITECTURES=120     # Blackwell sm_120
        -DBUILD_SHARED_LIBS=OFF
        -DWHISPER_BUILD_EXAMPLES=ON
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 (when CMake is 4.x)
   3. Builds Release.
   4. Downloads the large-v3-turbo model (~1.6 GB).
   5. Runs a benchmark on samples\jfk.wav to validate GPU usage.
   6. Writes install\report-02.txt for review.

 Idempotent. Use -Clean to wipe the build directory.
================================================================================
#>

param(
    [switch]$Clean,
    [switch]$SkipModelDownload
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

function Write-Section($t) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host (" " + $t)              -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

# ---- Setup paths ----
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$binDir    = Join-Path $root 'bin'
$repoDir   = Join-Path $binDir 'whisper.cpp'
$buildDir  = Join-Path $repoDir 'build'
$modelsDir = Join-Path $repoDir 'models'
$logFile   = Join-Path $root 'install\report-02.txt'

if (Test-Path $logFile) { Remove-Item $logFile -Force }
Start-Transcript -Path $logFile -Append | Out-Null

Write-Section "02-build-whisper.ps1 - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "root      = $root"
Write-Host "repoDir   = $repoDir"
Write-Host "buildDir  = $buildDir"

# ---- Verify prerequisites ----
Write-Section "Verifying prerequisites"

$missing = @()
foreach ($cmd in @('git','cmake','nvcc','nvidia-smi')) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $missing += $cmd }
}
if ($missing.Count -gt 0) {
    Write-Host "ERROR: missing commands in PATH: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "Close and reopen PowerShell, or re-run 01-prereqs.ps1." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host "OK: git, cmake, nvcc, nvidia-smi present." -ForegroundColor Green

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Host "ERROR: vswhere.exe not found. Reinstall VS 2022 Build Tools." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
$vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) {
    Write-Host "ERROR: VS 2022 with C++ workload not detected." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host "OK: VS 2022 at $vsPath" -ForegroundColor Green

# ---- Clone repo ----
Write-Section "Cloning ggml-org/whisper.cpp"

if (Test-Path $repoDir) {
    Write-Host "Repo already exists at $repoDir. Running git pull..."
    Push-Location $repoDir
    git fetch --all --tags 2>&1 | Out-Host
    git pull --ff-only 2>&1 | Out-Host
    Pop-Location
} else {
    git clone https://github.com/ggml-org/whisper.cpp.git $repoDir 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: git clone failed with exit $LASTEXITCODE" -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
}

Push-Location $repoDir
$commit  = (& git rev-parse HEAD).Trim()
$tag     = (& git describe --tags --abbrev=0 2>$null)
Pop-Location
Write-Host "Commit: $commit" -ForegroundColor Green
if ($tag) { Write-Host "Nearest tag: $tag" -ForegroundColor Green }

# ---- Clean ----
if ($Clean -and (Test-Path $buildDir)) {
    Write-Host ("Wiping " + $buildDir + " ...")
    Remove-Item -Recurse -Force $buildDir
}

# ---- CMake configure ----
Write-Section "CMake configure"

$cmakeVerLine = (& cmake --version | Select-Object -First 1)
$cmakeVer     = $cmakeVerLine -replace 'cmake version ',''
$cmakeMajor   = [int]($cmakeVer.Split('.')[0])
$policyFlag   = @()
if ($cmakeMajor -ge 4) {
    $policyFlag += '-DCMAKE_POLICY_VERSION_MINIMUM=3.5'
    Write-Host "CMake $cmakeVer (>=4): adding -DCMAKE_POLICY_VERSION_MINIMUM=3.5"
}

$cmakeArgs = @(
    '-S', $repoDir,
    '-B', $buildDir,
    '-G', 'Visual Studio 17 2022',
    '-A', 'x64',
    '-DGGML_CUDA=ON',
    '-DCMAKE_CUDA_ARCHITECTURES=120',
    '-DBUILD_SHARED_LIBS=OFF',
    '-DWHISPER_BUILD_EXAMPLES=ON',
    '-DCMAKE_BUILD_TYPE=Release'
)
$cmakeArgs += $policyFlag

Write-Host ("cmake " + ($cmakeArgs -join ' '))
& cmake @cmakeArgs 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: cmake configure failed (exit $LASTEXITCODE)." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# ---- Build ----
Write-Section "Building Release - this takes 5 to 10 minutes"

$buildArgs = @(
    '--build', $buildDir,
    '--config', 'Release',
    '--parallel'
)
& cmake @buildArgs 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: build failed (exit $LASTEXITCODE)." -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# ---- Detect binary ----
$candidateBins = @(
    (Join-Path $buildDir 'bin\Release\whisper-cli.exe'),
    (Join-Path $buildDir 'bin\Release\main.exe')
)
$cli = $candidateBins | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $cli) {
    Write-Host "ERROR: whisper-cli.exe / main.exe not found under bin\Release\" -ForegroundColor Red
    $relBin = Join-Path $buildDir 'bin\Release\'
    if (Test-Path $relBin) {
        Get-ChildItem $relBin | ForEach-Object { Write-Host "  $($_.Name)" }
    }
    Stop-Transcript | Out-Null
    exit 1
}
Write-Host "OK: binary = $cli" -ForegroundColor Green

# ---- Download model ----
Write-Section "Downloading model large-v3-turbo (~1.6 GB)"

$modelFile = Join-Path $modelsDir 'ggml-large-v3-turbo.bin'
if ((Test-Path $modelFile) -or $SkipModelDownload) {
    if ($SkipModelDownload) { Write-Host "Skip: SkipModelDownload flag set." }
    else { Write-Host "Model already present: $modelFile" }
} else {
    $dlScript = Join-Path $modelsDir 'download-ggml-model.cmd'
    if (-not (Test-Path $dlScript)) {
        Write-Host "ERROR: $dlScript not found (repo layout changed?)." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    Push-Location $modelsDir
    Write-Host "Running: $dlScript large-v3-turbo"
    & cmd /c "$dlScript large-v3-turbo" 2>&1 | Out-Host
    Pop-Location
    if (-not (Test-Path $modelFile)) {
        Write-Host "ERROR: model download failed. Check connection and retry." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
}
$modelSize = [math]::Round((Get-Item $modelFile).Length / 1MB, 1)
Write-Host "OK: model at $modelFile ($modelSize MB)" -ForegroundColor Green

# ---- Benchmark ----
Write-Section "Benchmark: transcribe samples\jfk.wav (GPU OK if wall-clock < 2s)"

$sampleWav = Join-Path $repoDir 'samples\jfk.wav'
$elapsed = $null
$usedCuda = $false
$transcOut = $null

if (-not (Test-Path $sampleWav)) {
    Write-Host "WARN: samples\jfk.wav not found. Skipping benchmark."
} else {
    Write-Host "Transcribing $sampleWav ..."
    Write-Host "VRAM before:"
    & nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader 2>&1 | Out-Host

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $cli -m $modelFile -f $sampleWav -l en -nt 2>&1 | Tee-Object -Variable transcOut | Out-Host
    $sw.Stop()
    $elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 2)

    Write-Host ""
    Write-Host "Wall-clock: $elapsed s" -ForegroundColor Cyan
    Write-Host "VRAM after:"
    & nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader 2>&1 | Out-Host

    if ($elapsed -gt 5) {
        Write-Host ""
        Write-Host "WARN: $elapsed s is slow. Likely running on CPU." -ForegroundColor Yellow
        Write-Host "Inspect log above: should mention 'CUDA' or 'cuBLAS'." -ForegroundColor Yellow
    } else {
        Write-Host "OK: timing consistent with GPU usage." -ForegroundColor Green
    }

    $joined = ($transcOut | Out-String)
    $usedCuda = ($joined -match 'CUDA' -or $joined -match 'cuBLAS')
    if ($usedCuda) {
        Write-Host "OK: binary log mentions CUDA/cuBLAS." -ForegroundColor Green
    } else {
        Write-Host "WARN: did not find 'CUDA' in output. Verify manually." -ForegroundColor Yellow
    }
}

# ---- Final report ----
Write-Section "Final report - copy this and paste it back"

$report = @()
$report += "## 02-build-whisper.ps1 result - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$report += ""
$report += "### Build"
$report += "- Repo:       $repoDir"
$report += "- Commit:     $commit"
if ($tag) { $report += "- Tag:        $tag" }
$report += "- VS:         $vsPath"
$report += "- CMake:      $cmakeVer"
$report += "- Binary:     $cli"
$report += ""
$report += "### Model"
$report += "- Path:       $modelFile"
$report += "- Size:       $modelSize MB"
$report += ""
$report += "### Benchmark"
if ($null -ne $elapsed) {
    $report += "- Sample:     samples\jfk.wav (~11s audio)"
    $report += "- Wall-clock: $elapsed s"
    $report += "- CUDA in log: $usedCuda"
} else {
    $report += "- skipped"
}
$report += ""
$report += "### nvidia-smi"
$report += (& nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>&1) -join "`n"

$reportText = $report -join "`n"
Add-Content -Path $logFile -Value "`n--- REPORT ---`n$reportText"
Write-Host $reportText

Write-Section "Done. Full log at install\report-02.txt"
Stop-Transcript | Out-Null
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       
