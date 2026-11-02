"""Run via stdin inside the image: no credentials, networking, or images."""
import json
from pathlib import Path
import sys

root = Path('/opt/misbar')
sys.path[:0] = [str(root), str(root / 'dish/src'), str(root / 'labels')]
from deployment.verify_bundle import verify
from dish_identifier.pipeline import Pipeline
from app.log_safety import install_safe_logging
from app.services.ingredient_service import load_ingredient_pipeline

install_safe_logging()
manifest = verify(root)
pipeline = Pipeline(root / 'dish', quality=object(), claude=object())
pipeline.runtime.load()
load_ingredient_pipeline()
print(json.dumps({'model_loading': 'both loaded', 'ingredient_data': pipeline.ingredient_data,
                  'mapping': pipeline.dish_display.identity, 'registry_sha256': pipeline.registry.sha256,
                  'paid_requests': 0, 'images_analyzed': 0}, indent=2))
