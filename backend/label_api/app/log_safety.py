"""Fail-closed diagnostics: only reviewed event codes reach application logs.

Do not pass exceptions, request data or credential values to ``log_event``.
Unknown library messages are suppressed at every level, including DEBUG. This
does not depend on recognizing a key's spelling or knowing its value beforehand.
"""
from __future__ import annotations

import logging
import os
import re


EVENTS = frozenset({
    "server_starting", "server_stopping", "dataset_ready", "model_warming",
    "model_warmup_deferred", "allergies_save_failed", "scan_authenticated",
    "allergies_loaded", "image_scan_failed", "text_scan_failed",
    "firebase_certificate_ready", "firebase_certificate_failed",
    "firebase_default_ready", "firebase_initialization_failed",
    "token_verification_failed", "firestore_ready", "firestore_initialization_failed",
    "allergies_query_failed", "user_document_missing", "allergies_saved",
    "profile_query_failed", "profile_saved", "profile_save_failed",
    "vision_ready", "vision_initialization_failed", "vision_api_failed",
    "vision_ocr_failed", "ingredient_model_loading", "ingredient_model_ready",
    "ingredient_model_failed", "ingredient_extraction_failed", "ingredients_not_found",
    "dataset_missing", "dataset_loading", "dataset_loaded", "dataset_load_failed",
    "request_failed", "dish_scan_failed", "gateway_startup_failed",
})
SUPPRESSED = "diagnostic_details_suppressed"


class _Event:
    def __init__(self, code):
        if code not in EVENTS:
            raise ValueError("Unknown diagnostic event.")
        self.code = code


def log_event(logger, level, code):
    logger.log(level, _Event(code))


def _safe_message(record):
    # Never call str()/repr()/getMessage() on an untrusted message or argument.
    if isinstance(record.msg, _Event) and record.msg.code in EVENTS:
        return record.msg.code
    if isinstance(record.msg, str) and record.msg in EVENTS | {SUPPRESSED} and not record.args:
        return record.msg
    return SUPPRESSED


class SafeFormatter(logging.Formatter):
    def format(self, record):
        # Deliberately ignore extras, exception chains, stack/source paths,
        # logger names and custom formatters which might serialize credentials.
        level = "ERROR" if record.levelno >= logging.ERROR else "WARNING" if record.levelno >= logging.WARNING else "INFO" if record.levelno >= logging.INFO else "DEBUG"
        return f"{self.formatTime(record)} [{level}] {_safe_message(record)}"


def uvicorn_log_config():
    return {
        "version": 1, "disable_existing_loggers": False,
        "formatters": {"safe": {"()": SafeFormatter}},
        "handlers": {"default": {"class": "logging.StreamHandler", "formatter": "safe", "stream": "ext://sys.stderr"}},
        "loggers": {
            "uvicorn": {"handlers": ["default"], "level": "INFO", "propagate": False},
            "uvicorn.error": {"handlers": [], "level": "INFO", "propagate": True},
            "uvicorn.access": {"handlers": [], "level": "WARNING", "propagate": False},
        },
    }


def install_safe_logging():
    """Install before importing SDKs; idempotent for reloads and the gateway."""
    previous = logging.getLogRecordFactory()
    if not getattr(previous, "_misbar_safe", False):
        def factory(*args, **kwargs):
            record = previous(*args, **kwargs)
            record.msg = _safe_message(record)
            record.args = ()
            record.exc_info = record.exc_text = record.stack_info = None
            return record
        factory._misbar_safe = True
        logging.setLogRecordFactory(factory)
    root = logging.getLogger()
    if not root.handlers:
        root.addHandler(logging.StreamHandler())
        root.setLevel(logging.INFO)
    for logger in [root, *logging.Logger.manager.loggerDict.values()]:
        if isinstance(logger, logging.Logger):
            for handler in logger.handlers:
                handler.setFormatter(SafeFormatter())
    if logging.lastResort is not None:
        logging.lastResort.setFormatter(SafeFormatter())
    logging.captureWarnings(True)


_SECRET_KEYS = frozenset({
    "authorization", "proxyauthorization", "cookie", "setcookie", "password",
    "passwd", "apikey", "apiuser", "apisecret", "privatekey", "privatekeyid",
    "clientsecret", "clientemail", "credential", "credentials", "token",
    "accesstoken", "refreshtoken", "idtoken", "session", "sessionid",
    "clientid", "secret", "signingkey", "authorizationcode", "verificationcode",
})
_PEM = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)", re.S)
_AUTH = re.compile(r"\b(Bearer|Basic)\s+[^\s,;\"']+", re.I)
_JWT = re.compile(r"\beyJ[\w-]+\.[\w-]+\.[\w-]+\b")
_KEY = re.compile(r"\b(?:sk-ant-[\w-]+|AIza[\w-]+)\b")
_ASSIGNMENT = re.compile(r"(?i)((?:api[_-]?(?:key|user|secret)|password|client[_-]?secret|(?:access|refresh|id)[_-]?token|authorization|credential|token)\s*[\"']?\s*[:=]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s&,;}]+)")
_USERINFO = re.compile(r"(https?://)[^\s/@]+(?::[^\s/@]*)?@", re.I)


def redact_sensitive(value, *, secret_values=()):
    """Redact a *copy* of provider error evidence; never alter pipeline state."""
    def sensitive_key(key):
        key = re.sub(r"[^a-z0-9]", "", str(key).lower())
        return key in _SECRET_KEYS or key.endswith((
            "apikey", "apiuser", "secret", "token", "password", "credential",
            "credentials", "privatekey", "secretkey", "accesskey", "accesskeyid",
            "authorization", "cookie",
        ))

    secrets = tuple(v for v in secret_values if isinstance(v, str) and v) + tuple(
        v for k, v in os.environ.items() if v and sensitive_key(k)
    )

    def clean(item):
        if isinstance(item, dict):
            return {clean(key): "[REDACTED]" if sensitive_key(key) else clean(val) for key, val in item.items()}
        if isinstance(item, (list, tuple)):
            return [clean(part) for part in item]
        if isinstance(item, str):
            for secret in sorted(secrets, key=len, reverse=True):
                item = item.replace(secret, "[REDACTED]")
            item = _PEM.sub("[REDACTED PRIVATE KEY]", item)
            item = _AUTH.sub("[REDACTED AUTHORIZATION]", item)
            item = _JWT.sub("[REDACTED TOKEN]", item)
            item = _KEY.sub("[REDACTED API KEY]", item)
            item = _ASSIGNMENT.sub(lambda match: match[1] + "[REDACTED]", item)
            return _USERINFO.sub(r"\1[REDACTED]@", item)
        return item
    return clean(value)
