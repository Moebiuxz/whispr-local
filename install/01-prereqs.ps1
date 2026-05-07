<#
================================================================================
 01-prereqs.ps1 — Instala prerequisites del sistema de dictado local
================================================================================
 EJECUTAR EN POWERSHELL ELEVADA (RUN AS ADMINISTRATOR):
   cd <repo-root>
   powershell -ExecutionPolicy Bypass -File .\install\01-prereqs.ps1

 Qué hace:
   1. Verifica winget.
   2. Detecta lo que ya está instalado (driver NVIDIA, CUDA, VS BT, CMake,
      Git, Python 3.11, Ollama) y reporta versiones.
   3. Instala lo que falta vía winget. NO reinstala lo que ya esté presente.
   4. Imprime un reporte final que copias y me pegas.

 Idempotente: correrlo dos veces es seguro.
 No reinicia nada por su cuenta. Si algún componente requiere reboot, te avisa.
================================================================================
#>

param(
    [switch]$DryRun  # con -DryRun no instala nada, solo reporta
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ----- helpers ---------------------------------------------------------------
function Write-Section($t) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host (" " + $t)              -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}

function Test-Cmd($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Get-WingetPkgVersion($id) {
    try {
        $out = winget list --id $id --exact 2>$null | Out-String
        if ($out -match $id) {
            $line = ($out -split "`r?`n") | Where-Object { $_ -match $id } | Select-Object -First 1
            return ($line -replace '\s+',' ').Trim()
        }
    } catch {}
    return $null
}

function Invoke-Winget($id, $extra = @()) {
    if ($DryRun) {
        Write-Host "[DRY-RUN] winget install --id $id $($extra -join ' ')" -ForegroundColor Yellow
        return @{ Success = $true; Output = "[dry-run]" }
    }
    Write-Host "  Instalando $id ..." -ForegroundColor Yellow
    $args = @('install','--id',$id,'--exact','--accept-package-agreements','--accept-source-agreements','--silent')
    $args += $extra
    $output = & winget @args 2>&1 | Out-String
    return @{ Success = ($LASTEXITCODE -eq 0); Output = $output; ExitCode = $LASTEXITCODE }
}

# ----- inicio ---------------------------------------------------------------
Write-Section "Dictado — Setup de prerequisites"

# Admin?
$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: este script tiene que correr como Administrador." -ForegroundColor Red
    Write-Host "       Cierra esta ventana y abre PowerShell como admin." -ForegroundColor Red
    exit 1
}
Write-Host "OK: corriendo como Administrador." -ForegroundColor Green

# winget?
if (-not (Test-Cmd 'winget')) {
    Write-Host "ERROR: winget no encontrado. Instala App Installer desde Microsoft Store." -ForegroundColor Red
    exit 1
}
Write-Host "OK: winget disponible — $((winget --version))" -ForegroundColor Green

# ----- detección ------------------------------------------------------------
Write-Section "Estado actual del sistema"

$status = [ordered]@{}

# Driver NVIDIA
try {
    $smi = & nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader 2>$null
    $status['NVIDIA Driver'] = if ($smi) { $smi } else { 'NO DETECTADO' }
} catch { $status['NVIDIA Driver'] = 'NO DETECTADO' }

# CUDA Toolkit
try {
    $nvcc = & nvcc --version 2>$null | Out-String
    if ($nvcc -match 'release (\d+\.\d+)') { $status['CUDA Toolkit'] = "v$($Matches[1])" }
    else { $status['CUDA Toolkit'] = 'NO INSTALADO' }
} catch { $status['CUDA Toolkit'] = 'NO INSTALADO' }

# Visual Studio Build Tools (busca cl.exe en VS 2022)
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    $status['VS 2022 Build Tools (C++)'] = if ($vsPath) { $vsPath } else { 'NO DETECTADO' }
} else {
    $status['VS 2022 Build Tools (C++)'] = 'NO DETECTADO (vswhere ausente)'
}

