"""Label JSON/SSE contracts, real ASGI delivery and cancellation; no provider calls."""
import asyncio
import contextlib
import io
import json
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

import httpx
from fastapi import HTTPException, Request, UploadFile
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent))
import main
from app.auth import get_current_user
from app.models import AllergenDetection
from app.services.label_progress_service import LabelJobs, STAGES, MAX_LABEL_IMAGE_BYTES
from app.services.quality_service import QualityServiceError
from app.services.user_allergen_service import (
    UserDocumentNotFoundError, DatabaseUnavailableError, InvalidAllergyDataError,
)

EXPECTED_PROGRESS = [
    ("image_received", "completed"),
    ("extracting_text", "started"), ("extracting_text", "completed"),
    ("identifying_ingredients", "started"), ("identifying_ingredients", "completed"),
    ("checking_allergens", "started"), ("checking_allergens", "completed"),
]
EXPECTED_RESULT = {
    "success": True, "status": "completed", "error_title": None, "is_safe": False,
    "extracted_ocr_text": "Ingredients: Milk, Sugar", "ingredient_list": "Milk, Sugar",
    "allergens_detected": [{"allergen": "Milk", "matched_ingredients": ["milk"], "is_user_allergen": True}],
    "total_allergens_count": 1, "ocr_engine": "google_vision",
    "message": "Analysis completed successfully.",
}
IMAGE = b"synthetic image bytes; not a dataset image"
AUTH = {"Authorization": "Bearer invented-local-token"}


def frames(text):
    output = []
    for block in text.strip().split("\n\n"):
        if not block.startswith("id:"):
            continue
        lines = block.splitlines()
        output.append((lines[1].split(": ", 1)[1], json.loads(lines[2].split(": ", 1)[1])))
    return output


class LabelDoubles:
    def setUp(self):
        self.guards = contextlib.ExitStack()
        self.addCleanup(self.guards.close)
        self.jobs = LabelJobs()
        self.guards.enter_context(patch.object(main, "_label_jobs", self.jobs))
        main.app.dependency_overrides[get_current_user] = lambda: {"uid": "verified-local-user"}
        self.addCleanup(main.app.dependency_overrides.clear)
        self.quality = self.guards.enter_context(patch.object(main, "check_image_quality", return_value={"accepted": True}))
        self.ocr = self.guards.enter_context(patch.object(main, "perform_ocr", return_value=("Ingredients: Milk, Sugar", "google_vision")))
        self.extract = self.guards.enter_context(patch.object(main, "extract_ingredients", return_value="Milk, Sugar"))
        self.fetch = self.guards.enter_context(patch.object(main, "fetch_user_allergens_from_db", return_value=["Milk"]))
        self.detect = self.guards.enter_context(patch.object(main, "detect_allergens", return_value=(
            [AllergenDetection(allergen="Milk", matched_ingredients=["milk"], is_user_allergen=True)], False)))
        self.client = TestClient(main.app)
        self.addCleanup(self.client.close)

    def scan(self, accept="text/event-stream", image=IMAGE, mime="image/jpeg", **kwargs):
        return self.client.post("/scan/image", headers={**AUTH, "Accept": accept},
                                files={"file": ("private-filename.jpg", image, mime)}, **kwargs)

    def assert_no_processing(self):
        for mock in [self.quality, self.ocr, self.extract, self.detect]:
            mock.assert_not_called()


