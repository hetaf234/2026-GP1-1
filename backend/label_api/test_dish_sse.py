"""Local JSON/SSE contracts and real delivery; all providers/Firebase are doubles."""
import asyncio
from copy import deepcopy
import json
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_dish_allergen_matching import AUTH, FakePipeline, make_app, user_allergen_service
from fastapi.testclient import TestClient
import httpx


class ProgressPipeline(FakePipeline):
    def __init__(self):
        super().__init__()
        self.result['final_dish_display_name_en'] = 'Synthetic meal'
        self.fail = None

    def run(self, path, *, filename, progress=None):
        self.paths.append(Path(path))
        snapshot = {'stages': [{'id': key, 'status': 'pending'} for key in (
            'upload', 'quality', 'food_gate', 'classification', 'ood', 'dataset', 'extraction', 'fusion', 'normalization')]}
        def emit(stage, status):
            for item in snapshot['stages']:
                if item['id'] == stage:
                    item['status'] = status
                    item['request_evidence'] = {'prompt': 'PRIVATE_PROMPT', 'raw_response': 'PRIVATE_RESPONSE'}
                    if status == 'error':
                        item['data'] = {'error_code': 'timeout', 'raw_response': 'PRIVATE_RESPONSE'}
            if progress:
                progress(snapshot)
                progress(snapshot)  # Repeated audit updates do not duplicate transitions.
        emit('upload', 'running')
        emit('upload', 'passed')
        emit('quality', 'running')
        self.entered.set()
        if self.block and not self.release.wait(5):
            raise RuntimeError('Timed out test worker')
        if self.fail == 'exception':
            raise RuntimeError('PRIVATE_EXCEPTION')
        if self.fail:
            stage, decision = self.fail
            emit(stage, decision)
            return {'decision': decision, 'stopped_at': stage, 'stages': deepcopy(snapshot['stages'])}
        for stage in ['quality', 'food_gate', 'classification', 'ood', 'dataset', 'extraction', 'fusion', 'normalization']:
            emit(stage, 'passed' if stage in ['quality', 'food_gate', 'ood'] else 'complete')
        return self.result


def frames(text):
    return [(block.splitlines()[0].split(': ', 1)[1], json.loads(block.split('data: ', 1)[1]))
            for block in text.strip().split('\n\n') if block.startswith('event: ')]


class SSETests(unittest.TestCase):
    def setUp(self):
        self.pipeline = ProgressPipeline()
        self.client = TestClient(make_app(self.pipeline))
        self.addCleanup(self.client.close)
        p = patch.object(user_allergen_service, 'fetch_user_allergens_from_db', return_value=['Egg', 'Milk', 'Soybean'])
        self.fetch = p.start(); self.addCleanup(p.stop)

    def scan(self, stream=True, headers=None):
        return self.client.post('/scan/dish', headers=headers or {**AUTH, 'Accept': 'text/event-stream' if stream else 'application/json'},
                                files={'file': ('dish.png', b'synthetic')})

    def test_stream_emits_confirmed_progress_and_one_exact_personalized_outcome(self):
        before = deepcopy(self.pipeline.result)
        response = self.scan()
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.headers['content-type'].startswith('text/event-stream'))
        events = frames(response.text)
        progress = [(e['stage'], e['status']) for kind, e in events if kind == 'progress']
        self.assertEqual(progress, [('image_received', 'running'), ('image_received', 'completed'),
                                   ('identifying_ingredients', 'running'), ('identifying_ingredients', 'completed'),
                                   ('checking_allergens', 'running'), ('checking_allergens', 'completed')])
        self.assertEqual([e['sequence'] for _, e in events], list(range(1, len(events) + 1)))
        self.assertEqual(len({e['scan_id'] for _, e in events}), 1)
        terminal = [e for kind, e in events if kind == 'outcome']
        self.assertEqual(len(terminal), 1)
        result = terminal[0]['result']
        self.assertEqual([m['allergen'] for m in result['personalization']['matches']], ['Egg', 'Milk', 'Soybean'])
        for match in result['personalization']['matches']:
            self.assertEqual(match['causes'], before['stages'][-1]['data']['allergen_causing_ingredients'][match['allergen']])
        self.assertEqual(len(self.pipeline.paths), 1)
        self.assertFalse(self.pipeline.paths[0].exists())
        self.assertEqual(self.pipeline.result, before)
        self.fetch.assert_called_once_with(user_id='alice-verified')
        self.assertNotIn('PRIVATE_', response.text)
        self.assertNotIn('request_evidence', response.text)
        self.assertNotIn('protocol', result)

    def test_json_preserves_original_stages_and_has_no_stream_events(self):
        response = self.scan(False)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['stages'], self.pipeline.result['stages'])
        self.assertEqual(len(self.pipeline.paths), 1)
        self.assertNotIn('event:', response.text)

    def test_authentication_precedes_stream_and_pipeline(self):
        response = self.scan(headers={'Accept': 'text/event-stream'})
        self.assertEqual(response.status_code, 401)
        self.assertEqual(self.pipeline.paths, [])
        self.fetch.assert_not_called()

    def test_rejections_and_provider_errors_are_terminal_events_not_completion(self):
        for failure in [('quality', 'rejected'), ('food_gate', 'rejected'), ('ood', 'rejected'), ('extraction', 'error')]:
            with self.subTest(failure=failure):
                self.pipeline.fail = failure
                events = frames(self.scan().text)
                result = events[-1][1]['result']
                self.assertEqual((result['decision'], result['stopped_at']), (failure[1], failure[0]))
                self.assertEqual(sum(k == 'outcome' for k, _ in events), 1)
                self.assertFalse(any(e.get('stage') == 'checking_allergens' for _, e in events))
                if failure[1] == 'error':
                    stage = next(s for s in result['stages'] if s['id'] == failure[0])
                    self.assertEqual(stage['error_code'], 'timeout')
                    self.assertNotIn('PRIVATE_RESPONSE', str(result))
        self.fetch.assert_not_called()

    def test_profile_failure_and_invalid_selections_never_confirm_completion(self):
        for value in [user_allergen_service.DatabaseUnavailableError('PRIVATE_ERROR'), [], ['Egg', 'unknown allergy'], ['Dairy'], ['Milk', 'Milk']]:
            self.fetch.side_effect = value if isinstance(value, Exception) else None
            self.fetch.return_value = value
            events = frames(self.scan().text)
            self.assertIn(('checking_allergens', 'error'), [(e.get('stage'), e.get('status')) for _, e in events])
            self.assertNotIn('PRIVATE_ERROR', str(events))
            self.assertNotEqual(events[-1][1]['result']['personalization']['status'], 'completed')

    def test_unexpected_worker_failure_has_one_safe_terminal_error_and_unlocks(self):
        self.pipeline.fail = 'exception'
        response = self.scan()
        self.assertEqual(frames(response.text)[-1][1]['result']['decision'], 'error')
        self.assertNotIn('PRIVATE_EXCEPTION', response.text)
        self.pipeline.fail = None
        self.assertEqual(frames(self.scan().text)[-1][1]['result']['decision'], 'accepted')

    def test_opt_out_accept_quality_zero_keeps_json(self):
        self.assertTrue(self.scan(headers={**AUTH, 'Accept': 'text/event-stream;q=0, application/json'}).headers['content-type'].startswith('application/json'))

    def test_nonzero_accept_quality_enables_stream(self):
        self.assertTrue(self.scan(headers={**AUTH, 'Accept': 'text/event-stream;q=0.5'}).headers['content-type'].startswith('text/event-stream'))

    def test_nested_prompts_credentials_and_provider_envelopes_are_not_streamed(self):
        evidence = self.pipeline.result['stages'][-1]['data']['allergen_causing_ingredients']['Egg'][0]['evidence'][0]
        # A simulated malicious nested mapping record cannot bypass projection.
        evidence['mapping_evidence'].append({'system_prompt': 'PRIVATE_PROMPT', 'provider_response': 'PRIVATE_PROVIDER',
                                            'api_key': 'PRIVATE_KEY', 'path': '/private/internal/path',
                                            'note': 'Retained mapping evidence'})
        # Keep group evidence consistent, as the unchanged normalization contract requires.
        self.pipeline.result['stages'][-1]['data']['ingredients'][0]['evidence'][1] = deepcopy(evidence)
        response = self.scan()
        self.assertNotIn('PRIVATE_', response.text)
        self.assertNotIn('/private/internal/path', response.text)
        self.assertIn('Retained mapping evidence', response.text)


class DeliveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_progress_arrives_before_completion_and_disconnect_does_not_unlock_worker(self):
        pipeline = ProgressPipeline(); pipeline.block = True
        app = make_app(pipeline)
        request = httpx.Request('POST', 'http://test/scan/dish', headers={**AUTH, 'Accept': 'text/event-stream'},
                                files={'file': ('dish.png', b'synthetic')})
        body = request.read()
        scope = {'type': 'http', 'asgi': {'version': '3.0', 'spec_version': '2.3'}, 'http_version': '1.1',
                 'method': 'POST', 'scheme': 'http', 'path': '/scan/dish', 'raw_path': b'/scan/dish',
                 'query_string': b'', 'headers': [(k.lower(), v) for k, v in request.headers.raw], 'server': ('test', 80), 'client': ('local', 1)}
        disconnect = asyncio.Event(); delivered = asyncio.Queue(); sent = False
        async def receive():
            nonlocal sent
            if not sent:
                sent = True
                return {'type': 'http.request', 'body': body, 'more_body': False}
            await disconnect.wait()
            return {'type': 'http.disconnect'}
        async def send(message):
            if message['type'] == 'http.response.body' and message.get('body'):
                delivered.put_nowait(message['body'])
        with patch.object(user_allergen_service, 'fetch_user_allergens_from_db', return_value=['Egg']) as fetch:
            running = asyncio.create_task(app(scope, receive, send))
            try:
                self.assertTrue(await asyncio.to_thread(pipeline.entered.wait, 2))
                content = b''
                while b'identifying_ingredients' not in content:
                    content += await asyncio.wait_for(delivered.get(), 2)
                self.assertNotIn(b'outcome', content)
                fetch.assert_not_called()
                disconnect.set()
                await asyncio.wait_for(running, 2)
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
                    response = await client.post('/scan/dish', headers=AUTH, files={'file': ('x', b'new')})
                    self.assertEqual(response.status_code, 429)
                self.assertEqual(len(pipeline.paths), 1)
            finally:
                pipeline.release.set()
                for _ in range(100):
                    if fetch.called and not pipeline.paths[0].exists(): break
                    await asyncio.sleep(.01)
                if not running.done():
                    disconnect.set(); await running
            self.assertEqual(fetch.call_count, 1)
            self.assertFalse(pipeline.paths[0].exists())

if __name__ == '__main__': unittest.main()
