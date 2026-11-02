from pathlib import Path
import os

# Project root directory
BASE_DIR = Path(__file__).resolve().parent.parent

# Credentials paths
CREDENTIALS_DIR = Path(os.environ.get("MISBAR_CREDENTIALS_DIR", str(BASE_DIR / "credentials")))
GOOGLE_VISION_CREDENTIALS = Path(os.environ.get("MISBAR_VISION_CREDENTIALS", str(CREDENTIALS_DIR / "allergen-scanner-506512-6b749d009330.json")))
FIREBASE_CREDENTIALS = Path(os.environ.get("MISBAR_FIREBASE_CREDENTIALS", str(CREDENTIALS_DIR / "misbar-ebea2-firebase-adminsdk-fbsvc-fb5b41e239.json")))
SIGHTENGINE_CREDENTIALS = Path(os.environ.get("MISBAR_SIGHTENGINE_CREDENTIALS", str(CREDENTIALS_DIR / "sightengine.json")))

# Dataset path
ALLERGEN_DATASET_FILE = BASE_DIR / "allergen_matching_dataset_reviewed_rtl.csv"

# Model path (uses local folder if downloaded, otherwise uses Hugging Face hub)
LOCAL_MODEL_DIR = Path(os.environ.get("MISBAR_LABEL_MODEL_DIR", str(BASE_DIR / "ingredient-detection")))
if os.environ.get("MISBAR_LABEL_MODEL_DIR") and not (LOCAL_MODEL_DIR / "config.json").is_file():
    raise RuntimeError("Configured local ingredient model is missing config.json.")
if LOCAL_MODEL_DIR.exists() and (LOCAL_MODEL_DIR / "config.json").exists():
    MODEL_PATH = str(LOCAL_MODEL_DIR)
else:
    MODEL_PATH = "openfoodfacts/ingredient-detection"

# Firebase project
FIREBASE_PROJECT_ID = "misbar-ebea2"

# Server configuration
HOST = "0.0.0.0"
PORT = 8000