class LabelSSETests(LabelDoubles, unittest.TestCase):
    def test_exact_legacy_json_payload_without_stream_metadata(self):
        response = self.scan("application/json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), EXPECTED_RESULT)
        self.fetch.assert_called_once_with(user_id="verified-local-user")

    def test_missing_accept_and_zero_or_invalid_sse_quality_keep_json(self):
        for value in ["*/*", "", "text/event-stream;q=0, application/json", "text/event-stream;q=bogus"]:
            with self.subTest(value=value):
                self.assertEqual(self.scan(value).json(), EXPECTED_RESULT)

    def test_sse_contract_progress_ids_one_exact_outcome_and_eof(self):
        response = self.scan()
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.headers["content-type"].startswith("text/event-stream"))
        self.assertEqual(response.headers["cache-control"], "no-store")
        events = frames(response.text)
        self.assertEqual([(p["stage"], p["status"]) for k, p in events if k == "progress"], EXPECTED_PROGRESS)
        self.assertEqual([p["sequence"] for _, p in events], list(range(1, 9)))
        self.assertEqual(len({p["scan_id"] for _, p in events}), 1)
        self.assertEqual([p["result"] for k, p in events if k == "outcome"], [EXPECTED_RESULT])
        self.assertEqual(sum(k in {"outcome", "error"} for k, _ in events), 1)
        for block, (_, payload) in zip(response.text.strip().split("\n\n"), events):
            self.assertEqual(block.splitlines()[0], f"id: {payload['scan_id']}:{payload['sequence']}")
        self.assertEqual(self.fetch.call_count, 2)  # Guard, then fresh original matching lookup.

    def test_original_processing_order_is_preserved_after_read_only_guard(self):
        operations = []
        self.fetch.side_effect = lambda **kw: operations.append("profile") or ["Milk"]
        self.quality.side_effect = lambda data: operations.append("quality") or {"accepted": True}
        self.ocr.side_effect = lambda data: operations.append("ocr") or ("Ingredients: Milk, Sugar", "google_vision")
        self.extract.side_effect = lambda text: operations.append("extract") or "Milk, Sugar"
        self.detect.side_effect = lambda **kw: operations.append("detect") or ([], True)
        self.scan()
        self.assertEqual(operations, ["profile", "quality", "ocr", "extract", "profile", "detect"])

    def test_missing_invalid_and_expired_auth_never_start_stream_or_providers(self):
        main.app.dependency_overrides.clear()
        from firebase_admin import auth
        with patch("app.auth.init_firebase_admin"), patch("app.auth.auth.verify_id_token",
                side_effect=auth.InvalidIdTokenError("PRIVATE_TOKEN_FAILURE")):
            for headers in [{}, {"Authorization": "Broken"}, AUTH]:
                response = self.client.post("/scan/image", headers={**headers, "Accept": "text/event-stream"},
                                            files={"file": ("x", IMAGE, "image/jpeg")})
                self.assertEqual(response.status_code, 401)
                self.assertNotIn("PRIVATE_TOKEN_FAILURE", response.text)
        self.assert_no_processing()
        self.fetch.assert_not_called()

    def test_invalid_verified_uid_fails_before_any_processing(self):
        for uid in [None, "", " ", 123]:
            main.app.dependency_overrides[get_current_user] = lambda value=uid: {"uid": value}
            self.assertEqual(self.scan().status_code, 401)
        self.assert_no_processing()

    def test_expired_and_revoked_firebase_tokens_fail_before_paid_calls(self):
        from firebase_admin import auth
        main.app.dependency_overrides.clear()
        for error in [auth.ExpiredIdTokenError("PRIVATE_EXPIRED", RuntimeError("PRIVATE_CAUSE")),
                      auth.RevokedIdTokenError("PRIVATE_REVOKED")]:
            with patch("app.auth.init_firebase_admin"), patch("app.auth.auth.verify_id_token", side_effect=error):
                response = self.scan()
                self.assertEqual(response.status_code, 401)
                self.assertIn("WWW-Authenticate", response.headers)
                self.assertNotIn("PRIVATE", response.text)
        self.assert_no_processing()
        self.fetch.assert_not_called()

    def test_openapi_documents_both_response_formats_without_changing_json_schema(self):
        content = self.client.get("/openapi.json").json()["paths"]["/scan/image"]["post"]["responses"]["200"]["content"]
        self.assertIn("text/event-stream", content)
        self.assertEqual(content["application/json"]["schema"]["$ref"], "#/components/schemas/ScanResponse")

    def test_invalid_uploads_fail_before_stream_and_profile_or_quality(self):
        for image, mime, code in [(b"", "image/jpeg", 400), (IMAGE, "text/plain", 400),
                                   (b"x" * (MAX_LABEL_IMAGE_BYTES + 1), "image/jpeg", 413)]:
            with self.subTest(code=code):
                response = self.scan(image=image, mime=mime)
                self.assertEqual(response.status_code, code)
                self.assertEqual(response.headers["content-type"], "application/json")
        self.assert_no_processing()
        self.fetch.assert_not_called()

    def test_missing_file_keeps_safe_422_without_processing(self):
        response = self.client.post("/scan/image", headers={**AUTH, "Accept": "text/event-stream"})
        self.assertEqual(response.status_code, 422)
        self.assert_no_processing()

    def test_missing_invalid_or_unavailable_profile_blocks_paid_calls(self):
        for value, status in [(UserDocumentNotFoundError("PRIVATE"), 404),
                              (DatabaseUnavailableError("PRIVATE"), 503),
                              (InvalidAllergyDataError("PRIVATE"), 500), ([], 500), (["Milk", "Milk"], 500)]:
            with self.subTest(value=type(value).__name__):
                self.fetch.side_effect = value if isinstance(value, Exception) else None
                self.fetch.return_value = value
                events = frames(self.scan().text)
                self.assertEqual(len(events), 1)
                self.assertEqual(events[0][0], "error")
                self.assertEqual(events[0][1]["http_status"], status)
                self.assertNotIn("PRIVATE", str(events))
        self.assert_no_processing()

    def test_quality_rejection_does_not_claim_ocr_or_later_completion(self):
        self.quality.return_value = {"accepted": False}
        events = frames(self.scan().text)
        self.assertEqual([(p.get("stage"), p.get("status")) for k, p in events if k == "progress"],
                         [("image_received", "completed")])
        self.assertEqual(events[-1][0], "error")
        self.assertEqual(events[-1][1]["code"], "low_quality")
        self.ocr.assert_not_called()
        self.extract.assert_not_called()

    def test_quality_service_error_has_safe_terminal_and_no_ocr(self):
        self.quality.side_effect = QualityServiceError("SECRET credential data")
        events = frames(self.scan().text)
        self.assertEqual(events[-1][1]["code"], "quality_unavailable")
        self.assertEqual(events[-1][1]["http_status"], 503)
        self.assertNotIn("SECRET", str(events))
        self.ocr.assert_not_called()

    def test_ocr_failure_or_empty_text_never_completes_text_stage(self):
        for value in [RuntimeError("PRIVATE_OCR"), ("", "google_vision"), (" ", "google_vision")]:
            self.ocr.side_effect = value if isinstance(value, Exception) else None
            self.ocr.return_value = value
            events = frames(self.scan().text)
            progress = [(p.get("stage"), p.get("status")) for k, p in events if k == "progress"]
            self.assertEqual(progress, EXPECTED_PROGRESS[:2])
            self.assertEqual(events[-1][0], "error")
            self.assertNotIn("PRIVATE_OCR", str(events))
        self.extract.assert_not_called()

    def test_ingredient_failure_or_missing_output_never_completes_ingredient_stage(self):
        for value in [RuntimeError("PRIVATE_MODEL"), "", " "]:
            self.extract.side_effect = value if isinstance(value, Exception) else None
            self.extract.return_value = value
            events = frames(self.scan().text)
            self.assertEqual([(p.get("stage"), p.get("status")) for k, p in events if k == "progress"], EXPECTED_PROGRESS[:4])
            self.assertEqual(events[-1][0], "error")
            self.assertNotIn("PRIVATE_MODEL", str(events))
        self.detect.assert_not_called()

    def test_matching_failure_never_completes_last_stage(self):
        self.detect.side_effect = RuntimeError("PRIVATE_MATCH")
        events = frames(self.scan().text)
        self.assertEqual([(p.get("stage"), p.get("status")) for k, p in events if k == "progress"], EXPECTED_PROGRESS[:6])
        self.assertEqual(events[-1][1]["code"], "allergen_check_failed")
        self.assertNotIn("PRIVATE_MATCH", str(events))

    def test_fresh_profile_failure_after_extraction_never_starts_matching(self):
        self.fetch.side_effect = [["Milk"], DatabaseUnavailableError("PRIVATE_DATABASE")]
        events = frames(self.scan().text)
        self.assertEqual([(p.get("stage"), p.get("status")) for k, p in events if k == "progress"], EXPECTED_PROGRESS[:5])
        self.assertEqual(events[-1][1]["code"], "profile_unavailable")
        self.detect.assert_not_called()

    def test_forged_allergy_fields_are_ignored_and_verified_uid_is_authoritative(self):
        self.scan(data={"user_allergens": '["Fish"]', "user_id": "forged"})
        self.assertEqual(self.fetch.call_args_list[0].kwargs, {"user_id": "verified-local-user"})
        self.assertEqual(self.detect.call_args.kwargs["user_allergens"], ["Milk"])

    def test_errors_do_not_echo_tokens_bytes_filenames_or_provider_details(self):
        self.quality.side_effect = RuntimeError("OPAQUE_PRIVATE_SECRET")
        response = self.scan(image=b"OPAQUE_PRIVATE_IMAGE")
        for value in ["OPAQUE_PRIVATE_SECRET", "OPAQUE_PRIVATE_IMAGE", "private-filename", "invented-local-token"]:
            self.assertNotIn(value, response.text)

    def test_legacy_rejections_remain_json_200_and_identical_domain_status(self):
        for target, output, status in [(self.quality, {"accepted": False}, "low_quality"),
                                       (self.ocr, ("", "google_vision"), "no_text"),
                                       (self.extract, "", "no_ingredients")]:
            old = target.return_value
            target.return_value = output
            response = self.scan("application/json")
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json()["status"], status)
            self.assertFalse(response.json()["success"])
            target.return_value = old

    def test_backend_matches_checked_in_flutter_contract_fixture(self):
        path = Path(__file__).resolve().parents[2] / "frontend/test/support/label_backend_stream.sse"
        events = frames(self.scan().text)
        actual = [(kind, {**p, "scan_id": "label-fixture"}) for kind, p in events]
        self.assertEqual(actual, frames(path.read_text()))


