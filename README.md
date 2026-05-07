# Dictado por voz local — Windows 11 + RTX 5070 Ti

Sistema de dictado **100% local** que reemplaza a Wispr Flow / Whisper en la nube. Presionas un hotkey global, hablas en español, sueltas, y el texto limpio aparece pegado en la app activa. Sub-segundo de latencia.

## Cómo se usa

1. **Hotkey**: mantén apretado `Ctrl + Alt + Espacio` mientras hablas. Suelta cuando terminás.
2. Beep agudo al iniciar grabación, beep grave al terminar (configurable).
3. El texto limpio se pega automáticamente con `Ctrl+V` en la app que tenga foco — terminal, navegador, Word, IDE, etc.

Funciona en cualquier aplicación que acepte pegar (que es básicamente todas).

## Instalación desde cero

Probado en Windows 11 con RTX 5070 Ti. Otros GPUs Blackwell (5070, 5080, 5090) deberían funcionar igual; otros sm_xx requieren cambiar `-DCMAKE_CUDA_ARCHITECTURES` en `install/02-build-whisper.ps1`.

```powershell
# 1. Clona el repo donde quieras (acá uso Tools, tú elige)
git clone https://github.com/<tu-usuario>/wispr-local.git
cd wispr-local

# 2. Instala prerequisites del sistema (PowerShell ELEVADA / Run as Administrator).
#    Driver NVIDIA, CUDA Toolkit 13.x, VS 2022 Build Tools, CMake, Git, Python 3.11, Ollama.
powershell -ExecutionPolicy Bypass -File .\install\01-prereqs.ps1

# 3. Si VS Build Tools fue instalado AHORA por el script anterior, integrá CUDA con MSBuild:
powershell -ExecutionPolicy Bypass -File .\install\01b-cuda-vs-integration.ps1

# 4. Cierra esta PowerShell, abre UNA NUEVA admin (para refrescar PATH con CUDA/CMake/Python).

# 5. Compila whisper.cpp con CUDA para sm_120 y baja el modelo de transcripción.
#    (Tarda 10-20 min: clone + cmake + msbuild + 1.6GB de modelo)
powershell -ExecutionPolicy Bypass -File .\install\02-build-whisper.ps1

# 6. Configura Ollama y baja el modelo LLM limpiador (~4.7GB).
#    (Tarda 5-15 min según conexión + ~30s de cold-start del daemon la primera vez)
powershell -ExecutionPolicy Bypass -File .\install\03-ollama-setup.ps1

# 7. Probalo manualmente (PowerShell normal, NO admin):
powershell -ExecutionPolicy Bypass -File .\bin\start-dictado.ps1
# Presiona Ctrl+Alt+Espacio, hablá, suelta. El texto debería pegarse en cualquier app.

# 8. Si te gusta, activá el autostart con Windows:
powershell -ExecutionPolicy Bypass -File .\install\04-autostart.ps1
```

**VRAM:** large-v3-turbo (~2 GB) + qwen2.5-7b-q4_K_M (~5 GB) ≈ 7 GB de los 16 disponibles.

