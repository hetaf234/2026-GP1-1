"""System-owned user metadata. Never accept a role or language from the client."""

DEFAULT_USER_METADATA = {"language": "en", "role": "member"}


def missing_metadata(data):
    """Preserve every existing value, including an administrator's role."""
    return {key: value for key, value in DEFAULT_USER_METADATA.items() if key not in data}


def merge_user_write(db, doc_ref, payload, *, initialize_created_at=False):
    """Read missing keys and merge atomically; a concurrent admin edit wins on retry.

    All callers are trusted backend operations. Existing profile/allergy fields
    are only changed by the caller's original payload, never by metadata defaults.
    """
    from firebase_admin import firestore

    @firestore.transactional
    def write(transaction):
        snapshot = doc_ref.get(transaction=transaction)
        existing = (snapshot.to_dict() or {}) if snapshot.exists else {}
        update = {**payload, **missing_metadata(existing)}
        if initialize_created_at and not snapshot.exists:
            update["createdAt"] = firestore.SERVER_TIMESTAMP
        transaction.set(doc_ref, update, merge=True)

    write(db.transaction())
