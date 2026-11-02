"""Submit a build only after explicit activation; never provision resources."""
import argparse
import json
import os
import re
import subprocess
import time

from validate_data import ROOT, strict_json


def main():
    policy = strict_json(ROOT / 'deployment/policy.json')
    if not policy['allow_backend_deployment'] or os.environ.get('MISBAR_BACKEND_DEPLOY_APPROVED') != 'true':
        raise ValueError('Cloud build submission is not approved.')
    from guard_reviewed_main import check
    check()
    sha = os.environ['GITHUB_SHA']
    if not re.fullmatch('[a-f0-9]{40}', sha):
        raise ValueError('An immutable source commit is required.')
    bucket = os.environ['MISBAR_BUILD_SOURCE_BUCKET']
    account = os.environ['MISBAR_CLOUD_BUILD_ACCOUNT']
    if not re.fullmatch('[a-z0-9][a-z0-9._-]{2,221}', bucket):
        raise ValueError('Configure an approved existing source bucket.')
    if not re.fullmatch(r'[a-z][a-z0-9-]{4,28}[a-z0-9]@' + re.escape(policy['project']) + r'\.iam\.gserviceaccount\.com', account):
        raise ValueError('Configure the dedicated hosting-project build identity.')
    # Describe must succeed. Never create a staging bucket implicitly.
    subprocess.run(['gcloud', 'storage', 'buckets', 'describe', 'gs://' + bucket,
                    '--project=' + policy['project'], '--format=value(name)'], check=True,
                   stdout=subprocess.DEVNULL)
    number = os.environ['GITHUB_RUN_NUMBER']
    if not number.isdigit():
        raise ValueError('Invalid workflow run number.')
    tag = 'github-' + sha + '-' + number
    args = ['gcloud', 'builds', 'submit', str(ROOT), '--config=deployment/cloudbuild.build-only.yaml',
            '--project=' + policy['project'], '--region=' + policy['region'],
            '--service-account=projects/' + policy['project'] + '/serviceAccounts/' + account,
            '--gcs-source-staging-dir=gs://' + bucket + '/source', '--substitutions=_IMAGE_TAG=' + tag,
            '--format=json', '--quiet', '--async']
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('Cloud Build failed; no deployment is permitted.')
    build = json.loads(result.stdout)
    deadline = time.monotonic() + 2100
    while build['status'] in {'STATUS_UNKNOWN', 'PENDING', 'QUEUED', 'WORKING'}:
        if time.monotonic() >= deadline:
            raise TimeoutError('Cloud Build polling timed out; do not submit a duplicate build.')
        time.sleep(5)
        result = subprocess.run(['gcloud', 'builds', 'describe', build['id'],
                                 '--project=' + policy['project'], '--region=' + policy['region'],
                                 '--format=json'], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('Cloud Build status could not be verified; deployment is blocked.')
        build = json.loads(result.stdout)
    if build['status'] != 'SUCCESS':
        raise RuntimeError('Cloud Build did not finish successfully.')
    images = build.get('results', {}).get('images', [])
    expected = policy['artifact_repository'] + ':' + tag
    matches = [i for i in images if i['name'] == expected and re.fullmatch('sha256:[a-f0-9]{64}', i['digest'])]
    if len(matches) != 1:
        raise ValueError('The tested image digest could not be verified.')
    image = policy['artifact_repository'] + '@' + matches[0]['digest']
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('image=' + image + '\n')
    print(json.dumps({'build': build['id'], 'tested_image': image}))


if __name__ == '__main__':
    main()
