import os
import json
import logging
from app.log_safety import log_event
from typing import List, Optional, Dict, Any
from datetime import datetime, timezone
import urllib.request
import urllib.error

from app.constants import FIREBASE_PROJECT_ID, FIREBASE_CREDENTIALS
from app.auth import init_firebase_admin
from app.services.user_metadata_service import merge_user_write, DEFAULT_USER_METADATA

logger = logging.getLogger("allergen_scanner.db")

class UserDocumentNotFoundError(Exception):
    """The user profile or its saved allergy selection does not exist yet."""
    pass

class DatabaseUnavailableError(Exception):
    """Raised when Firestore is unavailable or connection fails."""
    pass

class InvalidAllergyDataError(Exception):
    """Saved selections are empty, malformed or not canonical categories."""
    pass

def validate_user_allergens(allergies: List[str]) -> None:
    """Reject invalid selections without coercion, aliases or partial matching."""
    from app.services.allergen_service import get_available_categories

    supported = get_available_categories()
    if (not isinstance(allergies, list) or not allergies
            or any(not isinstance(value, str) or value not in supported for value in allergies)
            or len(set(allergies)) != len(allergies)):
        raise InvalidAllergyDataError("Select at least one allergen using the 14 supported categories.")


_firestore_client = None

def get_firestore_client():
    """
    Returns the Firestore client from firebase_admin, initializing if needed.
    """
    global _firestore_client
    if _firestore_client is not None:
        return _firestore_client

    app = init_firebase_admin()
    if app is not None:
        try:
            from firebase_admin import firestore
            _firestore_client = firestore.client()
            log_event(logger, logging.INFO, "firestore_ready")
            return _firestore_client
        except Exception:
            log_event(logger, logging.ERROR, "firestore_initialization_failed")

    return None

def fetch_user_allergens_from_db(user_id: str) -> List[str]:
    """
    Extracts the user's saved allergen list directly from Cloud Firestore
    under document collection 'users/{user_id}'.
    Raises explicit exceptions on failure so callers never confuse failures with empty lists.
    """
    if not user_id or not user_id.strip():
        raise ValueError("fetch_user_allergens_from_db called with empty user_id.")

    db = get_firestore_client()
    if db is None:
        raise DatabaseUnavailableError("Firestore client is not available on server.")

    try:
        doc_ref = db.collection("users").document(user_id.strip())
        doc = doc_ref.get()
    except Exception:
        log_event(logger, logging.ERROR, "allergies_query_failed")
        raise DatabaseUnavailableError("Firestore query failed.") from None

    if not doc.exists:
        log_event(logger, logging.WARNING, "user_document_missing")
        raise UserDocumentNotFoundError("User profile document not found.")

    data = doc.to_dict() or {}
    if "allergies" not in data:
        raise UserDocumentNotFoundError("User allergy selections have not been saved.")

    allergies = data["allergies"]
    validate_user_allergens(allergies)
    return list(allergies)

def save_user_allergens_in_db(user_id: str, allergies: List[str]) -> bool:
    """
    Saves or updates the user's selected allergies in Firestore.
    """
    if not user_id or not user_id.strip():
        raise ValueError("save_user_allergens_in_db called with empty user_id.")

    validate_user_allergens(allergies)
    db = get_firestore_client()
    if db is None:
        raise DatabaseUnavailableError("Firestore client is not available on server.")

    try:
        from firebase_admin import firestore
        doc_ref = db.collection("users").document(user_id.strip())
        merge_user_write(db, doc_ref, {
            "allergies": allergies,
            "updatedAt": firestore.SERVER_TIMESTAMP,
        })
        log_event(logger, logging.INFO, "allergies_saved")
        return True
    except Exception:
        log_event(logger, logging.ERROR, "allergies_save_failed")
        raise DatabaseUnavailableError("Failed to save allergies in Firestore.") from None

def get_user_profile_from_db(user_id: str) -> Optional[Dict[str, Any]]:
    """
    Retrieves the user profile data (name, email, allergies) for the given user_id.
    """
    if not user_id or not user_id.strip():
        return None

    db = get_firestore_client()
    if db is None:
        raise RuntimeError("Firestore client is not available on server.")
    try:
        doc = db.collection("users").document(user_id.strip()).get()
        data = (doc.to_dict() or {}) if doc.exists else {}
    except Exception:
        log_event(logger, logging.ERROR, "profile_query_failed")
        raise RuntimeError("User profile could not be retrieved.") from None

    selection_saved = "allergies" in data
    if selection_saved:
        validate_user_allergens(data["allergies"])
    return {
        "uid": user_id.strip(),
        "name": data.get("name"),
        "email": data.get("email"),
        "allergies": list(data["allergies"]) if selection_saved else [],
        "allergy_selection_saved": selection_saved,
        "language": data.get("language", DEFAULT_USER_METADATA["language"]),
        "role": data.get("role", DEFAULT_USER_METADATA["role"]),
    }

def save_user_profile_in_db(user_id: str, name: Optional[str] = None, email: Optional[str] = None) -> bool:
    """
    Creates or updates the user's profile document in Firestore.
    """
    if not user_id or not user_id.strip():
        return False

    db = get_firestore_client()
    if db is not None:
        try:
            from firebase_admin import firestore
            doc_ref = db.collection("users").document(user_id.strip())
            payload: Dict[str, Any] = {
                "updatedAt": firestore.SERVER_TIMESTAMP,
            }
            if name is not None:
                payload["name"] = name.strip()
            if email is not None:
                payload["email"] = email.strip()

            # A new account has no saved selections until the selection endpoint
            # succeeds. Metadata is assigned only here, inside the transaction.
            merge_user_write(db, doc_ref, payload, initialize_created_at=True)
            log_event(logger, logging.INFO, "profile_saved")
            return True
        except Exception:
            log_event(logger, logging.ERROR, "profile_save_failed")
            raise RuntimeError("User profile could not be saved.") from None

    raise RuntimeError("Firestore client is not available on server.")
