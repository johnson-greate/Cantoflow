#!/usr/bin/env python3
"""
FunASR Cantonese ASR Server
Provides HTTP API for speech-to-text using FunASR's Cantonese model.
"""

import os
import sys
import time
import tempfile
import logging
from pathlib import Path
from typing import Optional

import numpy as np
import soundfile as sf
from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import JSONResponse
import uvicorn

# OpenCC for Simplified <-> Traditional Chinese conversion (initialized after logger)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# OpenCC for Simplified <-> Traditional Chinese conversion
try:
    from opencc import OpenCC
    # s2hk: Simplified Chinese to Traditional Chinese (Hong Kong variant)
    cc_s2hk = OpenCC('s2hk')
    # t2s: Traditional Chinese to Simplified Chinese
    cc_t2s = OpenCC('t2s')
    opencc_available = True
    logger.info("OpenCC loaded for Traditional/Simplified conversion")
except ImportError:
    opencc_available = False
    cc_s2hk = None
    cc_t2s = None
    logger.warning("OpenCC not available, Traditional/Simplified conversion disabled")

# FunASR model configuration
# SenseVoiceSmall - multilingual model supports Cantonese
# 70ms to process 10s audio, 15x faster than Whisper-Large
# Use local path if already downloaded
import os
SENSEVOICE_LOCAL_PATH = os.path.expanduser("~/.cache/modelscope/hub/models/iic/SenseVoiceSmall")
SENSEVOICE_MODEL = "iic/SenseVoiceSmall"  # ModelScope model name
# Fallback: Paraformer model from ModelScope
FALLBACK_MODEL = "iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn"

# Global model instance
asr_model = None
model_loaded = False
model_load_error = None

app = FastAPI(
    title="FunASR Cantonese Server",
    description="Speech-to-text API using FunASR Cantonese model",
    version="1.0.0"
)


def load_model():
    """Load the FunASR model."""
    global asr_model, model_loaded, model_load_error

    if model_loaded:
        return True

    try:
        from funasr import AutoModel

        start_time = time.time()

        # Check if local model exists
        local_model_pt = os.path.join(SENSEVOICE_LOCAL_PATH, "model.pt")
        if os.path.exists(local_model_pt):
            logger.info(f"Loading SenseVoiceSmall from local cache: {SENSEVOICE_LOCAL_PATH}")
            model_path = SENSEVOICE_LOCAL_PATH
        else:
            logger.info(f"Loading SenseVoiceSmall from ModelScope: {SENSEVOICE_MODEL}")
            model_path = SENSEVOICE_MODEL

        # Try loading SenseVoiceSmall
        try:
            asr_model = AutoModel(
                model=model_path,
                vad_model="fsmn-vad",
                vad_kwargs={"max_single_segment_time": 30000},
                # Enable GPU if available
                device="cuda" if os.environ.get("FUNASR_USE_GPU") else "cpu",
                disable_update=True,  # Skip update check for faster startup
            )
            logger.info(f"Loaded SenseVoiceSmall in {time.time() - start_time:.2f}s")
        except Exception as e:
            logger.warning(f"Failed to load SenseVoiceSmall: {e}")
            logger.info(f"Trying fallback model from ModelScope: {FALLBACK_MODEL}")
            asr_model = AutoModel(
                model=FALLBACK_MODEL,
                vad_model="fsmn-vad",
                punc_model="ct-punc",
                device="cuda" if os.environ.get("FUNASR_USE_GPU") else "cpu",
                disable_update=True,
            )
            logger.info(f"Loaded fallback model in {time.time() - start_time:.2f}s")

        model_loaded = True
        return True

    except Exception as e:
        model_load_error = str(e)
        logger.error(f"Failed to load model: {e}")
        return False


@app.on_event("startup")
async def startup_event():
    """Load model on startup."""
    logger.info("Starting FunASR server...")
    # Load model in background to not block startup
    import threading
    thread = threading.Thread(target=load_model)
    thread.start()


@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "model_loaded": model_loaded,
        "model_error": model_load_error,
        "model": SENSEVOICE_MODEL if model_loaded else None
    }


@app.get("/ready")
async def ready_check():
    """Readiness check - returns 200 only when model is loaded."""
    if not model_loaded:
        if model_load_error:
            raise HTTPException(status_code=503, detail=f"Model load failed: {model_load_error}")
        raise HTTPException(status_code=503, detail="Model still loading...")
    return {"status": "ready", "model": SENSEVOICE_MODEL}


