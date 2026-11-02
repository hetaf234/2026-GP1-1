"""Public errors contain reviewed messages, never SDK exception text or inputs."""
import logging
import re

from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException

from app.log_safety import install_safe_logging, log_event


PUBLIC_ERRORS = frozenset({
    "Not Found", "Method Not Allowed", "Authentication required",
    "Authorization header missing. Please include 'Authorization: Bearer <firebase_id_token>'.",
    "Invalid authorization format. Format must be 'Bearer <token>'.",
    "Token payload is missing a valid user ID (uid).",
    "Firebase ID token has expired. Please sign in again.",
    "Firebase ID token has been revoked.", "Invalid Firebase ID token.",
    "Could not validate Firebase credentials.", "A verified Firebase user is required.",
    "Database service unavailable. Cannot retrieve user allergies.",
    "Select at least one allergen using the 14 supported categories.",
    "Invalid allergy data in database.", "Failed to save allergies in database.",
    "User profile or allergy preferences not found. Please save your allergies before scanning.",
    "Uploaded file must be an image.", "Uploaded image file is empty.",
    "Image quality service is unavailable. Please retry later.",
    "Image analysis could not complete. Please retry later.",
    "Text analysis could not complete. Please retry later.",
    "Dish analysis could not complete. Please retry later.",
    "Dish analysis is busy. Please retry later.", "The image file is empty.",
    "The image exceeds 4 MB.", "Models are not ready.",
})
_DEFAULTS = {400: "Invalid request.", 401: "Authentication required.",
             403: "Access denied.", 404: "Not Found", 405: "Method Not Allowed",
             413: "Request is too large.", 422: "Invalid request data.",
             429: "Too many requests.", 503: "Service unavailable. Please retry later."}
_AUTH_HEADERS = frozenset({"Bearer", 'Bearer error="invalid_token"',
                         'Bearer error="invalid_token", error_description="Token expired"',
                         'Bearer error="invalid_token", error_description="Token revoked"'})


def install_error_handlers(app):
    install_safe_logging()
    # Debug traceback responses include locals/exception text. Never enable them.
    app.debug = False

    @app.exception_handler(HTTPException)
    async def http_error(request, exc):
        message = exc.detail if isinstance(exc.detail, str) and exc.detail in PUBLIC_ERRORS else _DEFAULTS.get(exc.status_code, "Request could not complete.")
        headers = {}
        for key, value in (exc.headers or {}).items():
            if key.lower() == "www-authenticate":
                headers["WWW-Authenticate"] = value if value in _AUTH_HEADERS else "Bearer"
            elif key.lower() == "retry-after" and str(value).isascii() and str(value).isdigit():
                headers["Retry-After"] = str(value)
            elif key.lower() == "allow" and isinstance(value, str) and re.fullmatch(r"(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)(?:,\s*(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS))*", value):
                headers["Allow"] = value
        return JSONResponse({"detail": message}, status_code=exc.status_code, headers=headers)

    @app.exception_handler(RequestValidationError)
    async def invalid_request(request, exc):
        # Pydantic's input/ctx/msg may contain the submitted token, password,
        # body or parser exception. Keep the 422 contract without echoing them.
        return JSONResponse({"detail": [{"type": "value_error", "loc": ["request"],
                                         "msg": "Invalid request data."}]}, status_code=422)

    @app.exception_handler(Exception)
    async def internal_error(request, exc):
        log_event(logging.getLogger("allergen_scanner"), logging.ERROR, "request_failed")
        return JSONResponse({"detail": "Request could not complete."}, status_code=500)
