"""Sightengine image quality check shared by the CLI and image scan route."""

import json
import math
from pathlib import Path

import requests


from app.constants import SIGHTENGINE_CREDENTIALS

CREDENTIALS_FILE = SIGHTENGINE_CREDENTIALS
API_URL = "https://api.sightengine.com/1.0/check.json"


class QualityServiceError(Exception):
    """The check could not be completed; this does not mean poor image quality."""


def check_image_quality(image_bytes: bytes) -> dict:
    if not image_bytes:
        raise QualityServiceError("The image file is empty.")

    try:
        settings = json.loads(CREDENTIALS_FILE.read_text(encoding="utf-8-sig"))
        api_user = settings.get("api_user", "")
        api_secret = settings.get("api_secret", "")
        raw_threshold = settings.get("threshold", 0.5)
        if (
            not isinstance(api_user, str) or not api_user.strip()
            or not isinstance(api_secret, str) or not api_secret.strip()
            or isinstance(raw_threshold, bool)
        ):
            raise ValueError("Invalid settings")
        threshold = float(raw_threshold)
        if not math.isfinite(threshold) or not 0 <= threshold <= 1:
            raise ValueError("Invalid threshold")
    except (OSError, ValueError, TypeError, AttributeError):
        raise QualityServiceError(
            "Sightengine settings are missing or invalid. Check credentials/sightengine.json."
        ) from None

    try:
        response = requests.post(
            API_URL,
            data={
                "models": "quality",
                "api_user": api_user.strip(),
                "api_secret": api_secret.strip(),
            },
            files={"media": ("uploaded-image", image_bytes)},
            timeout=(5, 30),
        )
    except requests.RequestException:
        raise QualityServiceError(
            "Could not reach Sightengine. Check the connection and try again."
        ) from None

    if response.status_code != 200:
        raise QualityServiceError(
            f"Sightengine returned HTTP {response.status_code}. Check credentials and account limits."
        )

    try:
        result = response.json()
        if not isinstance(result, dict) or result.get("status") != "success":
            raise ValueError("Request not successful")
        raw_score = result["quality"]["score"]
        if isinstance(raw_score, bool):
            raise ValueError("Invalid score")
        score = float(raw_score)
        if not math.isfinite(score) or not 0 <= score <= 1:
            raise ValueError("Invalid score")
    except (KeyError, TypeError, ValueError):
        raise QualityServiceError(
            "Sightengine did not return a valid quality score. Check service access and account limits."
        ) from None

    return {"score": score, "threshold": threshold, "accepted": score >= threshold}
