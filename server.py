#!/usr/bin/env python3
import sys
import os
from pathlib import Path

# Auto-detect and switch to virtualenv python if we're not inside it
venv_python = Path(__file__).resolve().parent / "application" / ".venv" / "bin" / "python3"
if venv_python.exists() and sys.executable != str(venv_python):
    print(f"[Launcher] Switching to virtual environment python: {venv_python}")
    os.execv(str(venv_python), [str(venv_python)] + sys.argv)

# Add backend directory to PYTHONPATH
backend_dir = Path(__file__).resolve().parent / "application" / "backend"
sys.path.insert(0, str(backend_dir))

import uvicorn

PORT = 27099

if __name__ == "__main__":
    print(f"[Launcher] Starting FastAPI Bilingual Reader Server on port {PORT}...")
    # Run the uvicorn server serving fastapi api.main:app
    uvicorn.run(
        "api.main:app",
        host="0.0.0.0",
        port=PORT,
        reload=False
    )