class LabelDeliveryTests(LabelDoubles, unittest.IsolatedAsyncioTestCase):
    def request_parts(self):
        request = httpx.Request("POST", "http://test/scan/image", headers={**AUTH, "Accept": "text/event-stream"},
                                files={"file": ("test.jpg", IMAGE, "image/jpeg")})
        body = request.read()
        scope = {"type": "http", "asgi": {"version": "3.0", "spec_version": "2.3"}, "http_version": "1.1",
                 "method": "POST", "scheme": "http", "path": "/scan/image", "raw_path": b"/scan/image",
                 "query_string": b"", "headers": [(k.lower(), v) for k, v in request.headers.raw],
                 "server": ("test", 80), "client": ("local", 1)}
        return scope, body

    async def start_request(self):
        scope, body = self.request_parts()
        disconnect = asyncio.Event()
        delivered = asyncio.Queue()
        sent = False

        async def receive():
            nonlocal sent
            if not sent:
                sent = True
                return {"type": "http.request", "body": body, "more_body": False}
            await disconnect.wait()
            return {"type": "http.disconnect"}

        async def send(message):
            if message["type"] == "http.response.body" and message.get("body"):
                delivered.put_nowait(message["body"])
        return asyncio.create_task(main.app(scope, receive, send)), disconnect, delivered

    async def drain_workers(self):
        for _ in range(200):
            if not self.jobs.pending:
                return
            await asyncio.sleep(.005)
        self.fail("Worker did not clean up.")

    async def test_progress_arrives_while_quality_is_blocked_and_disconnect_stops_next_calls(self):
        entered, release = threading.Event(), threading.Event()
        def quality(data):
            entered.set()
            if not release.wait(3):
                raise RuntimeError("Test worker was not released.")
            return {"accepted": True}
        self.quality.side_effect = quality
        running, disconnect, delivered = await self.start_request()
        try:
            self.assertTrue(await asyncio.to_thread(entered.wait, 2))
            data = await asyncio.wait_for(delivered.get(), 1)
            self.assertIn(b'"image_received"', data)
            self.assertNotIn(b'"extracting_text"', data)
            self.assertNotIn(b"outcome", data)
            disconnect.set()
            await asyncio.wait_for(running, 1)
            self.assertTrue(self.jobs.lock.locked())
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=main.app), base_url="http://test") as client:
                other = await client.post("/scan/image", headers={**AUTH, "Accept": "text/event-stream"},
                                          files={"file": ("x", IMAGE, "image/jpeg")})
            self.assertEqual(other.status_code, 429)
        finally:
            disconnect.set()
            release.set()
            await self.drain_workers()
            if not running.done():
                await running
        self.quality.assert_called_once()
        self.ocr.assert_not_called()
        self.extract.assert_not_called()
        self.detect.assert_not_called()
        self.assertFalse(self.jobs.lock.locked())

    async def test_each_stage_completion_waits_for_its_actual_operation(self):
        for target, stage in [(self.ocr, "extracting_text"), (self.extract, "identifying_ingredients"), (self.detect, "checking_allergens")]:
            entered, release = threading.Event(), threading.Event()
            result = target.return_value
            def block(*args, value=result, **kwargs):
                entered.set()
                if not release.wait(3):
                    raise RuntimeError("Test worker was not released.")
                return value
            target.side_effect = block
            running, disconnect, delivered = await self.start_request()
            try:
                self.assertTrue(await asyncio.to_thread(entered.wait, 2))
                content = b""
                while f'"stage": "{stage}", "status": "started"'.encode() not in content:
                    content += await asyncio.wait_for(delivered.get(), 1)
                self.assertNotIn(f'"stage": "{stage}", "status": "completed"'.encode(), content)
                self.assertNotIn(b"outcome", content)
                release.set()
                await asyncio.wait_for(running, 2)
                while not delivered.empty():
                    content += delivered.get_nowait()
                self.assertEqual(frames(content.decode())[-1][0], "outcome")
            finally:
                release.set()
                disconnect.set()
                if not running.done():
                    await running
                await self.drain_workers()
                target.side_effect = None

    async def test_heartbeats_are_not_progress_and_cancellation_during_preflight_is_safe(self):
        entered, release = threading.Event(), threading.Event()
        def profile(**kwargs):
            entered.set()
            release.wait(3)
            return ["Milk"]
        self.fetch.side_effect = profile
        with patch("app.services.label_progress_service.HEARTBEAT_SECONDS", .01):
            running, disconnect, delivered = await self.start_request()
            try:
                self.assertTrue(await asyncio.to_thread(entered.wait, 2))
                self.assertEqual(await asyncio.wait_for(delivered.get(), 1), b": keep-alive\n\n")
                disconnect.set()
                await asyncio.wait_for(running, 1)
            finally:
                release.set()
                disconnect.set()
                if not running.done():
                    await running
                await self.drain_workers()
        self.assert_no_processing()

    async def test_send_headers_failure_releases_reservation_without_starting_worker(self):
        scope, _ = self.request_parts()
        response = self.jobs.stream(lambda *args: self.fail("Worker must not start"), lambda: None)
        async def receive():
            await asyncio.Event().wait()
        async def send(message):
            if message["type"] == "http.response.start":
                raise RuntimeError("Local disconnect at headers")
        with self.assertRaises(Exception):
            await response(scope, receive, send)
        self.assertFalse(self.jobs.lock.locked())
        self.assertEqual(len(self.jobs.pending), 0)

    async def test_upload_is_closed_even_for_pre_stream_validation_errors(self):
        for data, mime in [(b"", "image/jpeg"), (IMAGE, "text/plain"), (IMAGE, "image/jpeg")]:
            file = UploadFile(io.BytesIO(data), headers={"content-type": mime})
            scope, _ = self.request_parts()
            request = Request(scope)
            response = None
            try:
                response = await main.scan_image(request, file, {"uid": "verified-local-user"})
            except HTTPException:
                pass
            self.assertTrue(file.file.closed)
            if response is not None:
                response._cleanup()
            self.assertFalse(self.jobs.lock.locked())


if __name__ == "__main__":
    unittest.main()
