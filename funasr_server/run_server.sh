#!/bin/bash
# FunASR Server Startup Script
# Usage: ./run_server.sh [--gpu]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SCRIPT_DIR/venv"

# Check for GPU flag
if [[ "$1" == "--gpu" ]]; then
    export FUNASR_USE_GPU=1
    echo "GPU mode enabled"
fi

# Create virtual environment if not exists
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating Python virtual environment..."
    python3 -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"

    echo "Installing dependencies..."
    pip install --upgrade pip
    pip install -r "$SCRIPT_DIR/requirements.txt"
else
    source "$VENV_DIR/bin/activate"
fi

# Set default port
export FUNASR_HOST="${FUNASR_HOST:-127.0.0.1}"
export FUNASR_PORT="${FUNASR_PORT:-8765}"

echo "Starting FunASR server on $FUNASR_HOST:$FUNASR_PORT..."
python "$SCRIPT_DIR/server.py"