**Cosas que te van a faltar:**
- Driver NVIDIA actualizado (≥581 para Blackwell). winget no maneja drivers oficiales — se baja manualmente de [nvidia.com](https://www.nvidia.com/Download/index.aspx) si está vencido.
- Tener Ollama abierto (la versión 0.23+ desacopló el tray app del daemon HTTP — `start-services.ps1` lo levanta solo).

## Cómo está armado

```
Mic (16kHz mono)
   ↓ sounddevice
WAV en memoria (sin disco)
   ↓ HTTP POST
whisper-server.exe (CUDA sm_120)
   modelo large-v3-turbo en VRAM (~2 GB)
   ↓ texto crudo en español
HTTP POST
   ↓
ollama (CUDA sm_120)
   qwen2.5:7b-instruct-q4_K_M en VRAM (~5 GB)
   limpia muletillas + puntuación + capitalización
   ↓ texto limpio
pyperclip + keyboard.send("ctrl+v")
   ↓
App con foco
```

Tres procesos vivos: `ollama.exe`, `whisper-server.exe`, `python.exe` (dictado.py). Total ~7 GB de VRAM ocupados de los 16 disponibles.

## Latencia medida (RTX 5070 Ti, audio de 5–7 s)

| Etapa | Tiempo |
|---|---|
| Transcribe (whisper) | 0.1–0.3 s |
| Clean (qwen) | 0.3–0.4 s |
| Paste (clipboard + Ctrl+V) | 0.06 s |
| **Total wall-clock** | **0.6–0.7 s** |

## Estructura del proyecto

```
<repo-root>\
├── README.md                       ← este archivo
├── LICENSE                         ← MIT
├── config.py                       ← TODA la configuración (hotkey, prompt, vocabulario, beep…)
├── dictado.py                      ← script principal (hotkey → transcribir → limpiar → pegar)
├── requirements.txt                ← deps Python (sounddevice, keyboard, requests…)
├── bin/
│   ├── start-services.ps1          ← levanta whisper-server + ollama serve (idempotente)
│   ├── start-dictado.ps1           ← wrapper: services + pip install + dictado.py
│   ├── start-dictado-silent.vbs    ← VBS shim que lanza start-dictado.ps1 oculto (autostart)
│   ├── stop-services.ps1           ← mata whisper-server, ollama, dictado.py
│   └── whisper.cpp/                ← (gitignored) repo clonado, compilado con CUDA sm_120
├── install/
│   ├── 01-prereqs.ps1              ← instala Driver/CUDA/VS BuildTools/CMake/Git/Python/Ollama
│   ├── 01b-cuda-vs-integration.ps1 ← copia los 4 .props/.targets/etc. de CUDA → VS
│   ├── 02-build-whisper.ps1        ← clona y compila whisper.cpp para sm_120
│   ├── 03-ollama-setup.ps1         ← levanta daemon + pull qwen2.5 + smoke test
│   └── 04-autostart.ps1            ← crea shortcut en Startup folder (.lnk → .vbs)
└── logs/                           ← (gitignored) creado en runtime
    ├── dictado.log                 ← cada dictada con timing (rec, transcribe, clean, paste)
    ├── whisper-server.stdout.log
    └── whisper-server.stderr.log
```

## Operación diaria

### Está corriendo

```powershell
Get-Process whisper-server, ollama, python -ErrorAction SilentlyContinue | Format-Table Name, Id, StartTime
Get-NetTCPConnection -LocalPort 8080,11434 -State Listen | Format-Table LocalPort, OwningProcess
```

Los tres procesos esperados y los dos puertos en LISTEN = sistema OK.

### Reiniciar todo

```powershell
cd <repo-root>
powershell -ExecutionPolicy Bypass -File .\bin\stop-services.ps1
Start-Process wscript.exe ".\bin\start-dictado-silent.vbs"
```

(Esperar ~30–60 s la primera vez de cada sesión por la carga del modelo en VRAM.)

### Apagar todo (sin matar el autostart)

```powershell
powershell -ExecutionPolicy Bypass -File .\bin\stop-services.ps1
```

### Desactivar el autostart

```powershell
powershell -ExecutionPolicy Bypass -File .\install\04-autostart.ps1 -Remove
```

(Quita `Dictado.lnk` de `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\`. La próxima vez que prendas la PC ya no se levanta solo. Para reactivarlo, correr `04-autostart.ps1` sin `-Remove`.)

### Logs

`logs/dictado.log` tiene cada dictada con timing por etapa:

```
[INFO] REC start
[INFO] REC stop (5.09s, 78624 samples)
[INFO] TRANSCRIBE 0.24s | raw='...'
[INFO] CLEAN 0.32s | clean='...'
[INFO] PASTE 0.06s | total=0.62s
```

Útil para detectar si la GPU se desactivó (un total de 30s+ es señal de CPU fallback) o si Qwen está reformulando demasiado.

## Configuración — `config.py`

Todo lo tuneable está en un solo archivo. Cambiar y reiniciar `dictado.py` (no hace falta tocar servicios).

### Cambiar el hotkey

```python
HOTKEY = "ctrl+alt+space"   # default
# alternativas razonables:
# HOTKEY = "ctrl+shift+space"   # si Alt te molesta (atajos con menú)
# HOTKEY = "alt+space"          # más corto, pero choca con menús
# HOTKEY = "f9"                 # tecla dedicada
```

Cualquier combinación válida del paquete `keyboard` sirve. Múltiples modificadores con `+`.

### Agregar términos al vocabulario custom

Edita `EXTRA_VOCAB` en `config.py`. Los items se inyectan al final del system prompt para que Qwen los respete EXACTOS:

```python
EXTRA_VOCAB = [
    "VS Code", "Cursor", "Vim",
    "Supabase", "PlanetScale", "Neon",
    "Vercel", "AWS", "Cloudflare",
    # tu nombre, marca, jerga interna...
    "TanStack Query", "Zustand", "tRPC",
]
```

### Cambiar el prompt de limpieza

`SYSTEM_PROMPT` controla el comportamiento del limpiador. Las reglas duras (no reformular, mantener términos técnicos) están explícitas. Si quieres más o menos agresivo, edita ahí. Ya hay 5 ejemplos few-shot que guían el modelo.

### Subir a Qwen 14B (mejor calidad, ~1 s extra de latencia)

Si los modelos chicos te dejan reformulaciones inconsistentes (típico con texto ya bien dicho), upgradear a 14B con un solo cambio:

```powershell
ollama pull qwen2.5:14b-instruct-q4_K_M
```

Después en `config.py`:

```python
OLLAMA_MODEL = "qwen2.5:14b-instruct-q4_K_M"
```

VRAM: ~9 GB para Qwen 14B + 2 GB para Whisper = 11 GB de los 16 disponibles. Entra cómodo.

Latencia esperada: ~1.0–1.5 s total (vs 0.6 s con 7B). Calidad notablemente mejor: respeta el input verbatim cuando ya está limpio.

### Activar/desactivar el beep

```python
BEEP_ENABLED = True   # False = silencioso
BEEP_START_FREQ = 800
BEEP_END_FREQ = 1000
```

### Mantener Qwen permanentemente en VRAM

`OLLAMA_KEEP_ALIVE = -1` (default) → modelo cargado infinito. Si quieres liberar VRAM cuando no usás:

```python
OLLAMA_KEEP_ALIVE = "5m"   # se descarga 5 min después de la última dictada
```

## Hardware y software validados

- **Windows 11**
- **NVIDIA RTX 5070 Ti** (Blackwell, sm_120, 16 GB VRAM)
- **Driver NVIDIA 591.86** (necesario ≥581 para Blackwell + CUDA 13)
- **CUDA Toolkit 13.2** (build cuda_13.2.r13.2)
- **Visual Studio 2022 Build Tools** + workload "Desktop development with C++" + Windows 11 SDK
- **CMake 4.3.2**
- **Git 2.53**
- **Python 3.11.9**
- **Ollama 0.23.1** (la versión nueva con launcher visual; el daemon HTTP en `127.0.0.1:11434` sigue funcionando igual que siempre)
- **whisper.cpp v1.8.4** (commit `c81b2da`), compilado con `GGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120`. El binario reporta `CUDA: ARCHS = 1200 | BLACKWELL_NATIVE_FP4 = 1`.
- **Modelo whisper**: `ggml-large-v3-turbo.bin` (1.6 GB)
- **Modelo LLM**: `qwen2.5:7b-instruct-q4_K_M` (4.9 GB en VRAM)

## Troubleshooting

### El hotkey no captura cuando hay una app Admin con foco

Es limitación de Windows: hooks de teclado de procesos non-admin no llegan a ventanas elevated. Solución: que `dictado.py` también corra elevated. Editar el shortcut `Dictado.lnk` (en Startup folder) → Propiedades → Avanzado → "Run as administrator". O cambiar a Task Scheduler con "Run with highest privileges".

### No suena el beep

Algunos sistemas mutearon `winsound.Beep` por defecto. Probar con auriculares conectados (usa el speaker de placa madre/HDMI). Si no, `BEEP_ENABLED = False` y mover a otro feedback.

### "Server did not come up" en `start-services.ps1`

La primera vez Ollama tarda 30–60 s descargando runners CUDA. Subsecuentes <2 s. Si pasa de 60 s, ver `logs/whisper-server.stderr.log` o ejecutar `ollama serve` en una terminal visible para ver el error real.

### Qwen reformula demasiado

Pasar a 14B (ver arriba) o agregar más ejemplos few-shot al `SYSTEM_PROMPT` mostrando el comportamiento que quieres.

### No me toma el micrófono correcto

Por default usa el dispositivo default del sistema (Configuración → Sound → Input). Si quieres forzar otro, editar `dictado.py`, función `Recorder.start()`, agregar `device=N` al `sd.InputStream` (ver dispositivos con `python -c "import sounddevice; print(sounddevice.query_devices())"`).

### Hubo un cambio de driver/CUDA y ahor