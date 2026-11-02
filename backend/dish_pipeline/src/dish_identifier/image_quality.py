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
import socket
import ssl
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import uuid
import warnings

from PIL import Image, UnidentifiedImageError
import certifi

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
                             "تعذّر قراءة نتيجة فحص الجودة.", http_status=http_status)
    if http_status != 200 or payload.get("status") != "success":
        error = payload.get("error")
        error_type = error.get("type") if isinstance(error, dict) else None
        reason = "credentials_error" if error_type == "credentials_error" else (
            "rate_limit" if http_status == 429 else "service_error"
        )
        message = "تحققي من معرّف API والمفتاح السري." if reason == "credentials_error" else (
            "بلغ الطلب حد الخدمة. حاولي لاحقًا." if reason == "rate_limit" else
            "تعذّر فحص الصورة بالخدمة. حاولي مرة أخرى."
        )
        return QualityResult("error", None, threshold, reason, message, payload, http_status)
    try:
        score = _number(payload["quality"]["score"], "quality score", maximum=1)
    except (KeyError, TypeError, ValueError):
        return QualityResult("error", None, threshold, "invalid_response",
                             "لم ترجع الخدمة درجة جودة صالحة.", payload, http_status)
    accepted = score >= threshold
    return QualityResult(
        "accepted" if accepted else "rejected", score, threshold,
        "quality_passed" if accepted else "low_quality",
        "اجتازت الصورة فحص الجودة؛ فحص الطعام لم يُربط بعد." if accepted else
        "جودة الصورة غير كافية. ارفعي صورة أوضح.", payload, http_status,
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

    def check(self, image_bytes: bytes):
        """Upload the original bytes once; invalid images and outages never pass."""
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(io.BytesIO(image_bytes)) as image:
                    image_format = image.format
                    image.verify()
                with Image.open(io.BytesIO(image_bytes)) as image:
                    image.load()
            # These formats are supported by this initial integration, without conversion.
            content_types = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}
            if image_format not in content_types:
                return self._error("unsupported_format", "استخدمي صورة JPEG أو PNG أو WebP.")
        except (UnidentifiedImageError, OSError, ValueError, SyntaxError,
                Image.DecompressionBombError, Image.DecompressionBombWarning):
            return self._error("invalid_image", "تعذّر قراءة ملف الصورة؛ اختاري ملفًا صالحًا.")

        boundary = "misbar-" + uuid.uuid4().hex
        body = bytearray()
        for name, value in (("models", "quality"), ("api_user", self.api_user), ("api_secret", self.api_secret)):
            body.extend(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
            body.extend(value.encode("utf-8") + b"\r\n")
        body.extend((f'--{boundary}\r\nContent-Disposition: form-data; name="media"; filename="image"\r\n'
                     f'Content-Type: {content_types[image_format]}\r\n\r\n').encode())
        body.extend(image_bytes)
        body.extend(f"\r\n--{boundary}--\r\n".encode())
        request = Request(ENDPOINT, data=bytes(body), method="POST", headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Accept": "application/json",
        })
        if self._last_request is not None:
            delay = self.config.request_interval_seconds - (time.monotonic() - self._last_request)
            if delay > 0:
                time.sleep(delay)
        self._last_request = time.monotonic()
        status = 200
        try:
            try:
                with urlopen(request, timeout=self.config.timeout_seconds, context=https_context()) as response:
                    status = response.status
                    raw = response.read()
            except HTTPError as error:
                with error:
                    status = error.code
                    raw = error.read()
            payload = self._redact(json.loads(raw, parse_float=_json_float, parse_constant=_reject_json_constant))
        except (socket.timeout, TimeoutError):
            return self._error("timeout", "انتهت مهلة فحص الصورة. حاولي مرة أخرى.")
        except ssl.SSLCertVerificationError:
            return self._error("tls_error", "تعذّر التحقق من شهادة الاتصال الآمن بخدمة الجودة.")
        except URLError as error:
            if isinstance(error.reason, ssl.SSLCertVerificationError):
                return self._error("tls_error", "تعذّر التحقق من شهادة الاتصال الآمن بخدمة الجودة.")
            if isinstance(error.reason, (socket.timeout, TimeoutError)):
                return self._error("timeout", "انتهت مهلة فحص الصورة. حاولي مرة أخرى.")
            if isinstance(error.reason, socket.gaierror):
                return self._error("dns_error", "تعذّر الوصول لعنوان الخدمة. تحققي من اتصال الإنترنت.")
            return self._error("network_error", "تعذّر الاتصال بخدمة فحص الجودة. حاولي مرة أخرى.")
        except OSError:
            return self._error("network_error", "تعذّر الاتصال بخدمة فحص الجودة. حاولي مرة أخرى.")
        except (ValueError, UnicodeError):
            return self._error("rate_limit" if status == 429 else "invalid_response",
                               "تعذّر قراءة رد الخدمة. حاولي لاحقًا.", status)
        return evaluate_response(payload, self.config.threshold, status)

    def _error(self, reason, message, status=None):
        return QualityResult("error", None, self.config.threshold, reason, message, http_status=status)
