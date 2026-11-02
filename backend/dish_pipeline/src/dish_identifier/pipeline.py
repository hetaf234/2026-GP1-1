"""Online image → gates → frozen Top-1/OOD → union → Claude name grouping.

No training, classifier override or user-allergy matching.
Human dish reviews are provenance, never model inputs.
"""
from __future__ import annotations

import hashlib
import io
import json
from pathlib import Path
import time
import warnings

from PIL import Image

from .claude_client import ClaudeClient, StageError, load_claude_key
from .credentials import load_sightengine_credentials
from .dish_display import DishDisplayNames
from .frozen_runtime import FrozenRuntime
from .human_labels import HumanLabelRegistry
from .image_quality import QualityConfig, SightengineQualityGate
from .ingredient_data import IngredientData
from .ingredient_normalization import METHOD, apply_normalization, normalization_records, render_prompt
from .recipe_fusion import NAME_NORMALIZATION_METHOD, merge_sources, validate_extraction

PROJECT = Path(__file__).resolve().parents[2]
ASSETS = Path(__file__).with_name("assets")
PIPELINE_REVISION = "misbar-normalization-v3-short-top1-20261028"
STAGES = [("upload", "Image validation"), ("quality", "Image quality"), ("food_gate", "Food serving check"),
          ("classification", "Dish recognition"), ("ood", "Supported dish check"),
          ("dataset", "Recipe ingredients & linked allergens"), ("extraction", "Claude ingredient analysis"),
          ("fusion", "Merge ingredients & allergens"), ("normalization", "Claude ingredient normalization")]
FOOD_REJECTIONS = {
    "MULTIPLE_DISHES": "Several independent main dishes are prominent. Please upload one main meal with its sides and sauces.",
    "NOT_FOOD": "No food serving could be identified. Please upload a photo of your meal.",
    "PACKAGED_PRODUCT_OR_LABEL": "The actual food is not clearly visible. Please photograph the food outside its closed packaging.",
    "RAW_INGREDIENTS": "This photo shows cooking ingredients rather than a prepared meal. Please upload a prepared food serving.",
    "UNCERTAIN": "We could not reliably identify one main food serving. Please take a closer, unobstructed photo of your meal."
}
QUALITY_ERRORS = {
    "credentials_error": "The image-quality service could not authenticate. Check the saved server credentials.",
    "rate_limit": "The image-quality service quota or request limit was reached. Please try again later.",
    "timeout": "The image-quality check timed out. Please try again; no quality decision was made.",
    "tls_error": "A secure connection to the image-quality service could not be verified. Please try again later.",
    "dns_error": "The image-quality service address could not be reached. Check your connection.",
    "network_error": "The image-quality service could not be reached. Check your connection and try again."
}


