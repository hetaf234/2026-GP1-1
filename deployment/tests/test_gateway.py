import asyncio
from contextlib import asynccontextmanager
from copy import deepcopy
import json
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.testclient import TestClient
import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Packaged-Food-Recognition/Server"))

from deployment.gateway import create_gateway
from test_dish_allergen_matching import CATEGORIES, pipeline_result
from app.services import user_allergen_service


def authenticate(authorization: str | None = Header(None)):
    if authorization != "Bearer local-test-token":
        raise HTTPException(401, "Authentication required")
    return {"uid": "verified-test-uid"}


class PipelineDouble:
    setup_errors = []

    def __init__(self):
        self.runtime = self
        self.loads = 0
        self.paths = []
        self.fail = False
        self.entered = threading.Event()
        self.release = threading.Event()
        self.block = False
        self.categories = CATEGORIES
        self.result = pipeline_result()
        self.result.update(final_dish="dajaj-mashwi", final_dish_display_name_en="Grilled Chicken",
                           registry_sha256="unchanged-test-authority")

    def load(self):
        self.loads += 1

    def _check_authority(self):
        pass

    def run(self, path, *, filename, progress=None):
        self.paths.append(Path(path))
        if self.fail:
            raise RuntimeError("TEST_PRIVATE_VALUE")
        if self.block:
            self.entered.set()
            if not self.release.wait(5):
                raise RuntimeError("Test worker did not finish")
        if progress is not None:
            progress.update("image_received", "running")
            progress.update("image_received", "completed")
            progress.update("identifying_ingredients", "running")
            progress.update("identifying_ingredients", "completed")
        return self.result


def gateway(pipeline):
    lifecycle = []

    @asynccontextmanager
    async def lifespan(app):
        lifecycle.append("start")
        yield
        lifecycle.append("stop")

    labels = FastAPI(lifespan=lifespan)

    @labels.get("/users/me/allergies")
    def allergies(user=Depends(authenticate)):
        return {"allergies": ["Egg"]}

    @labels.post("/scan/image")
    def image(user=Depends(authenticate)):
        return {"label_contract": "unchanged"}

    return create_gateway(labels, authenticate, pipeline, lambda: lifecycle.append("label_model")), lifecycle


AUTH = {"Authorization": "Bearer local-test-token"}


