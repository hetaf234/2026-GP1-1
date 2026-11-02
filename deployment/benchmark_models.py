"""Offline CPU smoke/latency check, never accuracy or end-to-end food analysis."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import sys
import tempfile
import time
from unittest.mock import patch


def benchmark(repo, dish, label_model, *, dish_only=False):
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    os.environ["MISBAR_LABEL_MODEL_DIR"] = str(label_model)
    sys.path.insert(0, str(dish / "src"))
    label_root = repo / "labels" if (repo / "labels/main.py").is_file() else repo / "Packaged-Food-Recognition/Server"
    sys.path.insert(0, str(label_root))
    from PIL import Image
    from dish_identifier.pipeline import Pipeline
    from app.services import ingredient_service

    # Offline diagnostics cannot contact providers or require their secrets.
    # Only the frozen model methods below are invoked on this instance.
    pipeline = Pipeline(dish, quality=object(), claude=object())
    if pipeline.setup_errors:
        raise RuntimeError("The existing pipeline setup is not ready.")
    times = {}
    start = time.monotonic()
    pipeline.runtime.load()
    times["dish_model_load_seconds"] = time.monotonic() - start

    with tempfile.TemporaryDirectory(prefix="misbar-offline-smoke-") as folder:
        image = Image.new("RGB", (448, 448), (120, 130, 140))
        path = Path(folder) / "synthetic.png"
        image.save(path)
        reference = pipeline.registry.resolve(original_label=None, image_path=path)
        start = time.monotonic()
        prediction, features = pipeline.runtime.classify(image)
        times["dish_classification_seconds"] = time.monotonic() - start
        start = time.monotonic()
        ood = pipeline.runtime.supportedness(features)
        times["dish_supportedness_seconds"] = time.monotonic() - start

    text = "Ingredients: water, wheat flour, egg, milk, salt."
    ingredients = None
    if not dish_only:
        start = time.monotonic()
        # Match the proposed CPU deployment; do not benchmark the Mac's MPS device.
        with patch.object(ingredient_service, "get_device", return_value=-1):
            ingredient_service.load_ingredient_pipeline()
        times["label_model_load_seconds"] = time.monotonic() - start
        start = time.monotonic()
        ingredients = ingredient_service.extract_ingredients(text)
        times["label_text_inference_seconds"] = time.monotonic() - start
        if not ingredients.strip():
            raise RuntimeError("The downloaded label model returned no ingredient span for the synthetic text.")
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    report = {"test_type": "offline_cpu_smoke_and_latency", "platform": sys.platform,
              "timings": times, "peak_process_rss_bytes": rss if sys.platform == "darwin" else rss * 1024,
              "source": "New synthetic image and test text; no dataset images or ground-truth labels.",
              "reference_basis": "Human authority checked before inference; no classification accuracy computed.",
              "registry_sha256": pipeline.registry.sha256, "registry_revision": pipeline.registry.data["revision"],
              "original_label": None, "reviewed_label": reference["effective_label"],
              "excluded_count": 0, "unresolved_count": 0, "image_sha256": reference["image_sha256"],
              "raw_synthetic_prediction": prediction, "raw_synthetic_supportedness": ood,
              "label_test_text": text, "label_test_extracted_ingredients": ingredients,
              "label_model_verified": not dish_only,
              "paid_service_requests": 0, "full_pipeline_verified": False,
              "linux_container_verified": sys.platform == "linux", "runtime_signature": pipeline.runtime_signature}
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dish-project", required=True, type=Path)
    parser.add_argument("--label-model", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--dish-only", action="store_true")
    args = parser.parse_args()
    report = benchmark(Path(__file__).resolve().parents[1], args.dish_project.resolve(), args.label_model.resolve(), dish_only=args.dish_only)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("test_type", "timings", "peak_process_rss_bytes", "paid_service_requests", "full_pipeline_verified")}, indent=2))