def validate_image(data, config):
    if not data:
        raise StageError("empty_file", "The selected file is empty. Choose a JPEG, PNG or WebP photo.")
    if len(data) > config["max_upload_bytes"]:
        raise StageError("file_too_large", "This photo exceeds 4 MB. Choose a smaller JPEG, PNG or WebP photo.")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as source:
                fmt, dimensions = source.format, source.size
                if dimensions[0] * dimensions[1] > config["max_image_pixels"]:
                    raise StageError("image_too_large", "This photo exceeds 20 megapixels. Choose a smaller image.")
                if getattr(source, "n_frames", 1) > 1:
                    raise StageError("animated_image", "Choose a still photo rather than an animated image.")
                source.verify()
            with Image.open(io.BytesIO(data)) as source:
                image = source.convert("RGB")
                image.load()
        mime = {"JPEG": "image/jpeg", "PNG": "image/png", "WEBP": "image/webp"}.get(fmt)
        if not mime:
            raise StageError("unsupported_format", "This file format is not supported. Choose a JPEG, PNG or WebP photo.")
        return image, mime, dimensions
    except StageError:
        raise
    except (OSError, ValueError, SyntaxError, Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise StageError("invalid_image", "This file could not be read as an image. Choose a valid JPEG, PNG or WebP photo.") from None


def runtime_signature(project=PROJECT):
    project = Path(project)
    config_bytes = (project / "configs/pipeline.json").read_bytes()
    config = json.loads(config_bytes)
    return {"revision": PIPELINE_REVISION,
            "config_sha256": hashlib.sha256(config_bytes).hexdigest(),
            "dish_display_mapping_sha256": hashlib.sha256((project / config["dish_display_mapping_file"]).read_bytes()).hexdigest(),
            "assets_manifest_sha256": hashlib.sha256((ASSETS / "manifest.json").read_bytes()).hexdigest()}


class Pipeline:
    def __init__(self, project=PROJECT, *, quality=None, claude=None, runtime=None):
        self.project = Path(project)
        config_bytes = (self.project / "configs/pipeline.json").read_bytes()
        self.config = json.loads(config_bytes)
        if self.config["allergy_matching_enabled"]:
            raise ValueError("User-allergy matching is not enabled in this pipeline")
        self.stage_definitions = STAGES if self.config["normalization_enabled"] else STAGES[:-1]
        self.assets = {}
        manifest_bytes = (ASSETS / "manifest.json").read_bytes()
        manifest = json.loads(manifest_bytes)
        for name, entry in manifest.items():
            data = (ASSETS / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != entry["sha256"]:
                raise ValueError("Runtime asset identity mismatch")
            self.assets[name] = json.loads(data) if name.endswith('.json') else data.decode()
        self.asset_hashes = {name: entry["sha256"] for name, entry in manifest.items()}
        self.runtime_signature = {"revision": PIPELINE_REVISION,
            "config_sha256": hashlib.sha256(config_bytes).hexdigest(),
            "assets_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest()}
        if self.config["normalization_enabled"]:
            for key in ("normalization_prompt", "normalization_schema"):
                if self.config.get(key) not in self.assets:
                    raise ValueError("The normalization prompt or schema is not a verified runtime asset")
            if type(self.config.get("normalization_max_tokens")) is not int or self.config["normalization_max_tokens"] < 1:
                raise ValueError("A positive normalization token limit is required")
        self.categories = self.assets["ingredient_schema.json"]["properties"]["ingredients"]["items"]["properties"]["allergens"]["items"]["enum"]
        data_file = self.config.get("ingredient_data_file")
        if not isinstance(data_file, str) or not data_file.strip():
            raise StageError("invalid_recipe_data", "The ingredient data file is not configured.")
        self.recipe_data = IngredientData(self.project / data_file, self.categories)
        self.ingredient_data = self.recipe_data.identity
        display_file = self.config.get("dish_display_mapping_file")
        if not isinstance(display_file, str) or not display_file.strip():
            raise StageError("invalid_dish_display_mapping", "The dish display mapping file is not configured.")
        classes_file = self.config.get("dish_class_mapping_file")
        if not isinstance(classes_file, str) or not classes_file.strip():
            raise StageError("invalid_dish_display_mapping", "The model class mapping file is not configured.")
        classes = json.loads((self.project / classes_file).read_text())["classes"]
        self.dish_display = DishDisplayNames(self.project / display_file, classes)
        self.runtime_signature["dish_display_mapping_sha256"] = self.dish_display.identity["sha256"]
        self.registry = HumanLabelRegistry(self.project / "data_governance/human_label_registry.json")
        self._check_authority()
        self.setup_errors = []
        self.quality = quality
        if quality is None:
            try:
                user, secret = load_sightengine_credentials(self.project / ".env")
                self.quality = SightengineQualityGate(user, secret, QualityConfig.from_file(self.project / "configs/image_quality.json"))
            except (ValueError, OSError):
                self.setup_errors.append("Image-quality credentials or configuration are missing or invalid.")
        self.claude = claude
        if claude is None:
            try:
                self.claude = ClaudeClient(load_claude_key(self.project), self.config["claude_model"],
                    self.config["claude_timeout_seconds"], self.config["claude_request_interval_seconds"])
            except (ValueError, OSError):
                self.setup_errors.append("Claude credentials are missing or invalid in the saved server configuration.")
        self.runtime = runtime or FrozenRuntime(self.project)

    def _check_authority(self):
        active = json.loads((self.project / "data_governance/active_references.json").read_text())
        current = HumanLabelRegistry(self.project / "data_governance/human_label_registry.json")
        if active.get("status") != "ready" or active.get("registry_sha256") != current.sha256 or current.sha256 != self.registry.sha256:
            raise StageError("reference_not_ready", "The human-review reference changed or is not ready. Restart after resolving the reference.")

    def run(self, path, *, filename=None, progress=None):
        path = Path(path)
        result = {"filename": filename or path.name, "decision": "processing", "message": "Preparing your photo.",
                  "stopped_at": None, "final_dish": None, "final_dish_display_name_en": None, "stages": [
                      {"id": key, "name": title, "status": "pending", "message": "Waiting for previous stages.", "data": None}
                      for key, title in self.stage_definitions],
                  "normalization_performed": False, "semantic_normalization_performed": False,
                  "user_allergy_matching_performed": False,
                  "protocol": {"assets": self.asset_hashes, "claude_model": self.config["claude_model"],
                               "ingredient_data": self.ingredient_data,
                               "dish_display_mapping": self.dish_display.identity,
                               "ingredient_name_normalization": NAME_NORMALIZATION_METHOD,
                               "runtime_signature": self.runtime_signature, "classification_output": "top1",
                               "semantic_normalization_enabled": self.config["normalization_enabled"],
                               "semantic_normalization_method": METHOD if self.config["normalization_enabled"] else None},
                  "reference_basis": "Human dish labels retained as provenance only. No dish-label accuracy is derived or classifier output overridden.",
                  "registry_sha256": self.registry.sha256, "registry_revision": self.registry.data["revision"]}
        self._result, self._progress = result, progress
        current = "upload"
        try:
            self._start(current)
            self._check_authority()
            # Resolve exact identity before opening/uploading any chosen image.
            reference = self.registry.resolve(original_label=None, image_path=path)
            result.update(image_sha256=reference["image_sha256"], human_reference=reference,
                          original_label=reference["review"]["original_label"] if reference["review"] else None,
                          reviewed_label=reference["effective_label"],
                          human_excluded_count=int(reference["decision"] == "EXCLUDE_UNUSABLE"),
                          human_unresolved_count=int(reference["decision"] == "UNSURE"))
            image_bytes = path.read_bytes()
            if hashlib.sha256(image_bytes).hexdigest() != reference["image_sha256"]:
                raise StageError("image_changed", "The image changed during validation. Please upload it again.")
            image, mime, dimensions = validate_image(image_bytes, self.config)
            self._finish(current, "passed", "The photo is valid and ready for analysis.", {"mime": mime, "width": dimensions[0], "height": dimensions[1], "bytes": len(image_bytes)})
            if self.setup_errors:
                raise StageError("setup_error", " ".join(self.setup_errors))

            current = "quality"
            self._start(current)
            quality = self.quality.check(image_bytes)
            if quality.decision == "error":
                raise StageError(quality.reason, QUALITY_ERRORS.get(quality.reason, "The image-quality service did not return a valid result. Please try again later."), details=quality.to_dict() | {"message": "Image-quality check could not be completed."})
            data = quality.to_dict()
            if quality.decision == "rejected":
                self._finish(current, "rejected", "The photo quality is too low. Please upload a clearer, well-lit photo.", data | {"message": "Quality below the acceptance threshold."})
                return self._stop("rejected", current)
            self._finish(current, "passed", "The photo passed the quality check.", data | {"message": "Image quality accepted."})

            current = "food_gate"
            self._start(current)
            gate, metadata = self.claude.analyze(image_bytes, mime, self.assets["food_gate_prompt.txt"], self.assets["food_gate_schema.json"],
                                               self.config["food_gate_max_tokens"], self._audit(current))
            categories = set(FOOD_REJECTIONS) | {"SINGLE_DISH"}
            if set(gate) != {"image_type", "reason"} or not isinstance(gate["image_type"], str) or gate["image_type"] not in categories or not isinstance(gate["reason"], str) or not gate["reason"].strip():
                raise StageError("invalid_response", "The food-serving check returned an invalid result. Please try again.")
            gate.update(metadata)
            if gate["image_type"] != "SINGLE_DISH":
                self._finish(current, "rejected", FOOD_REJECTIONS[gate["image_type"]], gate)
                return self._stop("rejected", current)
            self._finish(current, "passed", "One main food serving was identified. Sides and sauces are allowed.", gate)

            current = "classification"
            self._start(current)
            classification, features = self.runtime.classify(image)
            dish = classification["predicted_dish"]
            display_name_en = self.dish_display.english(dish)
            self._finish(current, "complete", "DINOv2 returned its Top-1 dish prediction.",
                         classification | {"display_name_en": display_name_en})

            current = "ood"
            self._start(current)
            ood = self.runtime.supportedness(features)
            if not ood["accepted"]:
                self._finish(current, "rejected", "This meal may be outside our supported dishes. The dish guess has been withheld; ingredient analysis was not run.", ood)
                return self._stop("rejected", current)
            result["final_dish"] = dish
            result["final_dish_display_name_en"] = display_name_en
            self._finish(current, "passed", "The dish prediction passed the supportedness check.", ood)

            current = "dataset"
            self._start(current)
            recipe = self.recipe_data.retrieve(dish)
            recipe["dataset_version"] = self.ingredient_data
            self._finish(current, "complete", "Retrieved recipe ingredients and their linked potential allergens from the selected Misbar dataset.", recipe)

            current = "extraction"
            self._start(current)
            prompt = self.assets["ingredient_prompt.txt"].replace("{categories}", json.dumps(self.categories)).replace("{dish}", dish)
            schema = json.loads(json.dumps(self.assets["ingredient_schema.json"]))
            schema["properties"]["dinov2_predicted_dish"]["enum"] = [dish]
            extracted, metadata = self.claude.analyze(image_bytes, mime, prompt, schema, self.config["ingredients_max_tokens"], self._audit(current))
            extracted = validate_extraction(extracted, dish, self.categories)
            self._finish(current, "complete", "Claude returned recognized and inferred ingredients with confidence and potential allergen links.", extracted | metadata)

            current = "fusion"
            self._start(current)
            merged = merge_sources(recipe["ingredients"], extracted["ingredients"])
            result["normalization_performed"] = merged["normalization_applied"]
            self._finish(current, "complete", "Merged recipe and Claude results with case and whitespace normalization; all source evidence retained.", merged)
            if self.config["normalization_enabled"]:
                current = "normalization"
                self._start(current)
                self._check_authority()
                records = normalization_records(merged)
                template = self.assets[self.config["normalization_prompt"]]
                prompt = render_prompt(template, dish, records)
                prompt_sha = hashlib.sha256(prompt.encode()).hexdigest()
                self._audit(current)({"event": "normalization_input", "records": records, "prompt_sha256": prompt_sha})
                proposal, metadata = self.claude.analyze_text(prompt, self.assets[self.config["normalization_schema"]],
                    self.config["normalization_max_tokens"], self._audit(current))
                self._audit(current)({"event": "normalization_proposal", "proposal": proposal, "provider_metadata": metadata})
                normalized = apply_normalization(merged, proposal)
                normalized.update(review_status="live_output_not_individually_human_reviewed",
                    proposal=proposal, input_records=records, provider_metadata=metadata, prompt_sha256=prompt_sha,
                    prompt_template_sha256=self.asset_hashes[self.config["normalization_prompt"]])
                result["semantic_normalization_performed"] = True
                self._finish(current, "complete", "Ingredient names normalized by Claude. All original allergen links, causes and confidence scores retained.", normalized)
                result.update(decision="accepted", message="Analysis complete. Ingredient names have been normalized and linked allergens retained.",
                              stopped_at="before_user_allergy_matching")
                self._emit()
                return result
            result.update(decision="accepted", message="Analysis complete. Ingredients and potential allergens have been merged.", stopped_at="before_semantic_normalization")
            self._emit()
            return result
        except StageError as error:
            self._finish(current, "error", error.message, {"error_code": error.code, **error.details})
            return self._stop("error", current)
        except Exception as error:
            self._finish(current, "error", "This stage could not be completed. Check the local setup and try again; no acceptance or rejection was inferred from this error.", {"error_code": "local_stage_error", "error_type": type(error).__name__})
            return self._stop("error", current)

    def _stage(self, key):
        return next(s for s in self._result["stages"] if s["id"] == key)

    def _emit(self):
        if self._progress:
            self._progress(self._result)

    def _start(self, key):
        stage = self._stage(key)
        stage.update(status="running", message="Checking…", started_at=time.time())
        self._result["message"] = stage["name"] + " is running."
        self._emit()

    def _finish(self, key, status, message, data):
        stage = self._stage(key)
        stage.update(status=status, message=message, data=data, duration_seconds=round(time.time()-stage.get("started_at", time.time()), 3))
        self._emit()

    def _stop(self, decision, key):
        self._result.update(decision=decision, stopped_at=key, message=self._stage(key)["message"])
        for stage in self._result["stages"]:
            if stage["status"] == "pending":
                stage.update(status="skipped", message="Not run because an earlier stage stopped the analysis.")
        self._emit()
        return self._result

    def _audit(self, key):
        def record(event):
            self._stage(key).setdefault("request_evidence", []).append(event)
            self._emit()
        return record