# CMake
if (Test-Cmd 'cmake') {
    $cmv = (& cmake --version 2>$null | Select-Object -First 1)
    $status['CMake'] = $cmv
} else { $status['CMake'] = 'NO INSTALADO' }

# Git
if (Test-Cmd 'git') {
    $status['Git'] = (& git --version 2>$null)
} else { $status['Git'] = 'NO INSTALADO' }

# Python 3.11
$py311 = $null
if (Test-Cmd 'py') {
    $py311 = (& py -3.11 --version 2>$null)
}
if (-not $py311 -and (Test-Cmd 'python')) {
    $pyv = (& python --version 2>$null)
    if ($pyv -match '3\.11') { $py311 = $pyv }
}
$status['Python 3.11'] = if ($py311) { $py311 } else { 'NO INSTALADO' }

# Ollama
if (Test-Cmd 'ollama') {
    $status['Ollama'] = (& ollama --version 2>$null) -join ' '
} else { $status['Ollama'] = 'NO INSTALADO' }

$status.GetEnumerator() | ForEach-Object {
    $color = if ($_.Value -match 'NO INSTALADO|NO DETECTADO') { 'Red' } else { 'Green' }
    Write-Host ("  {0,-30} {1}" -f $_.Key, $_.Value) -ForegroundColor $color
}

# ----- instalación -----------------------------------------------------------
Write-Section "Instalación de lo que falta"

$results = @{}

# 1. Driver NVIDIA — winget no maneja drivers oficiales.
#    Si el driver está vencido para Blackwell (necesitas >=581), te aviso.
$driverOK = $false
if ($status['NVIDIA Driver'] -match '(\d+)\.(\d+)') {
    $major = [int]$Matches[1]
    if ($major -ge 581) { $driverOK = $true }
}
if (-not $driverOK) {
    Write-Host ""
    Write-Host "AVISO — Driver NVIDIA: bájalo manualmente desde:" -ForegroundColor Yellow
    Write-Host "  https://www.nvidia.com/Download/index.aspx" -ForegroundColor Yellow
    Write-Host "  Producto: GeForce RTX 5070 Ti — Versión >= 581.x (Studio o Game Ready)" -ForegroundColor Yellow
    Write-Host "  Si ya lo tienes y nvidia-smi reporta menor, actualiza antes de seguir." -ForegroundColor Yellow
    $results['NVIDIA Driver'] = 'MANUAL — ver mensaje arriba'
} else {
    $results['NVIDIA Driver'] = "OK ($($status['NVIDIA Driver']))"
}

# 2. CUDA Toolkit 13.2
if ($status['CUDA Toolkit'] -match 'v(\d+)\.(\d+)') {
    $cmaj = [int]$Matches[1]; $cmin = [int]$Matches[2]
    if (($cmaj -gt 13) -or ($cmaj -eq 13 -and $cmin -ge 0) -or ($cmaj -eq 12 -and $cmin -ge 8)) {
        $results['CUDA Toolkit'] = "OK ($($status['CUDA Toolkit']))"
    } else {
        Write-Host "CUDA actual ($($status['CUDA Toolkit'])) NO sirve para sm_120. Instalando 13.2..."
        $r = Invoke-Winget 'Nvidia.CUDA' @('--version','13.2')
        $results['CUDA Toolkit'] = if ($r.Success) { 'INSTALADO 13.2' } else { "FALLO: $($r.ExitCode)" }
    }
} else {
    $r = Invoke-Winget 'Nvidia.CUDA'
    $results['CUDA Toolkit'] = if ($r.Success) { 'INSTALADO' } else { "FALLO: $($r.ExitCode)" }
}

# 3. VS Build Tools 2022 — workload Desktop development with C++
if ($status['VS 2022 Build Tools (C++)'] -match 'NO DETECTADO') {
    # Microsoft.VisualStudio.2022.BuildTools NO instala workloads por default.
    # winget no permite pasar --override fácil con espacios; usamos un override file.
    Write-Host "Instalando VS 2022 Build Tools con workload C++ (esto tarda ~10-15 min)..."
    $args = @(
        '--override',
        '"--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended"'
    )
    $r = Invoke-Winget 'Microsoft.VisualStudio.2022.BuildTools' $args
    $results['VS 2022 Build Tools'] = if ($r.Success) { 'INSTALADO con workload C++' } else { "FALLO: $($r.ExitCode)" }
} else {
    $results['VS 2022 Build Tools'] = "OK ($($status['VS 2022 Build Tools (C++)']))"
}

