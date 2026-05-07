"""
dictado.py — Sistema de dictado por voz local.
Hotkey push-to-talk → graba mic → whisper.cpp → Ollama (Qwen) → clipboard → Ctrl+V

Run:
    python dictado.py

Para arrancar todo (whisper-server + ollama + dictado), usar:
    bin/start-dictado.ps1   (modo dev, ventana visible)
    bin/start-dictado-silent.vbs  (autostart, sin ventana)
"""
import io
import os
import sys
import time
import json
import wave
import queue
import logging
import threading
import tempfile
import subprocess

import numpy as np
import sounddevice as sd
import keyboard
import pyperclip
import requests

import config

# -------------------------------------------------------------------- logging
os.makedirs(os.path.dirname(config.LOG_FILE), exist_ok=True)
logging.basicConfig(
    level=getattr(logging, config.LOG_LEVEL),
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(config.LOG_FILE, encoding="utf-8"),
        logging.StreamHandler(sys.stderr),
    ],
)
log = logging.getLogger("dictado")

# -------------------------------------------------------------------- helpers
def beep(freq, dur_ms):
    if not config.BEEP_ENABLED:
        return
    try:
        import winsound
        winsound.Beep(int(freq), int(dur_ms))
    except Exception:
        pass

def is_whisper_up() -> bool:
    try:
        r = requests.get(f"http://{config.WHISPER_HOST}:{config.WHISPER_PORT}/", timeout=2)
        return r.status_code in (200, 404)  # whisper-server may return 404 on root
    except Exception:
        return False

def is_ollama_up() -> bool:
    try:
        r = requests.get("http://127.0.0.1:11434/api/tags", timeout=3)
        return r.status_code == 200
    except Exception:
        return False

def warmup_ollama():
    """Disparar una inferencia chiquita para asegurar que el modelo está cargado en VRAM."""
    try:
        log.info("Warmup Ollama...")
        requests.post(
            config.OLLAMA_URL,
            json={
                "model": config.OLLAMA_MODEL,
                "prompt": "ok",
                "stream": False,
                "keep_alive": config.OLLAMA_KEEP_ALIVE,
                "options": {"temperature": 0.0, "num_predict": 1},
            },
            timeout=120,
        )
        log.info("Ollama warmed up.")
    except Exception as e:
        log.warning("Warmup Ollama falló: %s", e)

def wait_for_services(timeout=120):
    """Esperar a que whisper-server y Ollama estén listos."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        w = is_whisper_up()
        o = is_ollama_up()
        if w and o:
            log.info("Whisper-server y Ollama OK.")
            return True
        log.info("Esperando servicios... whisper=%s ollama=%s", w, o)
        time.sleep(2)
    return False

# -------------------------------------------------------------------- audio
class Recorder:
    """Captura del mic en chunks de int16 mono 16kHz."""
    def __init__(self):
        self._chunks = []
        self._stream = None
        self._lock = threading.Lock()

    def start(self):
        with self._lock:
            self._chunks = []
            self._stream = sd.InputStream(
                samplerate=config.SAMPLE_RATE,
                channels=config.AUDIO_CHANNELS,
                dtype=config.AUDIO_DTYPE,
                callback=self._cb,
            )
            self._stream.start()

    def _cb(self, indata, frames, time_info, status):
        if status:
            log.debug("audio status: %s", status)
        # indata: shape (frames, channels). copy is mandatory.
        self._chunks.append(indata.copy())

    def stop(self) -> np.ndarray:
        with self._lock:
            if self._stream is None:
                return np.array([], dtype=np.int16)
            try:
                self._stream.stop()
                self._stream.close()
            finally:
                self._stream = None
            if not self._chunks:
                return np.array([], dtype=np.int16)
            audio = np.concatenate(self._chunks, axis=0).flatten()
            self._chunks = []
            return audio

def write_wav_bytes(audio_int16: np.ndarray, sample_rate: int) -> bytes:
    """Devuelve un WAV PCM 16-bit en memoria (sin tocar disco)."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)  # int16
        w.setframerate(sample_rate)
        w.writeframes(audio_int16.tobytes())
    return buf.getvalue()

# -------------------------------------------------------------------- pipeline
def transcribe(wav_bytes: bytes) -> str:
    """POST al whisper-server. Devuelve texto crudo."""
    files = {"file": ("dictado.wav", wav_bytes, "audio/wav")}
    data  = {
        "language": config.WHISPER_LANGUAGE,
        "response_format": "json",
    }
    # Initial prompt opcional: sesga el decodificador hacia nuestro dominio
    # para reducir alucinaciones. Solo se envía si está habilitado en config.
    initial = getattr(config, "WHISPER_INITIAL_PROMPT", "") or ""
    if initial and getattr(config, "WHISPER_USE_INITIAL_PROMPT", False):
        data["prompt"] = initial
    r = requests.post(config.WHISPER_URL, files=files, data=data, timeout=30)
    r.raise_for_status()
    js = r.json()
    # whisper.cpp server devuelve {"text": "..."} (algunas versiones {"transcription":[...]})
    text = js.get("text") or js.get("transcription") or ""
    if isinstance(text, list):
        text = " ".join(t.get("text", "") for t in text)
    # whisper-server inserta \n al cortar segmentos largos; los aplastamos
    # para que Qwen no se confunda con saltos de línea en medio de palabras.
    text = " ".join(text.split())
    return text.strip()

def build_system_prompt() -> str:
    base = config.SYSTEM_PROMPT
    if config.EXTRA_VOCAB:
        base += " Vocabulario adicional a respetar EXACTO: " + ", ".join(config.EXTRA_VOCAB) + "."
    return base

