<#
================================================================================
 start-dictado.ps1 - Wrapper completo: instala deps Python, levanta servicios,
                     y corre dictado.py en una ventana visible.
================================================================================
 Uso normal:
   powershell -ExecutionPolicy Bypass -File .\bin\start-dictado.ps1

 Para autostart silencioso, ver start-dictado-silent.vbs (creado por
 04-autostart.ps1 en Fase 5).
================================================================================
#>

$ErrorActionPreference = 'Continue'
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $root

# 1. Servicios
& powershell -ExecutionPolicy Bypass -File "$root\bin\start-services.ps1"

# 2. Dependencias Python (idempotente: pip detecta si ya estan)
Write-Host ""
Write-Host "Verificando dependencias Python..."
& py -3.11 -m pip install --disable-pip-version-check -r "$root\requirements.txt" --quiet
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: pip install falló." -ForegroundColor Red
    exit 1
}

# 3. Dictado
Write-Host ""
Write-Host "================================================================"
Write-Host " Iniciando dictado.py — mantén Ctrl+Alt+Espacio para dictar"
Write-Host "================================================================"
& py -3.11 "$root\dictado.py"
