import re
import csv
import logging
from app.log_safety import log_event
from typing import List, Tuple, Dict
from app.constants import ALLERGEN_DATASET_FILE
from app.models import AllergenDetection

logger = logging.getLogger(__name__)

_allergen_rules: List[Tuple[str, str, re.Pattern]] = []
_all_categories: List[str] = []
_dataset_loaded = False

def load_allergen_dataset():
    global _allergen_rules, _all_categories, _dataset_loaded
    if _dataset_loaded:
        return

    if not ALLERGEN_DATASET_FILE:
        log_event(logger, logging.ERROR, "dataset_missing")
        raise RuntimeError("Allergen dataset could not be loaded. Check server configuration.")

    log_event(logger, logging.INFO, "dataset_loading")
    try:
        categories_set = set()
        rules = []

        with open(ALLERGEN_DATASET_FILE, mode="r", encoding="utf-8") as f:
            reader = csv.reader(f)
            header = next(reader, None)
            
            # Determine column positions
            cat_idx = 0
            kw_idx = 1
            if header:
                for idx, col_name in enumerate(header):
                    col_lower = col_name.lower().strip()
                    if "category" in col_lower:
                        cat_idx = idx
                    elif "keyword" in col_lower or "ingredient" in col_lower:
                        kw_idx = idx

            for row in reader:
                if len(row) <= max(cat_idx, kw_idx):
                    continue
                category = row[cat_idx].strip()
                keyword = row[kw_idx].strip().lower()

                if not keyword or not category:
                    continue

                categories_set.add(category)
                # Word-boundary regex matching
                pattern = re.compile(r"\b" + re.escape(keyword) + r"\b", re.IGNORECASE)
                rules.append((category, keyword, pattern))

        if len(categories_set) != 14 or not rules:
            raise ValueError("The allergen dataset must contain all 14 categories.")

        _allergen_rules = rules
        _all_categories = sorted(list(categories_set))
        _dataset_loaded = True
        log_event(logger, logging.INFO, "dataset_loaded")
    except Exception:
        log_event(logger, logging.ERROR, "dataset_load_failed")
        raise RuntimeError("Allergen dataset could not be loaded. Check server configuration.") from None

def get_available_categories() -> List[str]:
    load_allergen_dataset()
    return list(_all_categories)

def get_keywords_count() -> int:
    load_allergen_dataset()
    return len(_allergen_rules)

def detect_allergens(
    ingredient_text: str,
    user_allergens: List[str]
) -> Tuple[List[AllergenDetection], bool]:
    """
    Cross-references ingredient text against the allergen dataset.
    Returns: (list_of_detections, is_safe)
    """
    from app.services.user_allergen_service import validate_user_allergens

    validate_user_allergens(user_allergens)
    if not ingredient_text:
        return [], True

    # Normalize text for matching
    normalized_text = re.sub(r"\s+", " ", ingredient_text.lower())

    # Map: category -> set of matched keywords
    matched_by_cat: Dict[str, List[str]] = {}

    for category, keyword, pattern in _allergen_rules:
        if pattern.search(normalized_text):
            if category not in matched_by_cat:
                matched_by_cat[category] = []
            if keyword not in matched_by_cat[category]:
                matched_by_cat[category].append(keyword)

    target_categories = set(user_allergens)

    detections: List[AllergenDetection] = []
    has_user_allergy_conflict = False

    for category, keywords in matched_by_cat.items():
        is_user_allergen = category in target_categories
        if is_user_allergen:
            has_user_allergy_conflict = True

        detections.append(
            AllergenDetection(
                allergen=category,
                matched_ingredients=keywords,
                is_user_allergen=is_user_allergen
            )
        )

    return detections, not has_user_allergy_conflict
