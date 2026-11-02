"""Compute trusted path filters without evaluating branch names as shell code."""
import json
import os
import re
import subprocess


if __name__ == '__main__':
    with open(os.environ['GITHUB_EVENT_PATH']) as source:
        event = json.load(source)
    before = event.get('pull_request', {}).get('base', {}).get('sha') or event.get('before', '')
    if before and re.fullmatch('[a-f0-9]{40}', before) and before != '0' * 40:
        command = ['git', 'diff', '--name-only', before, 'HEAD']
    else:
        command = ['git', 'ls-files']
    paths = subprocess.run(command, capture_output=True, text=True, check=True).stdout.splitlines()
    backend = any(p.startswith(('backend/', 'data/', 'deployment/', 'security_tests/')) or
                  p in {'firestore.rules', 'firebase.json', 'frontend/lib/models/scan_result.dart',
                        'frontend/test/support/label_backend_stream.sse'} for p in paths)
    frontend = any(p.startswith('frontend/') for p in paths)
    if any(p.startswith('.github/workflows/') for p in paths):
        backend = frontend = True
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('backend=' + str(backend).lower() + '\n')
        output.write('frontend=' + str(frontend).lower() + '\n')
