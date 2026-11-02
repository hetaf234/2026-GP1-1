"""Offline adversarial tests. All credentials below are invented test strings."""
import copy
import io
import json
import logging
import logging.config
import os
from pathlib import Path
import runpy
import sys
import traceback
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

REPO = Path(__file__).resolve().parents[2]
SERVER = REPO / "Packaged-Food-Recognition/Server"
sys.path.insert(0, str(SERVER))

import main
from app import auth
from app.error_safety import install_error_handlers
from app.log_safety import SafeFormatter, install_safe_logging, log_event, redact_sensitive
from app.services import allergen_service, ingredient_service, ocr_service, user_allergen_service as db_service
from app.services.quality_service import QualityServiceError
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from deployment.tests.test_gateway import PipelineDouble, gateway, AUTH


OPAQUE = "invented-opaque-value-Q7R42"
TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.inventedSignature"
KEY = "sk-" + "ant-api03-invented-Q7R42"
PEM = "-----BEGIN " + "PRIVATE KEY-----\nINVENTED_KEY_MATERIAL\n-----END PRIVATE KEY-----"
SENSITIVE = f"{OPAQUE} Authorization: Bearer {TOKEN} api_key={KEY} password=pass-Q7R42 {PEM} user-Q7R42@example.invalid"


class LogCapture:
    def __enter__(self):
        self.output = io.StringIO()
        self.handler = logging.StreamHandler(self.output)
        self.handler.setFormatter(SafeFormatter())
        self.root = logging.getLogger()
        self.level = self.root.level
        self.root.addHandler(self.handler)
        self.root.setLevel(logging.DEBUG)
        return self.output

    def __exit__(self, *args):
        self.root.removeHandler(self.handler)
        self.root.setLevel(self.level)


class LoggingSafetyTests(unittest.TestCase):
    def test_unknown_plaintext_formatted_structured_and_debug_messages_are_suppressed(self):
        install_safe_logging()
        with LogCapture() as output:
            logger = logging.getLogger("third_party.provider")
            for level in (logging.DEBUG, logging.INFO, logging.WARNING, logging.ERROR, logging.CRITICAL):
                logger.log(level, SENSITIVE)
                logger.log(level, "provider response: %s", {"credentials": SENSITIVE})
            log_event(logger, logging.ERROR, "vision_ocr_failed")
        text = output.getvalue()
        self.assertNotIn(OPAQUE, text)
        self.assertNotIn(TOKEN, text)
        self.assertNotIn("INVENTED_KEY_MATERIAL", text)
        self.assertIn("diagnostic_details_suppressed", text)
        self.assertIn("vision_ocr_failed", text)

    def test_exception_chain_stack_and_preformatted_traceback_are_not_logged(self):
        with LogCapture() as output:
            try:
                try:
                    raise ValueError(SENSITIVE)
                except ValueError as cause:
                    raise RuntimeError(OPAQUE) from cause
            except RuntimeError:
                logging.getLogger("uvicorn.error").exception("ASGI failure %s", SENSITIVE, stack_info=True)
        text = output.getvalue()
        self.assertNotIn(OPAQUE, text)
        self.assertNotIn("Traceback", text)
        self.assertNotIn("ValueError", text)

    def test_formatter_never_serializes_extras_logger_names_or_exception_objects(self):
        class Unprintable:
            def __str__(self):
                raise AssertionError("Untrusted object was evaluated")
        record = logging.LogRecord(SENSITIVE, logging.ERROR, SENSITIVE, 1, Unprintable(), (), None)
        record.exc_text = record.stack_info = SENSITIVE
        record.request_headers = {"Authorization": SENSITIVE}
        record.password = SENSITIVE
        self.assertNotIn(OPAQUE, SafeFormatter().format(record))
        with LogCapture() as output:
            logging.getLogger("provider").error(Unprintable())
        self.assertIn("diagnostic_details_suppressed", output.getvalue())

    def test_installation_is_idempotent_and_future_standard_handlers_are_safe(self):
        install_safe_logging()
        factory = logging.getLogRecordFactory()
        install_safe_logging()
        self.assertIs(logging.getLogRecordFactory(), factory)
        output = io.StringIO()
        handler = logging.StreamHandler(output)
        handler.setFormatter(logging.Formatter("%(message)s"))
        logger = logging.getLogger("late.provider")
        logger.addHandler(handler)
        try:
            logger.error(SENSITIVE, exc_info=(ValueError, ValueError(SENSITIVE), None))
        finally:
            logger.removeHandler(handler)
        self.assertNotIn(OPAQUE, output.getvalue())
        self.assertNotIn("ValueError", output.getvalue())

    def test_uvicorn_uses_safe_formatter_and_disables_access_logging(self):
        with patch("uvicorn.run") as run, patch.dict(os.environ, {"PORT": "8080"}):
            runpy.run_module("deployment.serve", run_name="__main__")
        config = run.call_args.kwargs
        self.assertFalse(config["access_log"])
        self.assertIs(config["log_config"]["formatters"]["safe"]["()"], SafeFormatter)


