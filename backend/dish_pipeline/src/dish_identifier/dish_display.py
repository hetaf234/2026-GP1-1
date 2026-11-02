"""English presentation names; never relabel classifier or recipe identifiers."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from .claude_client import StageError


class DishDisplayNames:
    def __init__(self, path, supported_dishes):
        self.path = Path(path)
        try:
            raw = self.path.read_bytes()
            rows = json.loads(raw)
        except (OSError, ValueError, UnicodeDecodeError) as error:
            raise StageError("invalid_dish_display_mapping", "The dish display mapping is missing or unreadable.") from error
        if not isinstance(rows, list) or not rows:
            raise StageError("invalid_dish_display_mapping", "The dish display mapping must be a non-empty list.")
        self.names = {}
        for row in rows:
            if not isinstance(row, dict):
                raise StageError("invalid_dish_display_mapping", "A dish display mapping row is invalid.")
            key, name = row.get("current_name"), row.get("display_name_en")
            if any(not isinstance(value, str) or not value.strip() or value != value.strip() for value in (key, name)):
                raise StageError("invalid_dish_display_mapping", "Every dish needs an exact identifier and a non-empty English display name.")
            if key in self.names:
                raise StageError("invalid_dish_display_mapping", f"Duplicate dish display identifier: {key}.")
            self.names[key] = name
        expected = set(supported_dishes)
        missing, extra = expected - self.names.keys(), self.names.keys() - expected
        if missing or extra:
            raise StageError("invalid_dish_display_mapping",
                f"Dish display mapping does not match the model classes. Missing: {sorted(missing)}; extra: {sorted(extra)}.")
        self.identity = {"file": self.path.name, "sha256": hashlib.sha256(raw).hexdigest(),
                         "source_field": "display_name_en", "language": "en", "dish_count": len(self.names),
                         "scope": "presentation_only; original dish identifiers unchanged"}

    def english(self, dish):
        if dish not in self.names:
            raise StageError("missing_dish_display_name", "The predicted dish has no configured English display name.")
        return self.names[dish]
