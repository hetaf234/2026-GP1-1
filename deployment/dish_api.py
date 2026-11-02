"""Authenticated JSON/SSE access to the unchanged, serialized Dish pipeline."""
from __future__ import annotations

import asyncio
from copy import deepcopy
import logging
from pathlib import Path
import tempfile
import threading
import uuid

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse


def dish_router(pipeline, authenticate, *, max_bytes=4 * 1024 * 1024):
    from app.log_safety import log_event, redact_sensitive
    from app.services.dish_allergen_service import DishEvidenceError, SAFETY_NOTICE, personalize_dish_result
    from app.services.dish_progress_service import DishProgress, encode_event, public_result
    from app.services.user_allergen_service import (
        DatabaseUnavailableError, InvalidAllergyDataError, UserDocumentNotFoundError,
    )
    router = APIRouter()
    lock = threading.Lock()
    pending = set()

    def secrets():
        claude, quality = getattr(pipeline, "claude", None), getattr(pipeline, "quality", None)
        return (getattr(claude, "_key", None), getattr(quality, "api_user", None), getattr(quality, "api_secret", None))

    def run_image(data, uid, progress=None):
        # The actual synchronous worker owns both upload lifetime and the lock.
        # Cancelling an HTTP waiter cannot unlock a still-running provider call.
        try:
            with tempfile.TemporaryDirectory(prefix="misbar-dish-") as folder:
                image = Path(folder) / "upload.image"
                image.write_bytes(data)
                kwargs = {"filename": "upload.image"}
                if progress is not None:
                    kwargs["progress"] = progress
                result = pipeline.run(image, **kwargs)
                if result.get("decision") != "accepted":
                    return deepcopy(result), 503 if result.get("decision") == "error" else 200
                if progress is not None:
                    progress.update("checking_allergens", "running")
                try:
                    output = personalize_dish_result(result, uid, categories=pipeline.categories)
                    if progress is not None:
                        progress.update("checking_allergens", "completed" if output["personalization"]["status"] == "completed" else "error")
                    return output, 200
                except UserDocumentNotFoundError:
                    code, status, message = "profile_not_found", 404, "Save your allergy preferences before scanning."
                except DatabaseUnavailableError:
                    code, status, message = "profile_unavailable", 503, "Allergy preferences could not be retrieved."
                except InvalidAllergyDataError:
                    code, status, message = "invalid_allergy_profile", 500, "Saved allergy preferences are invalid."
                except DishEvidenceError:
                    code, status, message = "invalid_dish_evidence", 503, "Dish normalization evidence could not be matched."
                if progress is not None:
                    progress.update("checking_allergens", "error")
                output = deepcopy(result)
                output.update(decision="error", stopped_at="user_allergy_matching",
                              user_allergy_matching_performed=False, message=message,
                              personalization={"status": "error", "error_code": code,
                                               "safety_assessment": "not_established", "notice": SAFETY_NOTICE})
                return output, status
        finally:
            lock.release()

    def keep_worker(task):
        pending.add(task)
        def done(finished):
            pending.discard(finished)
            if not finished.cancelled():
                finished.exception()  # Consume failures even if the caller disconnected.
        task.add_done_callback(done)

    @router.post("/scan/dish", tags=["Dish scanner"])
    async def scan_dish(request: Request, file: UploadFile = File(...), current_user: dict = Depends(authenticate)):
        uid = current_user.get("uid")
        if not isinstance(uid, str) or not uid.strip():
            await file.close()
            raise HTTPException(401, "A verified Firebase user is required.")
        if not lock.acquire(blocking=False):
            await file.close()
            raise HTTPException(429, "Dish analysis is busy. Please retry later.", headers={"Retry-After": "5"})
        worker_started = False
        try:
            data = await file.read(max_bytes + 1)
            if not data:
                raise HTTPException(400, "The image file is empty.")
            if len(data) > max_bytes:
                raise HTTPException(413, "The image exceeds 4 MB.")
            streaming = any(part.split(";", 1)[0].strip().lower() == "text/event-stream"
                            and not any(p.strip().lower() in {"q=0", "q=0.0", "q=0.00", "q=0.000"} for p in part.split(";")[1:])
                            for part in request.headers.get("accept", "").split(","))
            if not streaming:
                worker = asyncio.create_task(asyncio.to_thread(run_image, data, uid))
                worker_started = True
                keep_worker(worker)
                result, status = await asyncio.shield(worker)
                if result.get("decision") == "error":
                    result = redact_sensitive(result, secret_values=secrets())
                return JSONResponse(result, status_code=status)

            loop = asyncio.get_running_loop()
            # At most a handful of indicator transitions, not all audit emits.
            queue = asyncio.Queue()
            disconnected = threading.Event()
            scan_id, sequence = uuid.uuid4().hex, 0
            def send(kind, payload):
                nonlocal sequence
                if disconnected.is_set() or loop.is_closed():
                    return
                sequence += 1
                frame = encode_event(kind, {"scan_id": scan_id, "sequence": sequence, **payload})
                try:
                    loop.call_soon_threadsafe(queue.put_nowait, (kind, frame))
                except RuntimeError:
                    # Shutdown/disconnect must not change pipeline decisions.
                    disconnected.set()
            def stream_worker():
                try:
                    result, status = run_image(data, uid, DishProgress(send))
                    send("outcome", {"http_status": status, "result": public_result(result, secret_values=secrets())})
                except Exception:
                    log_event(logging.getLogger(__name__), logging.ERROR, "dish_scan_failed")
                    send("outcome", {"http_status": 503, "result": {"decision": "error", "stopped_at": "analysis",
                                                                               "error_code": "dish_scan_failed"}})
            worker = asyncio.create_task(asyncio.to_thread(stream_worker))
            worker_started = True
            keep_worker(worker)

            async def events():
                try:
                    while True:
                        try:
                            kind, frame = await asyncio.wait_for(queue.get(), timeout=15)
                        except asyncio.TimeoutError:
                            yield ": keep-alive\n\n"
                            continue
                        yield frame
                        if kind == "outcome":
                            return
                finally:
                    disconnected.set()
                    # Worker keeps the lock/upload until synchronous work ends.
            return StreamingResponse(events(), media_type="text/event-stream",
                                     headers={"Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})
        except HTTPException:
            raise
        except asyncio.CancelledError:
            raise
        except Exception:
            log_event(logging.getLogger(__name__), logging.ERROR, "dish_scan_failed")
            raise HTTPException(503, "Dish analysis could not complete. Please retry later.") from None
        finally:
            try:
                await file.close()
            finally:
                if not worker_started:
                    lock.release()
    return router
