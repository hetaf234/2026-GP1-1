"""Local Sightengine token settings; never execute .env contents or print keys.

Only Sightengine's two token variables are read. Runtime environment values take
precedence, allowing deployment secrets without a local file. Local files are
private plaintext (0600), not encrypted storage, and must remain Git-ignored.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import tempfile

DEFAULT_ENV_FILE = Path(__file__).resolve().parents[2] / ".env"
NAMES = ("SIGHTENGINE_API_USER", "SIGHTENGINE_API_SECRET")
ENTRY = re.compile(r"^\s*(?:export\s+)?(SIGHTENGINE_API_USER|SIGHTENGINE_API_SECRET)\s*=(.*)$")


def _local_values(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("The local credentials file must not be a symbolic link")
    if not path.exists():
        return {}
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = ENTRY.match(line)
        if not match:
            continue
        name, value = match.groups()
        if name in values:
            raise ValueError("Duplicate Sightengine credential setting in .env")
        value = value.strip()
        if value.startswith('"'):
            try:
                value, offset = json.JSONDecoder().raw_decode(value)
            except ValueError:
                raise ValueError("Malformed quoted Sightengine credential in .env") from None
            if not isinstance(value, str):
                raise ValueError("Sightengine credentials must be text")
            remainder = match.group(2).strip()[offset:].strip()
            if remainder and not remainder.startswith("#"):
                raise ValueError("Unexpected text after quoted credential in .env")
        elif value.startswith("'"):
            end = value.find("'", 1)
            if end < 0 or (value[end + 1:].strip() and not value[end + 1:].strip().startswith("#")):
                raise ValueError("Malformed quoted Sightengine credential in .env")
            value = value[1:end]
        else:
            value = value.split(" #", 1)[0].strip()
        values[name] = value
    return values


def load_sightengine_credentials(path=DEFAULT_ENV_FILE, *, environ=None):
    """Return credentials without modifying the process environment."""
    environ = os.environ if environ is None else environ
    # A deployed application with complete environment secrets needs no .env.
    if all(name in environ for name in NAMES):
        return tuple(environ[name].strip() for name in NAMES)
    local = _local_values(path)
    return tuple(environ.get(name, local.get(name, "")).strip() for name in NAMES)


def save_sightengine_credentials(user, secret, path=DEFAULT_ENV_FILE):
    """Atomically save only our token pair; retain unrelated settings unchanged."""
    # Reuse the actual client's credential validation, without any API request.
    from .image_quality import SightengineQualityGate
    gate = SightengineQualityGate(user, secret)
    values = dict(zip(NAMES, (gate.api_user, gate.api_secret)))
    path = Path(path)
    if path.is_symlink():
        raise ValueError("The local credentials file must not be a symbolic link")
    _local_values(path)  # Reject malformed/duplicate settings rather than overwrite silently.
    original = path.read_text(encoding="utf-8") if path.exists() else ""
    remaining = dict(values)
    lines = []
    for line in original.splitlines(keepends=True):
        match = ENTRY.match(line.rstrip("\r\n"))
        if match:
            name = match.group(1)
            lines.append(f"{name}={json.dumps(remaining.pop(name))}\n")
        else:
            lines.append(line)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.extend(f"{name}={json.dumps(value)}\n" for name, value in remaining.items())
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", prefix=".misbar-env-",
                                         dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), 0o600)
            stream.writelines(lines)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