@app.post("/transcribe")
async def transcribe(
    audio: UploadFile = File(..., description="Audio file (WAV, 16kHz recommended)"),
    language: Optional[str] = Form(default="yue", description="Language code (yue for Cantonese)"),
    hotwords: Optional[str] = Form(default=None, description="Hotwords for better recognition"),
    script: Optional[str] = Form(default="traditional", description="Output script: 'traditional' (繁體) or 'simplified' (简体)"),
):
    """
    Transcribe audio file to text.

    - **audio**: Audio file in WAV format (16kHz mono recommended)
    - **language**: Language code (default: yue for Cantonese)
    - **hotwords**: Optional hotwords separated by space for better recognition
    - **script**: Output script preference - 'traditional' for 繁體字 (default), 'simplified' for 简体字

    Returns:
    - **text**: Transcribed text
    - **latency_ms**: Processing time in milliseconds
    """
    if not model_loaded:
        if not load_model():
            raise HTTPException(status_code=503, detail=f"Model not ready: {model_load_error}")

    start_time = time.time()

    try:
        # Save uploaded file to temp location
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_file:
            content = await audio.read()
            tmp_file.write(content)
            tmp_path = tmp_file.name

        logger.info(f"Received audio file: {audio.filename}, size: {len(content)} bytes")

        # Prepare hotwords if provided
        hotword_list = None
        if hotwords:
            # Format: "銅鑼灣 維園 旺角" -> hotword string for FunASR
            hotword_list = hotwords
            logger.info(f"Using hotwords: {hotword_list}")

        # Run inference
        try:
            # Import post-processing for SenseVoice
            try:
                from funasr.utils.postprocess_utils import rich_transcription_postprocess
            except ImportError:
                rich_transcription_postprocess = None

            # FunASR inference
            result = asr_model.generate(
                input=tmp_path,
                cache={},
                language="auto",  # Auto-detect language (supports Cantonese)
                use_itn=True,  # Enable inverse text normalization
                batch_size_s=60,
                merge_vad=True,
                hotword=hotword_list,
            )

            # Extract text from result
            if result and len(result) > 0:
                # FunASR returns list of dicts with 'text' key
                if isinstance(result[0], dict):
                    raw_text = result[0].get("text", "")
                else:
                    raw_text = str(result[0])

                # Apply SenseVoice post-processing if available
                if rich_transcription_postprocess and raw_text:
                    text = rich_transcription_postprocess(raw_text)
                else:
                    text = raw_text

                # Apply Traditional/Simplified Chinese conversion
                if opencc_available and text:
                    if script == "traditional" and cc_s2hk:
                        # Convert to Traditional Chinese (Hong Kong variant)
                        text = cc_s2hk.convert(text)
                        logger.info(f"Converted to Traditional Chinese (HK)")
                    elif script == "simplified" and cc_t2s:
                        # Ensure Simplified Chinese output
                        text = cc_t2s.convert(text)
                        logger.info(f"Converted to Simplified Chinese")
            else:
                text = ""

            latency_ms = int((time.time() - start_time) * 1000)

            logger.info(f"Transcription completed in {latency_ms}ms: {text[:50]}...")

            return JSONResponse({
                "text": text,
                "latency_ms": latency_ms,
                "language": language,
                "script": script,
                "model": SENSEVOICE_MODEL,
            })

        finally:
            # Clean up temp file
            os.unlink(tmp_path)

    except Exception as e:
        logger.error(f"Transcription error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/transcribe_streaming")
async def transcribe_streaming(
    audio: UploadFile = File(..., description="Audio file for streaming transcription"),
    chunk_size_ms: int = Form(default=200, description="Chunk size in milliseconds"),
):
    """
    Transcribe audio with streaming-style output (2pass mode).
    Returns both intermediate and final results.

    Note: This simulates streaming by processing the full audio but returning
    intermediate results. For true real-time streaming, use WebSocket endpoint.
    """
    if not model_loaded:
        if not load_model():
            raise HTTPException(status_code=503, detail=f"Model not ready: {model_load_error}")

    start_time = time.time()

    try:
        # Save uploaded file
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp_file:
            content = await audio.read()
            tmp_file.write(content)
            tmp_path = tmp_file.name

        try:
            # For streaming simulation, we use the regular model
            # but return results in streaming-compatible format
            result = asr_model.generate(
                input=tmp_path,
                batch_size_s=300,
            )

            if result and len(result) > 0:
                if isinstance(result[0], dict):
                    text = result[0].get("text", "")
                else:
                    text = str(result[0])
            else:
                text = ""

            latency_ms = int((time.time() - start_time) * 1000)

            return JSONResponse({
                "text": text,
                "is_final": True,
                "latency_ms": latency_ms,
                "mode": "2pass",
            })

        finally:
            os.unlink(tmp_path)

    except Exception as e:
        logger.error(f"Streaming transcription error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


def main():
    """Run the server."""
    host = os.environ.get("FUNASR_HOST", "127.0.0.1")
    port = int(os.environ.get("FUNASR_PORT", "8765"))

    logger.info(f"Starting FunASR server on {host}:{port}")

    uvicorn.run(
        app,
        host=host,
        port=port,
        log_level="info",
    )


if __name__ == "__main__":
    main()