# 4. CMake
if ($status['CMake'] -match 'NO INSTALADO') {
    $r = Invoke-Winget 'Kitware.CMake'
    $results['CMake'] = if ($r.Success) { 'INSTALADO' } else { "FALLO: $($r.ExitCode)" }
} else { $results['CMake'] = "OK ($($status['CMake']))" }

# 5. Git
if ($status['Git'] -match 'NO INSTALADO') {
    $r = Invoke-Winget 'Git.Git'
    $results['Git'] = if ($r.Success) { 'INSTALADO' } else { "FALLO: $($r.ExitCode)" }
} else { $results['Git'] = "OK ($($status['Git']))" }

# 6. Python 3.11
if ($status['Python 3.11'] -match 'NO INSTALADO') {
    $r = Invoke-Winget 'Python.Python.3.11'
    $results['Python 3.11'] = if ($r.Success) { 'INSTALADO' } else { "FALLO: $($r.ExitCode)" }
} else { $results['Python 3.11'] = "OK ($($status['Python 3.11']))" }

# 7. Ollama
if ($status['Ollama'] -match 'NO INSTALADO') {
    $r = Invoke-Winget 'Ollama.Ollama'
    $results['Ollama'] = if ($r.Success) { 'INSTALADO' } else { "FALLO: $($r.ExitCode)" }
} else { $results['Ollama'] = "OK ($($status['Ollama']))" }

# ----- reporte final --------------------------------------------------------
Write-Section "Reporte final — copia esto y mandámelo"

$report = @()
$report += "## Resultado de 01-prereqs.ps1 — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$report += ""
$report += "### Estado pre-instalación"
$status.GetEnumerator() | ForEach-Object { $report += ("- {0}: {1}" -f $_.Key, $_.Value) }
$report += ""
$report += "### Resultado de instalación"
$results.GetEnumerator() | ForEach-Object { $report += ("- {0}: {1}" -f $_.Key, $_.Value) }
$report += ""
$report += "### Verificación post-instalación (re-detección)"

# Re-detect (algunos requieren reabrir terminal; intentamos refrescar PATH)
$env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')

$post = [ordered]@{}
try { $post['nvidia-smi'] = (& nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader 2>$null) -join '' } catch { $post['nvidia-smi'] = 'falló' }
try { $post['nvcc']       = ((& nvcc --version 2>$null) -join ' ') -replace '\s+',' ' } catch { $post['nvcc'] = 'falló' }
try { $post['cmake']      = (& cmake --version 2>$null | Select-Object -First 1) } catch { $post['cmake'] = 'falló' }
try { $post['git']        = (& git --version 2>$null) } catch { $post['git'] = 'falló' }
try { $post['python']     = if (Test-Cmd 'py') { (& py -3.11 --version 2>$null) } else { 'py launcher ausente' } } catch { $post['python'] = 'falló' }
try { $post['ollama']     = (& ollama --version 2>$null) -join ' ' } catch { $post['ollama'] = 'falló' }

$post.GetEnumerator() | ForEach-Object { $report += ("- {0}: {1}" -f $_.Key, $_.Value) }

$report += ""
$report += "### Notas"
$report += "- Si algún componente recién instalado dice 'falló' o 'no encontrado', cierra y reabre esta PowerShell para que se actualice el PATH, y vuelve a correr este script."
$report += "- Si el driver NVIDIA es <581, instálalo manualmente desde nvidia.com antes de seguir."

$report -join "`n" | Tee-Object -FilePath (Join-Path $PSScriptRoot 'report-01.txt') | Write-Host

Write-Section "Done. El reporte también quedó guardado en install\report-01.txt"
