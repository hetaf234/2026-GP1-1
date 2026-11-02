"""Public Dish progress projection. Never stream a pipeline audit snapshot."""
from copy import deepcopy
import json
import re

from app.log_safety import redact_sensitive


def public_result(result, *, secret_values=()):
    """Keep required cause evidence, omitting internal prompts/provider envelopes."""
    output = {key: deepcopy(result[key]) for key in (
        "decision", "stopped_at", "final_dish", "final_dish_display_name_en",
        "semantic_normalization_performed", "user_allergy_matching_performed",
    ) if key in result}
    output["stages"] = [{"id": s.get("id"), "status": s.get("status")}
                        for s in result.get("stages", [])]
    for source, summary in zip(result.get("stages", []), output["stages"]):
        data = source.get("data")
        code = data.get("error_code") if isinstance(data, dict) else None
        if source.get("status") == "error" and isinstance(code, str) and re.fullmatch(r"[a-z_]{1,64}", code):
            # Safe diagnostic classification, never exception/provider text.
            summary["error_code"] = code
    personal = result.get("personalization")
    if isinstance(personal, dict):
        output["personalization"] = {key: deepcopy(personal[key]) for key in (
            "status", "method", "profile_source", "profile_read_at", "selected_allergies",
            "resolved_categories", "profile_category_resolutions", "unresolved_profile_terms",
            "match_status", "matches", "ingredients_without_identified_allergens",
            "mapping_disagreements", "safety_assessment", "notice", "category_scope_note", "error_code",
        ) if key in personal}

    # Evidence is retained, but even nested data may not smuggle audit material
    # into the public stream. Credential patterns are additionally redacted.
    forbidden = {"prompt", "request_evidence", "provider_metadata", "raw_response", "raw_provider_response",
                 "response_envelope", "proposal", "input_records", "path", "image_path", "filename"}
    def clean(value):
        if isinstance(value, dict):
            return {k: clean(v) for k, v in value.items()
                    if k.casefold() not in forbidden
                    and not any(word in k.casefold().replace("_", "")
                                for word in ("prompt", "provider", "requestevidence", "rawresponse"))}
        if isinstance(value, list):
            return [clean(v) for v in value]
        return value
    return redact_sensitive(clean(output), secret_values=secret_values)


def encode_event(kind, payload):
    return f"event: {kind}\ndata: {json.dumps(payload, ensure_ascii=False, allow_nan=False)}\n\n"


class DishProgress:
    """Reduce real pipeline statuses to three indicators; deduplicate audit emits."""
    def __init__(self, send):
        self.send = send
        self.states = {}

    def update(self, stage, status):
        if self.states.get(stage) != status:
            self.states[stage] = status
            self.send("progress", {"stage": stage, "status": status})

    def __call__(self, snapshot):
        statuses = {s["id"]: s["status"] for s in snapshot.get("stages", [])}
        upload = statuses.get("upload")
        if upload in {"running", "passed", "error", "rejected"}:
            self.update("image_received", "completed" if upload == "passed" else upload)
        following = [statuses.get(s) for s in (
            "quality", "food_gate", "classification", "ood", "dataset", "extraction", "fusion", "normalization")]
        if "error" in following:
            self.update("identifying_ingredients", "error")
        elif "rejected" in following:
            self.update("identifying_ingredients", "rejected")
        elif statuses.get("normalization") == "complete":
            self.update("identifying_ingredients", "completed")
        elif any(s not in {None, "pending", "skipped"} for s in following):
            self.update("identifying_ingredients", "running")
