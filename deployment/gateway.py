"""Cloud entry point: existing label API plus the full frozen dish pipeline."""
from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
import json
import logging
import os
from pathlib import Path
import sys

from fastapi import HTTPException

from deployment.dish_api import dish_router


def seed_quality_environment(path, environ):
    """Reuse one Sightengine secret file for both services without copying keys."""
    if all(environ.get(key, "").strip() for key in ("SIGHTENGINE_API_USER", "SIGHTENGINE_API_SECRET")):
        return
    try:
        settings = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        updates = {}
        for source, target in (("api_user", "SIGHTENGINE_API_USER"), ("api_secret", "SIGHTENGINE_API_SECRET")):
            value = settings[source]
            if not isinstance(value, str) or not value.strip():
                raise ValueError()
            if not environ.get(target, "").strip():
                updates[target] = value.strip()
        environ.update(updates)
    except (OSError, ValueError, KeyError, TypeError):
        raise RuntimeError("Sightengine service configuration is unavailable.") from None


def create_gateway(label_app, authenticate, pipeline, load_label_model, *, warm_models=True):
    from app.error_safety import install_error_handlers
    from app.log_safety import log_event
    install_error_handlers(label_app)
    previous_lifespan = label_app.router.lifespan_context
    ready = {"value": False}

    @asynccontextmanager
    async def lifespan(app):
        try:
            async with previous_lifespan(app):
                if warm_models:
                    await asyncio.to_thread(load_label_model)
                    await asyncio.to_thread(pipeline.runtime.load)
                if pipeline.setup_errors:
                    raise RuntimeError("Required dish service configuration is missing.")
                pipeline._check_authority()
                ready["value"] = True
                yield
        except Exception:
            log_event(logging.getLogger(__name__), logging.ERROR, "gateway_startup_failed")
            raise RuntimeError("Gateway lifecycle could not complete. Check server configuration.") from None
        finally:
            ready["value"] = False

    label_app.router.lifespan_context = lifespan
    label_app.include_router(dish_router(pipeline, authenticate))

    @label_app.get("/ready", tags=["Deployment"])
    def readiness():
        if not ready["value"]:
            raise HTTPException(503, "Models are not ready.")
        return {"ready": True, "models": ["packaged_label_ingredients", "dish_dinov2_nonlinear"]}

    return label_app


def from_environment():
    dish = Path(os.environ.get("MISBAR_DISH_ROOT", "/opt/misbar/dish"))
    labels = Path(os.environ.get("MISBAR_LABEL_ROOT", "/opt/misbar/labels"))
    sys.path.insert(0, str(dish / "src"))
    sys.path.insert(0, str(labels))
    from main import app
    from app.auth import get_current_user
    from app.constants import SIGHTENGINE_CREDENTIALS
    from app.services.ingredient_service import load_ingredient_pipeline
    from dish_identifier.pipeline import Pipeline
    from app.log_safety import log_event
    try:
        seed_quality_environment(SIGHTENGINE_CREDENTIALS, os.environ)
        return create_gateway(app, get_current_user, Pipeline(dish), load_ingredient_pipeline)
    except Exception:
        log_event(logging.getLogger(__name__), logging.ERROR, "gateway_startup_failed")
        raise RuntimeError("Gateway configuration could not be initialized.") from None
