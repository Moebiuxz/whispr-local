<#
================================================================================
 stop-services.ps1 - Mata whisper-server y ollama (y dictado.py si corre).
================================================================================
 Uso:  powershell -ExecutionPolicy Bypass -File .\bin\stop-services.ps1
================================================================================
#>

$ErrorActionPreference = 'SilentlyContinue'

Write-Host "Cerrando dictado.py (procesos python que importan keyboard)..."
Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" |
    Where-Object { $_.CommandLine -like '*dictado.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; "  killed PID $($_.ProcessId)" }

Write-Host "Cerrando whisper-server.exe..."
Get-Process whisper-server -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force
    "  killed PID $($_.Id)"
}

Write-Host "Cerrando ollama.exe (daemon, no el tray app)..."
# El tray app es 'ollama app.exe' — lo dejamos vivo. Solo matamos 'ollama.exe' (el serve).
Get-Process ollama -ErrorAction SilentlyContinue | ForEach-Object {
    Stop-Process -Id $_.Id -Force
    "  killed PID $($_.Id)"
}

Write-Host "Done."
