import os
import logging
from app.log_safety import log_event
from typing import Tuple
from app.constants import GOOGLE_VISION_CREDENTIALS

logger = logging.getLogger(__name__)

# Cache instance for Google Vision client
_vision_client = None

def get_vision_client():
    global _vision_client
    if _vision_client is not None:
        return _vision_client

    if GOOGLE_VISION_CREDENTIALS.exists():
        os.environ["GOOGLE_APPLICATION_CREDENTIALS"] = str(GOOGLE_VISION_CREDENTIALS)

    if os.getenv("GOOGLE_APPLICATION_CREDENTIALS"):
        try:
            from google.cloud import vision_v1 as vision
            _vision_client = vision.ImageAnnotatorClient()
            log_event(logger, logging.INFO, "vision_ready")
            return _vision_client
        except Exception:
            log_event(logger, logging.WARNING, "vision_initialization_failed")
            return None
    return None

def perform_ocr(image_bytes: bytes) -> Tuple[str, str]:
    """
    Extracts text from image bytes using Google Cloud Vision.
    Returns: (extracted_text, engine_name)
    """
    client = get_vision_client()
    if client is None:
        raise RuntimeError(
            "Google Vision client could not be initialized. Check the server configuration."
        )

    for attempt in range(2):
        try:
            from google.cloud import vision_v1 as vision
            image = vision.Image(content=image_bytes)
            response = client.document_text_detection(image=image)
            if response.error.message:
                error_msg = "Google Vision could not complete OCR."
                log_event(logger, logging.ERROR, "vision_api_failed")
                raise RuntimeError(error_msg)
            
            text = response.full_text_annotation.text
            if text:
                return text.strip(), "google_vision"
            else:
                return "", "google_vision"
        except Exception:
            log_event(logger, logging.ERROR, "vision_ocr_failed")
            if attempt == 0:
                import time
                time.sleep(0.5)

    raise RuntimeError("Google Vision OCR failed. Please retry later.") from None
