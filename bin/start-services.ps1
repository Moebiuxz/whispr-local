<#
================================================================================
 start-services.ps1 - Inicia whisper-server.exe y se asegura que Ollama corra.
================================================================================
 Idempotente. Se puede correr varias veces. Lanza solo lo que falta.

 - whisper-server.exe queda escuchando en 127.0.0.1:8080 con large-v3-turbo
   precargado en VRAM. POST /inference con multipart/form-data.
 - 'ollama serve' se levanta en :11434 si no está corriendo.

 Uso normal (no admin):
   powershell -ExecutionPolicy Bypass -File .\bin\start-services.ps1

 Para parar todo:
   .\bin\stop-services.ps1
================================================================================
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$whisperExe  = Join-Path $root 'bin\whisper.cpp\build\bin\Release\whisper-server.exe'
$whisperModel = Join-Path $root 'bin\whisper.cpp\models\ggml-large-v3-turbo.bin'
$logsDir     = Join-Path $root 'logs'

if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Force -Path $logsDir | Out-Null }

function Test-PortListening($port) {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    return [bool]$c
}

# ---- Ollama ----
Write-Host "Ollama..."
if (Test-PortListening 11434) {
    Write-Host "  OK: server on 11434" -ForegroundColor Green
} else {
    Write-Host "  Lanzando 'ollama serve'..."
    Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden | Out-Null
    # poll up to 60s
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        if (Test-PortListening 11434) { break }
    }
    if (Test-PortListening 11434) {
        Write-Host ("  OK: ollama up after ~{0}s" -f ($i+1)) -ForegroundColor Green
    } else {
        Write-Host "  WARN: ollama no levantó en 60s" -ForegroundColor Yellow
    }
}

# ---- Whisper-server ----
Write-Host "whisper-server..."
if (-not (Test-Path $whisperExe)) {
    Write-Host "ERROR: $whisperExe no existe. Recompilá con 02-build-whisper.ps1." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $whisperModel)) {
    Write-Host "ERROR: $whisperModel no existe." -ForegroundColor Red
    exit 1
}
if (Test-PortListening 8080) {
    Write-Host "  OK: server on 8080 ya activo." -ForegroundColor Green
} else {
    Write-Host "  Lanzando whisper-server (modelo: large-v3-turbo, port 8080)..."
    $stdoutLog = Join-Path $logsDir 'whisper-server.stdout.log'
    $stderrLog = Join-Path $logsDir 'whisper-server.stderr.log'
    $args = @(
        '-m', $whisperModel,
        '--host', '127.0.0.1',
        '--port', '8080',
        '-l', 'es',
        '-t', '4',
        '--print-progress'
    )
    Start-Process -FilePath $whisperExe `
                  -ArgumentList $args `
                  -WindowStyle Hidden `
                  -RedirectStandardOutput $stdoutLog `
                  -RedirectStandardError  $stderrLog | Out-Null
    # poll up to 60s
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        if (Test-PortListening 8080) { break }
    }
    if (Test-PortListening 8080) {
        Write-Host ("  OK: whisper-server up after ~{0}s" -f ($i+1)) -ForegroundColor Green
    } else {
        Write-Host "  ERROR: whisper-server no levantó en 60s. Ver $stderrLog" -ForegroundColor Red
        if (Test-Path $stderrLog) {
            Write-Host "  --- ultimas 20 lineas de stderr ---" -ForegroundColor Yellow
            Get-Content $stderrLog -Tail 20 | ForEach-Object { Write-Host "  $_" }
        }
    }
}

Write-Host ""
Write-Host "Estado:"
$ollamaState  = 'DOWN'; if (Test-PortListening 11434) { $ollamaState  = 'UP' }
$whisperState = 'DOWN'; if (Test-PortListening 8080)  { $whisperState = 'UP' }
Write-Host "  ollama         : $ollamaState"
Write-Host "  whisper-server : $whisperState"
