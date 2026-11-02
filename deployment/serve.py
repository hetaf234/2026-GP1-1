"""Run one process: the frozen model and pipeline own mutable cached state."""
import os
from pathlib import Path
import sys

# Set the logging boundary before Uvicorn, SDK imports or factory startup.
_local_labels = Path(__file__).resolve().parents[1] / "Packaged-Food-Recognition/Server"
sys.path.insert(0, os.environ.get("MISBAR_LABEL_ROOT", str(_local_labels if _local_labels.exists() else "/opt/misbar/labels")))
from app.log_safety import install_safe_logging, uvicorn_log_config

install_safe_logging()

import uvicorn

if __name__ == "__main__":
    uvicorn.run(
        "deployment.gateway:from_environment",
        factory=True,
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8080")),
        workers=1,
        access_log=False,
        log_config=uvicorn_log_config(),
        timeout_graceful_shutdown=420,
    )
