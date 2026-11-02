"""Adapter for the existing immutable DINOv2 + Nonlinear Fusion model."""
from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path


MANIFEST_SHA = "29b2f15f0992aa1281cd82a742abdbbdee8db3d4d122dfd1b43b568506ba992c"


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


class FrozenRuntime:
    def __init__(self, project):
        self.project, self.detector = Path(project), None

    def load(self):
        if self.detector is not None:
            return self.detector
        # Reuse the deployed frozen loader, including all component/weight hashes.
        # MISBAR_CHECKPOINT selects the original OneDrive file in another folder.
        import os
        loader = self.project / "manual_testing/test_nonlinear.py"
        if digest(loader) != "ec454751bc51728570b4076e68f02eb9f8337344f0f7f2d5e2780f2fc3255f33":
            raise ValueError("Portable frozen loader mismatch")
        spec = importlib.util.spec_from_file_location("misbar_portable_detector", loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        detector = module.load_detector(os.environ.get("MISBAR_CHECKPOINT"))
        detector.load_original()
        self.detector = detector
        return detector

    def classify(self, image):
        import numpy as np
        import torch
        detector = self.load()
        with torch.inference_mode():
            logits, embeddings = detector.original.forward_with_embedding(detector.transform(image.convert("RGB")).unsqueeze(0))
        logits, embeddings = logits.numpy(), embeddings.numpy()
        values = logits[0].astype(np.float64)
        probabilities = np.exp(values - values.max())
        probabilities /= probabilities.sum()
        index = int(np.argmax(probabilities))
        return {"predicted_dish": detector.classes[index],
                "top1": {"rank": 1, "dish": detector.classes[index], "confidence": float(probabilities[index])},
                "class_count": len(detector.classes),
                "confidence_definition": "Softmax across all 121 classes; not the OOD acceptance score."}, (logits, embeddings)

    def supportedness(self, features):
        logits, embeddings = features
        detector = self.load()
        result = detector.score_embeddings(embeddings, logits)
        return {"accepted": bool(result["accepted"][0]), "score": float(result["score"][0]),
                "threshold": detector.threshold, "LR_score": float(result["LR_score"][0]),
                "OE_score": float(result["OE_score"][0]), "model": "FINAL_NONLINEAR_FUSION",
                "rule": "Accept score >= threshold. Supportedness is not a calibrated probability of correctness."}
