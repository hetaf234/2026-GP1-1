"""Independent online image-quality gate. No food detection or dish inference.

Credentials stay in memory and in the HTTPS POST body. This module never reads
training data, changes image bytes, retries requests, or infers ground truth.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
import io
import json
import math
from pathlib import Path
import ssl
import time
import warnings

import certifi
from PIL import Image, UnidentifiedImageError
import requests
from urllib3.exceptions import NameResolutionError, ReadTimeoutError

ENDPOINT = "https://api.sightengine.com/1.0/check.json"


def https_context():
    """Use a portable CA bundle, including Python installs without system CAs."""
    context = ssl.create_default_context(cafile=certifi.where())
    context.set_alpn_protocols(["http/1.1"])
    return context


def _number(value, name, *, minimum=0, maximum=None):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be a number")
    try:
        finite = math.isfinite(value)
    except OverflowError:
        finite = False
    if not finite or value < minimum or (maximum is not None and value > maximum):
        raise ValueError(f"Invalid {name}")
    return float(value)


def _json_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("Non-finite JSON number")
    return number


def _reject_json_constant(value):
    raise ValueError("Invalid JSON constant")


@dataclass(frozen=True)
class QualityConfig:
    threshold: float = 0.5
    timeout_seconds: float = 30
    request_interval_seconds: float = 1.05

    def __post_init__(self):
        _number(self.threshold, "threshold", maximum=1)
        _number(self.timeout_seconds, "timeout_seconds", minimum=0.001)
        _number(self.request_interval_seconds, "request_interval_seconds", minimum=1)

    @classmethod
    def from_file(cls, path: Path):
        data = json.loads(Path(path).read_text())
        if data.get("provider") != "sightengine" or data.get("model") != "quality":
            raise ValueError("Expected the Sightengine quality configuration")
        return cls(**{name: data[name] for name in (
            "threshold", "timeout_seconds", "request_interval_seconds"
        )})


@dataclass(frozen=True)
class QualityResult:
    decision: str
    score: float | None
    threshold: float
    reason: str
    message: str
    raw_response: dict | None = None
    http_status: int | None = None

    @property
    def can_continue(self):
        return self.decision == "accepted"

    def to_dict(self):
        return {**asdict(self), "can_continue": self.can_continue}


def evaluate_response(payload: dict, threshold: float = 0.5, http_status=200):
    """Keep provider request status separate from our local quality decision."""
    _number(threshold, "threshold", maximum=1)
    if not isinstance(payload, dict):
        return QualityResult("error", None, threshold, "invalid_response",
                             "Could not read the image-quality result.", http_status=http_status)
    if http_status != 200 or payload.get("status") != "success":
        error = payload.get("error")
        error_type = error.get("type") if isinstance(error, dict) else None
        reason = "credentials_error" if error_type == "credentials_error" else (
            "rate_limit" if http_status == 429 else "service_error"
        )
        message = "The image-quality service could not authenticate." if reason == "credentials_error" else (
            "The image-quality service reached its request limit." if reason == "rate_limit" else
            "The image-quality service could not complete the check."
        )
        return QualityResult("error", None, threshold, reason, message, payload, http_status)
    try:
        score = _number(payload["quality"]["score"], "quality score", maximum=1)
    except (KeyError, TypeError, ValueError):
        return QualityResult("error", None, threshold, "invalid_response",
                             "The service did not return a valid quality score.", payload, http_status)
    accepted = score >= threshold
    return QualityResult(
        "accepted" if accepted else "rejected", score, threshold,
        "quality_passed" if accepted else "low_quality",
        "The image passed the quality check." if accepted else
        "Image quality is below the acceptance threshold.", payload, http_status,
    )


@dataclass(repr=False)
class SightengineQualityGate:
    api_user: str = field(repr=False)
    api_secret: str = field(repr=False)
    config: QualityConfig = field(default_factory=QualityConfig)
    _last_request: float | None = field(default=None, init=False, repr=False)

    def __post_init__(self):
        self.api_user = self.api_user.strip()
        self.api_secret = self.api_secret.strip()
        if not self.api_user or not self.api_secret:
            raise ValueError("Sightengine API user and secret are required")
        for value in (self.api_user, self.api_secret):
            if (value in {"YOUR_API_USER", "YOUR_API_SECRET"} or
                    any(char.isspace() for char in value) or any(char in value for char in "{}•")):
                raise ValueError("Paste the complete API credentials, without placeholders or spaces")

    @classmethod
    def from_environment(cls, config=None, *, env_file=None):
        from .credentials import DEFAULT_ENV_FILE, load_sightengine_credentials
        user, secret = load_sightengine_credentials(DEFAULT_ENV_FILE if env_file is None else env_file)
        return cls(user, secret, config or QualityConfig())

    def _redact(self, value):
        if isinstance(value, dict):
            return {key: "[REDACTED]" if key in {"api_user", "api_secret"} else self._redact(item)
                    for key, item in value.items()}
        if isinstance(value, list):
            return [self._redact(item) for item in value]
        if isinstance(value, str):
            for credential in (self.api_secret, self.api_user):
                value = value.replace(credential, "[REDACTED]")
        return value

    def check(self, image_bytes: bytes) -> QualityResult:
        """Upload the original bytes once; invalid images and outages never pass."""
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(io.BytesIO(image_bytes)) as image:
                    image_format = image.format
                    image.verify()
                with Image.open(io.BytesIO(image_bytes)) as image:
                    image.load()
            content_types = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}
            if image_format not in content_types:
                return self._error("unsupported_format", "Use a JPEG, PNG, or WebP image.")
        except (UnidentifiedImageError, OSError, ValueError, SyntaxError,
                Image.DecompressionBombError, Image.DecompressionBombWarning):
            return self._error("invalid_image", "Could not read the image file.")

        if self._last_request is not None:
            delay = self.config.request_interval_seconds - (time.monotonic() - self._last_request)
            if delay > 0:
                time.sleep(delay)
        self._last_request = time.monotonic()
        return self._request_quality(image_bytes, content_types[image_format])

    def _request_quality(self, image_bytes: bytes, content_type: str) -> QualityResult:
        try:
            response = requests.post(
                ENDPOINT,
                data={
                    "models": "quality",
                    "api_user": self.api_user,
                    "api_secret": self.api_secret,
                },
                files={"media": ("image", image_bytes, content_type)},
                headers={"Accept": "application/json"},
                timeout=self.config.timeout_seconds,
                verify=certifi.where(),
                allow_redirects=False,
            )
        except requests.exceptions.SSLError:
            return self._error("tls_error", "Could not establish a secure connection to the image-quality service.")
        except requests.RequestException as error:
            # Requests can wrap a response-body timeout or DNS failure in a ConnectionError.
            cause = error.args[0] if error.args else None
            if isinstance(error, requests.Timeout) or isinstance(cause, ReadTimeoutError):
                return self._error("timeout", "The image-quality check timed out.")
            if isinstance(getattr(cause, "reason", None), NameResolutionError):
                return self._error("dns_error", "Could not resolve the image-quality service address.")
            return self._error("network_error", "Could not connect to the image-quality service.")

        http_status = response.status_code
        try:
            payload = json.loads(
                response.content,
                parse_float=_json_float,
                parse_constant=_reject_json_constant,
            )
        except ValueError:
            return self._error(
                "rate_limit" if http_status == 429 else "invalid_response",
                "Could not read the image-quality service response.",
                http_status,
            )
        return evaluate_response(self._redact(payload), self.config.threshold, http_status)

    def _error(self, reason, message, status=None):
        return QualityResult("error", None, self.config.threshold, reason, message, http_status=status)
