"""Bounded, cancellable Label SSE delivery; never stream audit/provider data."""
from __future__ import annotations

import asyncio
import json
import logging
import threading
import uuid

from fastapi import HTTPException
from fastapi.responses import StreamingResponse

from app.log_safety import log_event

MAX_LABEL_IMAGE_BYTES = 4 * 1024 * 1024
STAGES = ("image_received", "extracting_text", "identifying_ingredients", "checking_allergens")
HEARTBEAT_SECONDS = 15


class LabelScanStopped(Exception):
    """Stop between operations; an already running synchronous call keeps its lock."""


def wants_label_stream(accept):
    for item in accept.split(","):
        media, *parameters = item.split(";")
        if media.strip().lower() != "text/event-stream":
            continue
        quality = 1.0
        try:
            for parameter in parameters:
                key, separator, value = parameter.strip().partition("=")
                if separator and key.lower() == "q":
                    quality = float(value.strip())
            if 0 < quality <= 1:
                return True
        except ValueError:
            continue
    return False


def encode_event(kind, payload):
    return (f"id: {payload['scan_id']}:{payload['sequence']}\n"
            f"event: {kind}\ndata: {json.dumps(payload, ensure_ascii=False, allow_nan=False)}\n\n")


def public_error(error, active_stage=None):
    """Only fixed reviewed strings; exception/provider text is never serialized."""
    if isinstance(error, HTTPException):
        if error.status_code == 404:
            return 404, "profile_not_found", "Save your allergy preferences before scanning."
        if error.status_code == 500 and error.detail == "Invalid allergy data in database.":
            return 500, "invalid_allergy_profile", "Your saved allergy preferences could not be verified."
        if error.status_code == 503:
            if error.detail == "Image quality service is unavailable. Please retry later.":
                return 503, "quality_unavailable", "The image quality check could not complete. Please try again."
            return 503, "profile_unavailable", "Your saved allergy preferences could not be loaded. Please try again."
    code = {
        "extracting_text": "ocr_failed",
        "identifying_ingredients": "ingredient_extraction_failed",
        "checking_allergens": "allergen_check_failed",
    }.get(active_stage, "analysis_failed")
    return 500, code, "Label analysis could not complete. Please try again."


CONTENT_ERRORS = {
    "low_quality": "Please retake the label photo in good lighting and keep the camera steady.",
    "no_text": "The label does not contain readable text. Please photograph a clear ingredient list.",
    "no_ingredients": "No ingredient list was found. Please photograph the Ingredients section.",
}


class _LabelResponse(StreamingResponse):
    def __init__(self, content, cleanup):
        self._cleanup = cleanup
        super().__init__(content, media_type="text/event-stream", headers={
            "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
            "X-Accel-Buffering": "no",
        })

    async def __call__(self, scope, receive, send):
        try:
            await super().__call__(scope, receive, send)
        finally:
            # Also covers failure/disconnection while sending response headers,
            # before the body generator (and its finally block) has started.
            self._cleanup()


class LabelJobs:
    """Serialize the shared local model. HTTP cancellation never unlocks a worker."""
    def __init__(self):
        self.lock = threading.Lock()
        self.pending = set()

    def _keep(self, task):
        self.pending.add(task)

        def done(finished):
            self.pending.discard(finished)
            if not finished.cancelled():
                finished.exception()
        task.add_done_callback(done)

    async def json(self, work):
        def run():
            with self.lock:
                return work()
        task = asyncio.create_task(asyncio.to_thread(run))
        self._keep(task)
        return await asyncio.shield(task)

    def stream(self, work, preflight):
        if not self.lock.acquire(blocking=False):
            raise HTTPException(429, "Too many requests.", headers={"Retry-After": "5"})

        loop = asyncio.get_running_loop()
        queue = asyncio.Queue(maxsize=16)  # Seven progress transitions + one terminal.
        stopped = threading.Event()
        scan_id = uuid.uuid4().hex
        sequence = 0
        worker_started = False
        reservation_released = False
        active_stage = None
        states = {}

        def check():
            if stopped.is_set():
                raise LabelScanStopped()

        def send(kind, payload):
            nonlocal sequence
            if stopped.is_set() or loop.is_closed():
                return
            sequence += 1
            frame = encode_event(kind, {"scan_id": scan_id, "sequence": sequence, **payload})

            def enqueue():
                if not stopped.is_set():
                    queue.put_nowait((kind, frame))
            try:
                loop.call_soon_threadsafe(enqueue)
            except RuntimeError:
                stopped.set()

        def progress(stage, status):
            nonlocal active_stage
            check()
            if stage not in STAGES or status not in {"started", "completed"}:
                raise ValueError("Invalid label progress.")
            if states.get(stage) == status:
                return
            index = STAGES.index(stage)
            if index and states.get(STAGES[index - 1]) != "completed":
                raise ValueError("Out-of-order label progress.")
            if status == "started" and stage in states:
                raise ValueError("Regressed label progress.")
            if status == "completed" and index and states.get(stage) != "started":
                raise ValueError("Unstarted label progress.")
            states[stage] = status
            active_stage = stage if status == "started" else None
            send("progress", {"stage": stage, "status": status})

        def worker():
            try:
                check()
                preflight()  # Read-only authorization guard before paid processing.
                check()
                progress("image_received", "completed")
                result = work(progress, check)
                check()
                if not result.success:
                    message = CONTENT_ERRORS.get(result.status)
                    if message is None:
                        raise ValueError("Invalid label rejection.")
                    send("error", {"http_status": 422, "code": result.status, "message": message})
                else:
                    if not all(states.get(stage) == "completed" for stage in STAGES):
                        raise ValueError("Unconfirmed label completion.")
                    send("outcome", {"http_status": 200, "result": result.model_dump()})
            except LabelScanStopped:
                pass
            except Exception as error:
                status, code, message = public_error(error, active_stage)
                log_event(logging.getLogger("allergen_scanner"), logging.ERROR, "image_scan_failed")
                send("error", {"http_status": status, "code": code, "message": message})
            finally:
                self.lock.release()

        def cleanup():
            nonlocal reservation_released
            stopped.set()
            if not worker_started and not reservation_released:
                reservation_released = True
                self.lock.release()

        async def events():
            nonlocal worker_started
            try:
                check()
                worker_started = True
                task = asyncio.create_task(asyncio.to_thread(worker))
                self._keep(task)
                while True:
                    try:
                        kind, frame = await asyncio.wait_for(queue.get(), HEARTBEAT_SECONDS)
                    except asyncio.TimeoutError:
                        yield ": keep-alive\n\n"
                        continue
                    yield frame
                    if kind in {"outcome", "error"}:
                        return
            finally:
                cleanup()

        return _LabelResponse(events(), cleanup)
