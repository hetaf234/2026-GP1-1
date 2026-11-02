"""Explicit APK upload or separately approved tester delivery using keyless ADC."""
import argparse
import json
import os
from pathlib import Path
import re
import time

from distribution_gate import check
from validate_data import ROOT, strict_json


def release_name(value, app_id):
    prefix = 'projects/237433634785/apps/' + app_id + '/releases/'
    if not value.startswith(prefix) or not re.fullmatch('[A-Za-z0-9_-]+', value[len(prefix):]):
        raise ValueError('The release must belong to the verified Firebase Android app.')
    return value


def execute(apk=None, release=None):
    policy = strict_json(ROOT / 'deployment/policy.json')
    check(policy, delivery=release is not None)
    from guard_reviewed_main import check as reviewed_main
    reviewed_main()
    import google.auth
    from google.auth.transport.requests import AuthorizedSession
    credentials, _ = google.auth.default(scopes=['https://www.googleapis.com/auth/cloud-platform'])
    session = AuthorizedSession(credentials)
    session.headers['x-goog-user-project'] = policy['firebase_project']
    host = 'https://firebaseappdistribution.googleapis.com'
    if release is not None:
        name = release_name(release, policy['firebase_app_id'])
        response = session.post(host + '/v1/' + name + ':distribute',
                                json={'groupAliases': [policy['test_group_alias']]}, timeout=60)
        response.raise_for_status()
        print('Approved release access assigned to the approved tester group.')
        return
    from check_apk import inspect
    inspect(apk)
    parent = 'projects/237433634785/apps/' + policy['firebase_app_id']
    with Path(apk).open('rb') as binary:
        response = session.post(host + '/upload/v1/' + parent + '/releases:upload', data=binary,
                                headers={'Content-Type': 'application/octet-stream',
                                         'X-Goog-Upload-Protocol': 'raw',
                                         'X-Goog-Upload-File-Name': Path(apk).name}, timeout=300)
    response.raise_for_status()
    operation = response.json()
    deadline = time.monotonic() + 300
    while not operation.get('done'):
        if time.monotonic() >= deadline:
            raise TimeoutError('App Distribution upload processing timed out; do not retry automatically.')
        operation_path = operation['name']
        if not re.fullmatch(re.escape(parent) + r'/releases/[^/]+/operations/[^/]+', operation_path):
            raise ValueError('Unexpected upload operation scope.')
        time.sleep(3)
        response = session.get(host + '/v1/' + operation_path, timeout=30)
        response.raise_for_status()
        operation = response.json()
    if operation.get('error'):
        raise RuntimeError('App Distribution upload failed; no tester delivery was attempted.')
    name = release_name(operation['response']['release']['name'], policy['firebase_app_id'])
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('release=' + name + '\n')
    # Do not log download tokens or automatically distribute/invite anyone.
    print(json.dumps({'uploaded_release': name, 'tester_delivery': False}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--apk', type=Path)
    group.add_argument('--release')
    args = parser.parse_args()
    execute(args.apk, args.release)
