"""Credential-free unit/contract checks. External network is denied."""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'backend/label_api'), str(ROOT), str(ROOT / 'deployment')]
from validate_data import validate


def run():
    os.chdir(ROOT)
    output = ROOT / '.local/test-results'
    output.mkdir(parents=True, exist_ok=True)
    stream = io.StringIO()
    results = []
    with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream), contextlib.ExitStack() as guard:
        for target in ('socket.socket.connect', 'socket.socket.connect_ex', 'socket.create_connection'):
            guard.enter_context(patch(target, side_effect=AssertionError('External network prohibited in tests')))
        data = validate()
        for name, folder in [('backend', ROOT / 'backend/label_api'), ('deployment', ROOT / 'deployment/tests')]:
            suite = unittest.TestLoader().discover(str(folder), pattern='test_*.py', top_level_dir=str(folder))
            result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
            results.append({'group': name, 'tests': result.testsRun, 'failures': len(result.failures),
                            'errors': len(result.errors), 'skipped': len(result.skipped)})
    report = {'groups': results, 'data': data, 'external_network_blocked': True}
    (output / 'backend.log').write_text(stream.getvalue())
    (output / 'backend.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    return int(any(item['failures'] or item['errors'] for item in results))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--backend', action='store_true', help='Run backend and deployment contract checks.')
    parser.parse_args()
    raise SystemExit(run())