def clean(text: str) -> str:
    """Limpia el texto crudo con Qwen via Ollama."""
    payload = {
        "model": config.OLLAMA_MODEL,
        "prompt": text,
        "system": build_system_prompt(),
        "stream": False,
        "keep_alive": config.OLLAMA_KEEP_ALIVE,
        "options": {"temperature": 0.0},
    }
    r = requests.post(config.OLLAMA_URL, json=payload, timeout=config.OLLAMA_TIMEOUT)
    r.raise_for_status()
    out = r.json().get("response", "").strip()

    # Guardrail: detecta cuando Qwen "responde" al input en vez de limpiarlo.
    # Síntomas: comienza con frases meta ("Por favor", "Claro,", "Aquí tienes")
    # o el output es desproporcionadamente más largo/corto que el input.
    META_PREFIXES = (
        "por favor", "aquí tienes", "aqui tienes", "claro,", "claro ",
        "entendido", "perfecto,", "ok,", "como asistente", "lo siento",
    )
    out_lower = out.lower()
    looks_meta = any(out_lower.startswith(p) for p in META_PREFIXES)
    len_ratio = len(out) / max(len(text), 1)
    too_different = len_ratio > 1.8 or len_ratio < 0.4
    if looks_meta or too_different:
        log.warning(
            "Qwen meta-respuesta detectada (ratio=%.2f, meta=%s). Pego raw.",
            len_ratio, looks_meta
        )
        return text
    return out

def paste(text: str):
    """Copia al clipboard y simula Ctrl+V."""
    pyperclip.copy(text)
    if config.AUTO_PASTE:
        time.sleep(config.PASTE_DELAY)
        keyboard.send("ctrl+v")

# -------------------------------------------------------------------- ptt
class PushToTalk:
    """Detecta press y release de un combo tipo 'ctrl+alt+space' y dispara callbacks.
    Implementado con polling (20ms) en lugar de hooks para evitar problemas con apps Admin."""
    def __init__(self, hotkey: str, on_start, on_stop):
        self.keys = [k.strip().lower() for k in hotkey.split("+")]
        self.on_start = on_start
        self.on_stop = on_stop
        self.active = False
        self._stop = threading.Event()
        self._t = threading.Thread(target=self._loop, daemon=True)

    def start(self):
        self._t.start()

    def stop(self):
        self._stop.set()

    def _all_pressed(self):
        try:
            return all(keyboard.is_pressed(k) for k in self.keys)
        except Exception as e:
            log.error("is_pressed falló: %s", e)
            return False

    def _loop(self):
        while not self._stop.is_set():
            pressed = self._all_pressed()
            if pressed and not self.active:
                self.active = True
                try:
                    self.on_start()
                except Exception:
                    log.exception("on_start error")
                    self.active = False
            elif not pressed and self.active:
                self.active = False
                try:
                    self.on_stop()
                except Exception:
                    log.exception("on_stop error")
            time.sleep(0.02)

# -------------------------------------------------------------------- main
class App:
    def __init__(self):
        self.recorder = Recorder()
        self.recording_started_at = 0.0
        self._busy = threading.Lock()

    def start_recording(self):
        if not self._busy.acquire(blocking=False):
            log.info("Ya estoy procesando — ignoro start.")
            return
        try:
            log.info("REC start")
            beep(config.BEEP_START_FREQ, config.BEEP_START_MS)
            self.recording_started_at = time.time()
            self.recorder.start()
        except Exception:
            log.exception("Error iniciando recording")
            self._busy.release()

    def stop_recording(self):
        try:
            audio = self.recorder.stop()
            elapsed = time.time() - self.recording_started_at
            log.info("REC stop (%.2fs, %d samples)", elapsed, len(audio))
            if elapsed < config.MIN_AUDIO_SEC or len(audio) == 0:
                log.info("Audio muy corto, descarto.")
                return

            t0 = time.time()
            wav = write_wav_bytes(audio, config.SAMPLE_RATE)
            t1 = time.time()
            try:
                raw = transcribe(wav)
            except Exception as e:
                log.error("Whisper falló: %s", e)
                return
            t2 = time.time()
            log.info("TRANSCRIBE %.2fs | raw=%r", t2 - t1, raw[:120])
            if not raw:
                log.info("Transcripción vacía.")
                return

            try:
                clean_text = clean(raw)
            except Exception as e:
                log.error("Ollama falló: %s — pego texto crudo.", e)
                clean_text = raw
            t3 = time.time()
            log.info("CLEAN %.2fs | clean=%r", t3 - t2, clean_text[:120])

            paste(clean_text)
            t4 = time.time()
            log.info("PASTE %.2fs | total=%.2fs", t4 - t3, t4 - t0)
            beep(config.BEEP_END_FREQ, config.BEEP_END_MS)
        finally:
            self._busy.release()

def main():
    log.info("dictado.py arranca. Hotkey=%s", config.HOTKEY)

    if not wait_for_services(timeout=180):
        log.error("Whisper-server u Ollama no respondieron. Asegurate de iniciarlos primero (ver bin/start-services.ps1).")
        sys.exit(1)

    warmup_ollama()

    app = App()
    ptt = PushToTalk(config.HOTKEY, app.start_recording, app.stop_recording)
    ptt.start()

    log.info("Listo. Mantén %s para dictar.", config.HOTKEY)
    try:
        # Bloquea hasta Ctrl+C / cierre. keyboard.wait() es nuestro ciclo principal.
        keyboard.wait("esc+ctrl+shift")  # combo improbable que no se usa, solo para bloquear
    except KeyboardInterrupt:
        pass
    finally:
        ptt.stop()
        log.info("Bye.")

if __name__ == "__main__":
    main()
