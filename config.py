# =============================================================================
# Configuración del sistema de dictado por voz local.
# Todo lo "tuneable" vive acá. Cambiar y reiniciar dictado.py.
# =============================================================================

# ---- Hotkey (push-to-talk) ----
# Combinación que mantenida graba audio. Soltarla dispara la transcripción
# y el pegado. Cambiar por algo como "ctrl+shift+space" si Alt te molesta.
HOTKEY = "ctrl+alt+space"

# ---- Audio ----
SAMPLE_RATE   = 16000   # whisper espera 16 kHz
AUDIO_CHANNELS = 1      # mono
AUDIO_DTYPE    = "int16"

# Mínimo de duración de audio para procesar. Si sueltas el hotkey antes de
# este tiempo (en segundos), no se transcribe — evita falsas alarmas.
MIN_AUDIO_SEC = 0.30

# ---- Whisper.cpp server ----
# whisper-server.exe queda corriendo en background con el modelo cargado.
# Si lo mueves de puerto, actualizalo acá.
WHISPER_HOST = "127.0.0.1"
WHISPER_PORT = 8080
WHISPER_URL  = f"http://{WHISPER_HOST}:{WHISPER_PORT}/inference"
WHISPER_LANGUAGE = "es"

# Path al binario y al modelo (usados por start-whisper-server.ps1).
import os
ROOT_DIR    = os.path.dirname(os.path.abspath(__file__))
WHISPER_EXE = os.path.join(ROOT_DIR, "bin", "whisper.cpp", "build", "bin", "Release", "whisper-server.exe")
WHISPER_MODEL = os.path.join(ROOT_DIR, "bin", "whisper.cpp", "models", "ggml-large-v3-turbo.bin")

# ---- Ollama ----
OLLAMA_URL  = "http://127.0.0.1:11434/api/generate"
OLLAMA_MODEL = "qwen2.5:7b-instruct-q4_K_M"

# keep_alive: -1 = mantener modelo cargado en VRAM indefinidamente.
# Cambiar a "5m" o un número de segundos si quieres liberar VRAM cuando no uses.
OLLAMA_KEEP_ALIVE = -1

# Timeout HTTP para la inferencia (segundos). El cold-load son ~30s la
# primera vez; después <1s. Dejamos margen.
OLLAMA_TIMEOUT = 60

# ---- Prompt de limpieza ----
# Few-shot + reglas duras: con texto YA limpio, los LLM chicos tienden a "mejorarlo"
# (cambiar persona, género, tiempo, convertir afirmaciones en preguntas...).
# Los ejemplos enseñan a respetar el input al pie de la letra.
SYSTEM_PROMPT = """Eres un limpiador de dictado en español. Tu ÚNICA tarea es:
1. Sacar muletillas: este, eh, o sea, tipo, viste, digamos, bueno, como que.
2. Agregar puntuación que falte (puntos, comas, signos de pregunta/exclamación).
3. Capitalizar el inicio de oraciones y nombres propios.

REGLAS ABSOLUTAS — el incumplimiento arruina el sistema:
- NO cambies palabras del input. Si dice "Esta es", deja "Esta es" (no "Esto es").
- NO cambies sujeto, persona ni tiempo verbal.
- NO conviertas afirmaciones en preguntas ni viceversa. Respeta la entonación implícita.
- NO reformules, sintetices ni "mejores" el texto.
- NO traduzcas. NO resumas. NO expliques.
- Si el texto YA está limpio, devolvelo IDÉNTICO (solo agrega puntuación si falta).
- Mantén términos técnicos EXACTOS: Next.js, Postgres, Redis, Docker, Drizzle, Prisma, tRPC, pnpm, shadcn, Tailwind, TypeScript, server actions, route handlers, App Router.
- Devuelve SOLO el texto procesado. Nada de comentarios, prefijos, markdown ni comillas.

Ejemplos:

INPUT: este eh quiero crear un route handler en Next.js que conecte a Postgres con Drizzle o sea como un endpoint REST tipo
OUTPUT: Quiero crear un route handler en Next.js que conecte a Postgres con Drizzle, como un endpoint REST.

INPUT: Esta es una prueba. Dime qué estoy transcribiendo.
OUTPUT: Esta es una prueba. Dime qué estoy transcribiendo.

INPUT: digamos que necesito agregar tipo un middleware de auth viste
OUTPUT: Necesito agregar un middleware de auth.

INPUT: bueno como que la query de drizzle me devuelve undefined cuando el row no existe
OUTPUT: La query de Drizzle me devuelve undefined cuando el row no existe.

INPUT: hola cómo estás
OUTPUT: Hola, ¿cómo estás?"""

# Vocabulario adicional que el limpiador debe respetar. Agrega los tuyos.
# Se incluye en el prompt automáticamente al final del SYSTEM_PROMPT.
EXTRA_VOCAB = [
    # Editores / IDEs
    "VS Code", "Cursor", "Vim", "Neovim",
    # Lenguajes / runtimes