class GatewayTests(unittest.TestCase):
    def setUp(self):
        profile = patch.object(user_allergen_service, "fetch_user_allergens_from_db", return_value=["Egg"])
        self.profile = profile.start()
        self.addCleanup(profile.stop)

    def test_existing_routes_and_lifecycle_are_preserved(self):
        pipeline = PipelineDouble()
        app, lifecycle = gateway(pipeline)
        with TestClient(app) as client:
            self.assertTrue(client.get("/ready").json()["ready"])
            self.assertEqual(pipeline.loads, 1)
            self.assertEqual(client.get("/users/me/allergies", headers=AUTH).json(), {"allergies": ["Egg"]})
            self.assertEqual(client.post("/scan/image", headers=AUTH).json(), {"label_contract": "unchanged"})
        self.assertEqual(lifecycle, ["start", "label_model", "stop"])
        with TestClient(app, raise_server_exceptions=False) as client:
            self.assertEqual(client.get("/users/me/allergies").status_code, 401)

    def test_unauthenticated_scan_never_calls_pipeline(self):
        pipeline = PipelineDouble()
        app, _ = gateway(pipeline)
        with TestClient(app) as client:
            response = client.post("/scan/dish", files={"file": ("label.png", b"test", "image/png")})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(pipeline.paths, [])

    def test_authenticated_scan_returns_original_evidence_and_cleans_upload(self):
        pipeline = PipelineDouble()
        original = deepcopy(pipeline.result)
        app, _ = gateway(pipeline)
        with TestClient(app) as client:
            response = client.post("/scan/dish", headers=AUTH,
                                   data={"user_id": "untrusted", "user_allergens": "invented"},
                                   files={"file": ("../../private.png", b"test", "image/png")})
        self.assertEqual(response.status_code, 200)
        result = response.json()
        self.assertEqual(pipeline.result, original)
        for key in ("stages", "registry_sha256", "final_dish", "final_dish_display_name_en", "protocol"):
            self.assertEqual(result[key], original[key])
        self.assertTrue(result["user_allergy_matching_performed"])
        self.assertEqual(result["personalization"]["status"], "completed")
        self.assertEqual([m["allergen"] for m in result["personalization"]["matches"]], ["Egg"])
        self.assertEqual(result["personalization"]["matches"][0]["causes"],
                         original["stages"][1]["data"]["allergen_causing_ingredients"]["Egg"])
        self.profile.assert_called_once_with(user_id="verified-test-uid")
        self.assertFalse(pipeline.paths[0].exists())
        self.assertEqual(pipeline.paths[0].name, "upload.image")

    def test_authenticated_gateway_stream_preserves_personalized_contract(self):
        pipeline = PipelineDouble()
        original = deepcopy(pipeline.result)
        app, _ = gateway(pipeline)
        with TestClient(app) as client:
            response = client.post("/scan/dish", headers={**AUTH, "Accept": "text/event-stream"},
                                   data={"user_id": "forged", "user_allergens": "Milk"},
                                   files={"file": ("test.png", b"test", "image/png")})
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.headers["content-type"].startswith("text/event-stream"))
        self.assertEqual(response.headers["cache-control"], "no-store")
        events = [(frame.splitlines()[0], json.loads(frame.splitlines()[1].removeprefix("data: ")))
                  for frame in response.text.strip().split("\n\n")]
        self.assertEqual([event for event, _ in events], ["event: progress"] * 6 + ["event: outcome"])
        self.assertEqual([payload["sequence"] for _, payload in events], list(range(1, 8)))
        self.assertEqual(len({payload["scan_id"] for _, payload in events}), 1)
        self.assertEqual([(p["stage"], p["status"]) for _, p in events[:-1]],
                         [(s, v) for s in ("image_received", "identifying_ingredients", "checking_allergens")
                          for v in ("running", "completed")])
        terminal = events[-1][1]
        self.assertEqual(terminal["http_status"], 200)
        self.assertEqual(terminal["result"]["personalization"]["matches"][0]["allergen"], "Egg")
        self.assertEqual(pipeline.result, original)
        self.profile.assert_called_once_with(user_id="verified-test-uid")
        self.assertEqual(len(pipeline.paths), 1)
        self.assertFalse(pipeline.paths[0].exists())

    def test_pipeline_rejection_and_provider_error_keep_their_meaning(self):
        for decision, status in [("rejected", 200), ("error", 503)]:
            with self.subTest(decision=decision):
                pipeline = PipelineDouble()
                pipeline.result.update(decision=decision, final_dish=None)
                app, _ = gateway(pipeline)
                with TestClient(app) as client:
                    response = client.post("/scan/dish", headers=AUTH, files={"file": ("test.png", b"test")})
                self.assertEqual(response.status_code, status)
                self.assertEqual(response.json(), pipeline.result)

    def test_internal_exception_does_not_expose_private_details(self):
        pipeline = PipelineDouble()
        pipeline.fail = True
        app, _ = gateway(pipeline)
        with TestClient(app) as client:
            response = client.post("/scan/dish", headers=AUTH, files={"file": ("test.png", b"test")})
        self.assertEqual(response.status_code, 503)
        self.assertNotIn("TEST_PRIVATE_VALUE", response.text)
        self.assertFalse(pipeline.paths[0].exists())

    def test_upload_limits_precede_model_and_provider_calls(self):
        pipeline = PipelineDouble()
        app, _ = gateway(pipeline)
        with TestClient(app) as client:
            for data, status in [(b"", 400), (b"x" * (4 * 1024 * 1024 + 1), 413)]:
                response = client.post("/scan/dish", headers=AUTH, files={"file": ("test.png", data)})
                self.assertEqual(response.status_code, status)
        self.assertEqual(pipeline.paths, [])

    def test_missing_configuration_cannot_report_ready(self):
        pipeline = PipelineDouble()
        pipeline.setup_errors = ["Missing private configuration"]
        app, _ = gateway(pipeline)
        with self.assertRaises(RuntimeError):
            with TestClient(app):
                pass
        self.assertEqual(TestClient(app).get("/ready").status_code, 503)


class CancellationTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        profile = patch.object(user_allergen_service, "fetch_user_allergens_from_db", return_value=["Egg"])
        profile.start()
        self.addCleanup(profile.stop)

    async def test_cancelled_caller_does_not_unlock_an_inflight_paid_operation(self):
        pipeline = PipelineDouble()
        pipeline.block = True
        app, _ = gateway(pipeline)
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="http://test") as client:
            async def scan():
                return await client.post("/scan/dish", headers=AUTH, files={"file": ("test.png", b"test")})

            first = asyncio.create_task(scan())
            self.assertTrue(await asyncio.to_thread(pipeline.entered.wait, 2))
            try:
                first.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await first
                self.assertEqual((await scan()).status_code, 429)
                self.assertEqual(len(pipeline.paths), 1)
            finally:
                pipeline.release.set()
            for _ in range(100):
                await asyncio.sleep(0.01)
                next_scan = await scan()
                if next_scan.status_code != 429:
                    break
            self.assertEqual(next_scan.status_code, 200)
            self.assertTrue(all(not path.exists() for path in pipeline.paths))


if __name__ == "__main__":
    unittest.main()