class ErrorResponseTests(unittest.TestCase):
    def setUp(self):
        self.overrides = dict(main.app.dependency_overrides)
        main.app.dependency_overrides.clear()
        main.app.dependency_overrides[auth.get_current_user] = lambda: {"uid": OPAQUE}
        self.client = TestClient(main.app, raise_server_exceptions=False)

    def tearDown(self):
        main.app.dependency_overrides.clear()
        main.app.dependency_overrides.update(self.overrides)
        self.client.close()

    def assertPrivate(self, response, logs):
        combined = response.text + str(response.headers) + logs
        for value in (OPAQUE, TOKEN, KEY, "INVENTED_KEY_MATERIAL", "pass-Q7R42", "user-Q7R42@example.invalid"):
            self.assertNotIn(value, combined)

    def test_image_text_profile_and_write_exceptions_are_private(self):
        cases = [
            ("main.perform_ocr", "POST", "/scan/image", {"files": {"file": ("label.png", b"test", "image/png")}}, 500),
            ("main.extract_ingredients", "POST", "/scan/text", {"json": {"text": "Ingredients: milk"}}, 500),
            ("main.get_user_profile_from_db", "GET", "/users/me", {}, 503),
            ("main.save_user_profile_in_db", "POST", "/users/profile", {"json": {"name": "Name"}}, 503),
            ("main.save_user_allergens_in_db", "PUT", "/users/me/allergies", {"json": {"allergies": ["Milk"]}}, 500),
        ]
        for target, method, path, kwargs, status in cases:
            with self.subTest(path=path), patch("main.check_image_quality", return_value={"accepted": True}), patch(target, side_effect=RuntimeError(SENSITIVE)), LogCapture() as logs:
                response = self.client.request(method, path, **kwargs)
            self.assertEqual(response.status_code, status)
            self.assertPrivate(response, logs.getvalue())

    def test_database_errors_keep_status_without_provider_details(self):
        for error, status in [(db_service.DatabaseUnavailableError, 503), (db_service.InvalidAllergyDataError, 500), (db_service.UserDocumentNotFoundError, 404)]:
            for route in ("/scan/text", "/scan/image", "/users/me/allergies"):
                # The preferences GET marks an unsaved selection explicitly (200).
                expected = 200 if route == "/users/me/allergies" and status == 404 else status
                with self.subTest(error=error, route=route), patch("main.extract_ingredients", return_value="milk"), patch("main.perform_ocr", return_value=("milk", "mock")), patch("main.check_image_quality", return_value={"accepted": True}), patch("main.fetch_user_allergens_from_db", side_effect=error(SENSITIVE)), LogCapture() as logs:
                    if route == "/scan/image":
                        response = self.client.post(route, files={"file": ("test.png", b"test", "image/png")})
                    elif route == "/scan/text":
                        response = self.client.post(route, json={"text": "milk"})
                    else:
                        response = self.client.get(route)
                self.assertEqual(response.status_code, expected)
                self.assertPrivate(response, logs.getvalue())

    def test_quality_error_and_untrusted_mime_type_are_not_echoed(self):
        with patch("main.check_image_quality", side_effect=QualityServiceError(SENSITIVE)), LogCapture() as logs:
            response = self.client.post("/scan/image", files={"file": ("test.png", b"test", "image/png")})
        self.assertEqual(response.status_code, 503)
        self.assertPrivate(response, logs.getvalue())
        response = self.client.post("/scan/image", files={"file": ("test", b"test", "text/" + OPAQUE)})
        self.assertEqual(response.status_code, 400)
        self.assertNotIn(OPAQUE, response.text)

    def test_invalid_and_unexpected_auth_errors_never_echo_the_token(self):
        main.app.dependency_overrides.clear()
        for error in (auth.auth.InvalidIdTokenError(SENSITIVE), RuntimeError(SENSITIVE)):
            with self.subTest(error=type(error)), patch("app.auth.init_firebase_admin"), patch("app.auth.auth.verify_id_token", side_effect=error), LogCapture() as logs:
                response = self.client.get("/users/me", headers={"Authorization": "Bearer " + TOKEN})
            self.assertEqual(response.status_code, 401)
            self.assertEqual(response.headers["www-authenticate"].split()[0], "Bearer")
            self.assertPrivate(response, logs.getvalue())

    def test_validation_errors_do_not_echo_body_parser_context_or_passwords(self):
        for kwargs in ({"json": {"text": {"password": SENSITIVE}}}, {"content": '{"text": "' + OPAQUE, "headers": {"Content-Type": "application/json"}}):
            with LogCapture() as logs:
                response = self.client.post("/scan/text", **kwargs)
            self.assertEqual(response.status_code, 422)
            self.assertPrivate(response, logs.getvalue())
            self.assertNotIn("input", response.json()["detail"][0])

    def test_http_exception_details_headers_and_debug_responses_are_safe(self):
        app = FastAPI(debug=True)
        install_error_handlers(app)

        @app.get("/failure")
        def failure():
            raise HTTPException(503, {"credentials": SENSITIVE}, headers={"X-Secret": SENSITIVE, "WWW-Authenticate": SENSITIVE})

        @app.get("/unhandled")
        def unhandled():
            raise RuntimeError(SENSITIVE)

        with TestClient(app, raise_server_exceptions=False) as client, LogCapture() as logs:
            for route in ("/failure", "/unhandled"):
                response = client.get(route)
                self.assertPrivate(response, logs.getvalue())
                self.assertNotIn("Traceback", response.text)
                self.assertNotIn("x-secret", response.headers)

    def test_success_results_are_unchanged_and_personal_data_is_not_logged(self):
        with patch("main.extract_ingredients", return_value="milk"), patch("main.fetch_user_allergens_from_db", return_value=["Milk"]), patch("main.detect_allergens", return_value=([], True)), LogCapture() as logs:
            response = self.client.post("/scan/text", json={"text": "milk"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["ingredient_list"], "milk")
        self.assertTrue(response.json()["is_safe"])
        self.assertNotIn(OPAQUE, logs.getvalue())


class ProviderFailureTests(unittest.TestCase):
    def test_firebase_and_vision_initialization_failures_are_private(self):
        with patch.object(auth, "_firebase_initialized", False), patch.object(auth.firebase_admin, "_apps", {}), patch.object(auth.FIREBASE_CREDENTIALS.__class__, "exists", return_value=True), patch.object(auth.credentials, "Certificate", side_effect=RuntimeError(SENSITIVE)), patch.object(auth.firebase_admin, "initialize_app", side_effect=RuntimeError(SENSITIVE)), LogCapture() as logs:
            self.assertIsNone(auth.init_firebase_admin())
        self.assertNotIn(OPAQUE, logs.getvalue())
        with patch.object(ocr_service, "_vision_client", None), patch.dict(os.environ, {"GOOGLE_APPLICATION_CREDENTIALS": "not-read-test-path"}), patch("google.cloud.vision_v1.ImageAnnotatorClient", side_effect=RuntimeError(SENSITIVE)), LogCapture() as logs:
            self.assertIsNone(ocr_service.get_vision_client())
        self.assertNotIn(OPAQUE, logs.getvalue())

    def test_model_and_dataset_loading_failures_have_safe_errors(self):
        fake_transformers = SimpleNamespace(AutoTokenizer=MagicMock(), AutoModelForTokenClassification=MagicMock(), pipeline=MagicMock())
        fake_transformers.AutoTokenizer.from_pretrained.side_effect = RuntimeError(SENSITIVE)
        with patch.object(ingredient_service, "_ingredient_pipeline", None), patch.dict(sys.modules, {"transformers": fake_transformers}), patch.object(ingredient_service, "get_device", return_value=-1), LogCapture() as logs:
            with self.assertRaises(RuntimeError) as error:
                ingredient_service.load_ingredient_pipeline()
        self.assertNotIn(OPAQUE, str(error.exception) + logs.getvalue())
        with patch.object(allergen_service, "_dataset_loaded", False), patch("builtins.open", side_effect=ValueError(SENSITIVE)), LogCapture() as logs:
            with self.assertRaises(RuntimeError) as error:
                allergen_service.load_allergen_dataset()
        self.assertNotIn(OPAQUE, str(error.exception) + logs.getvalue())

    def test_vision_retries_preserved_without_logging_provider_error_or_key(self):
        provider = MagicMock()
        provider.document_text_detection.return_value.error.message = SENSITIVE
        provider.document_text_detection.return_value.error.code = 401
        with patch("app.services.ocr_service.get_vision_client", return_value=provider), patch("time.sleep"), LogCapture() as logs:
            with self.assertRaises(RuntimeError) as error:
                ocr_service.perform_ocr(b"test")
        self.assertEqual(provider.document_text_detection.call_count, 2)
        self.assertNotIn(OPAQUE, str(error.exception) + logs.getvalue())
        self.assertIn("vision_api_failed", logs.getvalue())

    def test_database_read_and_write_errors_are_not_rethrown_with_private_causes(self):
        db = MagicMock()
        db.collection.return_value.document.return_value.get.side_effect = RuntimeError(SENSITIVE)
        db.collection.return_value.document.return_value.set.side_effect = RuntimeError(SENSITIVE)
        for operation in (lambda: db_service.fetch_user_allergens_from_db(OPAQUE), lambda: db_service.save_user_allergens_in_db(OPAQUE, ["Milk"])):
            with patch("app.services.user_allergen_service.get_firestore_client", return_value=db), LogCapture() as logs:
                with self.assertRaises(db_service.DatabaseUnavailableError) as error:
                    operation()
            public_traceback = "".join(traceback.format_exception(error.exception))
            self.assertNotIn(OPAQUE, public_traceback + logs.getvalue())

    def test_model_inference_failure_retains_empty_result_fallback_without_logging_text(self):
        pipe = MagicMock(side_effect=RuntimeError(SENSITIVE))
        with patch("app.services.ingredient_service.load_ingredient_pipeline", return_value=pipe), LogCapture() as logs:
            self.assertEqual(ingredient_service.extract_ingredients("Ingredients: milk"), "")
        self.assertNotIn(OPAQUE, logs.getvalue())
        self.assertIn("ingredient_extraction_failed", logs.getvalue())

    def test_profile_service_exceptions_do_not_retain_provider_text(self):
        db = MagicMock()
        db.collection.return_value.document.return_value.get.side_effect = RuntimeError(SENSITIVE)
        operations = (lambda: db_service.get_user_profile_from_db(OPAQUE),
                      lambda: db_service.save_user_profile_in_db(OPAQUE, name="Name"))
        for operation in operations:
            with patch.object(db_service, "get_firestore_client", return_value=db), LogCapture() as logs:
                with self.assertRaises(RuntimeError) as error:
                    operation()
            self.assertNotIn(OPAQUE, "".join(traceback.format_exception(error.exception)) + logs.getvalue())


class DishErrorSafetyTests(unittest.TestCase):
    def test_nested_error_evidence_is_redacted_without_mutating_original(self):
        pipeline = PipelineDouble()
        pipeline.claude = SimpleNamespace(_key=OPAQUE)
        pipeline.quality = SimpleNamespace(api_user="invented-user", api_secret="invented-secret")
        pipeline.result.update(decision="error", message="provider echoed " + OPAQUE,
            stages=[{"data": {"headers": {"X-API-Key": "invented-extra-key", "Cookie": "invented-cookie"},
                              "private_key": PEM, "Authorization": "Bearer " + TOKEN,
                              "text": "provider: invented-secret " + OPAQUE}}])
        original = copy.deepcopy(pipeline.result)
        app, _ = gateway(pipeline)
        with TestClient(app) as client, LogCapture() as logs:
            response = client.post("/scan/dish", headers=AUTH, files={"file": ("test.png", b"test")})
        self.assertEqual(response.status_code, 503)
        self.assertEqual(pipeline.result, original)
        for value in (OPAQUE, TOKEN, "INVENTED_KEY_MATERIAL", "invented-extra-key", "invented-cookie", "invented-secret"):
            self.assertNotIn(value, response.text + logs.getvalue())

    def test_environment_tokens_url_credentials_and_private_keys_are_redacted(self):
        value = {"message": "https://user-Q7R42:pass-Q7R42@example.invalid/path?api_secret=secret-Q7R42 " + PEM + " Bearer " + TOKEN + " " + OPAQUE,
                 "input_tokens": 100, "quality_score": 0.5}
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": OPAQUE}):
            result = redact_sensitive(value)
        serialized = json.dumps(result)
        for secret in (OPAQUE, TOKEN, "INVENTED_KEY_MATERIAL", "user-Q7R42", "pass-Q7R42", "secret-Q7R42"):
            self.assertNotIn(secret, serialized)
        self.assertEqual(result["input_tokens"], 100)
        self.assertEqual(result["quality_score"], 0.5)

    def test_credential_field_aliases_are_case_and_separator_insensitive(self):
        value = {key: OPAQUE for key in ("api_token", "X-Api-Key", "clientSecret", "access_key_id", "secret_key", "refresh-token", "PRIVATE_KEY", "Client_Email", "credentials", "session_id")}
        value.update(input_tokens=42, max_tokens=100)
        serialized = json.dumps(redact_sensitive(value))
        self.assertNotIn(OPAQUE, serialized)
        self.assertEqual(redact_sensitive(value)["input_tokens"], 42)

    def test_startup_exception_is_sanitized_without_starting_requests(self):
        pipeline = PipelineDouble()
        pipeline.load = MagicMock(side_effect=RuntimeError(SENSITIVE))
        app, _ = gateway(pipeline)
        with LogCapture() as logs, self.assertRaises(RuntimeError) as error:
            with TestClient(app):
                pass
        self.assertNotIn(OPAQUE, str(error.exception) + logs.getvalue())
        self.assertEqual(pipeline.paths, [])




if __name__ == "__main__":
    unittest.main()
