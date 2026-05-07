<#
================================================================================
 04-autostart.ps1 - Instala el dictado como autostart del usuario en Windows.
================================================================================
 Uso (NO admin, en PowerShell normal):
   cd <repo-root>
   powershell -ExecutionPolicy Bypass -File .\install\04-autostart.ps1

 Uso para desinstalar:
   .\install\04-autostart.ps1 -Remove

 Lo que hace:
   Crea un .lnk en %APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\
   apuntando a bin\start-dictado-silent.vbs. El VBS lanza PowerShell oculto
   que a su vez levanta servicios (idempotente) y dictado.py.

 Por qué VBS y no Task Scheduler:
   - No requiere admin.
   - VBS Run con flag 0 lanza la consola COMPLETAMENTE oculta (sin flash).
   - Lo mismo con powershell -WindowStyle Hidden via VBS.
================================================================================
#>

param(
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$vbsPath     = Join-Path $root 'bin\start-dictado-silent.vbs'
$startupDir  = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$shortcut    = Join-Path $startupDir 'Dictado.lnk'

if ($Remove) {
    if (Test-Path $shortcut) {
        Remove-Item $shortcut -Force
        Write-Host "Quitado: $shortcut" -ForegroundColor Green
    } else {
        Write-Host "No habia shortcut. Nada que hacer." -ForegroundColor Yellow
    }
    exit 0
}

# Verificaciones
if (-not (Test-Path $vbsPath)) {
    Write-Host "ERROR: $vbsPath no existe." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $startupDir)) {
    Write-Host "ERROR: Startup folder no existe ($startupDir)." -ForegroundColor Red
    exit 1
}

# Crear .lnk via WScript.Shell (sin dependencias externas)
$WshShell = New-Object -ComObject WScript.Shell
$lnk = $WshShell.CreateShortcut($shortcut)
$lnk.TargetPath       = "wscript.exe"
$lnk.Arguments        = "`"$vbsPath`""
$lnk.WorkingDirectory = $root
$lnk.IconLocation     = "C:\Windows\System32\shell32.dll,138"  # icono microfono-ish
$lnk.Description      = "Dictado por voz local (push-to-talk Ctrl+Alt+Espacio)"
$lnk.Save()

Write-Host "OK: shortcut creado en:" -ForegroundColor Green
Write-Host "    $shortcut"
Write-Host ""
Write-Host "Probarlo SIN reboot:"
Write-Host "    Start-Process -FilePath wscript.exe -ArgumentList `"$vbsPath`""
Write-Host ""
Write-Host "Para desactivar:"
Write-Host "    .\install\04-autostart.ps1 -Remove"
