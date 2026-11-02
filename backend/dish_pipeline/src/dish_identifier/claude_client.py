"""Claude JSON image stages and experimental text grouping; one dispatch, no retries."""
from __future__ import annotations

import base64
import json
import os
from pathlib import Path
import socket
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, HTTPSHandler, HTTPRedirectHandler, ProxyHandler

from .image_quality import https_context


class StageError(Exception):
    def __init__(self, code, message, *, details=None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details or {}


def load_claude_key(project, environ=None):
    """Reuse the existing private Claude file; deployment environment wins."""
    # Parse data only; never source, execute, or expand the private file.
    environ = os.environ if environ is None else environ
    if "ANTHROPIC_API_KEY" in environ:
        return environ["ANTHROPIC_API_KEY"].strip()
    for path in (Path(project) / ".env", Path(project) / "experiments/vlm_comparison/.env"):
        if path.is_symlink():
            raise ValueError("The credentials file must not be a symbolic link")
        if not path.exists():
            continue
        import re
        values = []
        for line in path.read_text().splitlines():
            match = re.match(r'^\s*(?:export\s+)?ANTHROPIC_API_KEY\s*=(.*)$', line)
            if not match:
                continue
            value = match.group(1).strip()
            if value.startswith('"'):
                value, offset = json.JSONDecoder().raw_decode(value)
                tail = match.group(1).strip()[offset:].strip()
                if tail and not tail.startswith('#'):
                    raise ValueError("Malformed Claude credential")
            elif value.startswith("'"):
                end = value.find("'", 1)
                if end < 0 or (value[end+1:].strip() and not value[end+1:].strip().startswith('#')):
                    raise ValueError("Malformed Claude credential")
                value = value[1:end]
            else:
                value = value.split(' #', 1)[0].strip()
            if not isinstance(value, str):
                raise ValueError("Malformed Claude credential")
            values.append(value)
        if len(values) > 1:
            raise ValueError("Duplicate Claude credential")
        if values and values[0]:
            return values[0]
    return ""


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class ClaudeClient:
    def __init__(self, key, model, timeout=120, interval=1.6):
        if not key or any(c.isspace() for c in key):
            raise ValueError("Claude API key is missing or malformed")
        self._key = key
        self.model, self.timeout, self.interval = model, timeout, interval
        self._last = 0
        self._lock = threading.Lock()
        self._opener = build_opener(ProxyHandler({}), HTTPSHandler(context=https_context()), NoRedirect())

    def redact(self, obj):
        if isinstance(obj, dict):
            return {k: self.redact(v) for k, v in obj.items()}
        if isinstance(obj, list):
            return [self.redact(v) for v in obj]
        return obj.replace(self._key, "[REDACTED]") if isinstance(obj, str) else obj

    def analyze(self, image, mime, prompt, schema, max_tokens, audit):
        content = [{"type": "image", "source": {"type": "base64", "media_type": mime,
                   "data": base64.b64encode(image).decode("ascii")}}, {"type": "text", "text": prompt}]
        return self._analyze_content(content, prompt, schema, max_tokens, audit)

    def analyze_text(self, prompt, schema, max_tokens, audit):
        """Send names only; never resend image bytes for normalization."""
        return self._analyze_content([{"type": "text", "text": prompt}], prompt, schema, max_tokens, audit)

    def _analyze_content(self, content, prompt, schema, max_tokens, audit):
        payload = {"model": self.model, "max_tokens": max_tokens, "thinking": {"type": "between_tools"},
                   "messages": [{"role": "user", "content": content}],
                   "output_config": {"format": {"type": "json_schema", "schema": schema}, "effort": "low"}}
        import hashlib
        audit({"event": "request_prepared", "model": self.model,
               "request_sha256": hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest(),
               "prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest(), "max_tokens": max_tokens})
        request = Request("https://api.anthropic.com/v1/messages", method="POST",
                          data=json.dumps(payload).encode(), headers={"Content-Type": "application/json",
                          "anthropic-version": "2023-06-01", "x-api-key": self._key})
        with self._lock:
            delay = self.interval - (time.monotonic() - self._last)
            if delay > 0:
                time.sleep(delay)
            self._last = time.monotonic()
        try:
            audit({"event": "dispatch_started", "outcome": "unknown_until_response"})
            with self._opener.open(request, timeout=self.timeout) as response:
                raw = response.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024:
                raise StageError("invalid_response", "The analysis service returned an oversized response.")
            envelope = self.redact(json.loads(raw))
        except HTTPError as error:
            code = error.code
            error.close()
            kind = "credentials_error" if code in (401, 403) else "rate_limit" if code == 429 else "service_error"
            message = {"credentials_error": "The analysis service could not authenticate. Check the saved server credentials.",
                       "rate_limit": "The analysis service is busy or its quota was reached. Please try again later.",
                       "service_error": "The analysis service could not complete this request. Please try again later."}[kind]
            raise StageError(kind, message, details={"http_status": code}) from None
        except (socket.timeout, TimeoutError):
            raise StageError("timeout", "The analysis request timed out. Please try again; no decision was made.") from None
        except URLError as error:
            if isinstance(error.reason, (socket.timeout, TimeoutError)):
                raise StageError("timeout", "The analysis request timed out. Please try again; no decision was made.") from None
            raise StageError("network_error", "The analysis service could not be reached. Check the connection and try again.") from None
        except OSError:
            raise StageError("network_error", "The analysis service could not be reached. Check the connection and try again.") from None
        except (ValueError, UnicodeError):
            raise StageError("invalid_response", "The analysis service returned an unreadable response.") from None
        audit({"event": "response_received", "raw_response": envelope})
        if envelope.get("model") != self.model or envelope.get("stop_reason") != "end_turn":
            raise StageError("incomplete_response", "The analysis did not finish with a complete result. Please try again.")
        try:
            text = "".join(b["text"] for b in envelope["content"] if b.get("type") == "text")
            analysis = json.loads(text)
            if not isinstance(analysis, dict):
                raise ValueError()
        except (KeyError, TypeError, ValueError):
            raise StageError("invalid_response", "The analysis service returned an invalid result.") from None
        return analysis, {"model": envelope["model"], "response_id": envelope.get("id"), "usage": envelope.get("usage")}
