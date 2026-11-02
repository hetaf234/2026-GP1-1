"""Existing test service image update only. Disabled until separate approval."""
import argparse
import copy
import json
import os
from pathlib import Path
import re
import subprocess

from validate_data import ROOT, strict_json


def command(*args):
    result = subprocess.run(['gcloud', *args, '--format=json'], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('Google Cloud command failed; inspect protected runner logs.')
    return json.loads(result.stdout)


def validate_target(policy, image, execute=False):
    if policy['project'] != 'project-51f11627-cb56-4c1e-978' or policy['region'] != 'us-central1':
        raise ValueError('Unapproved hosting target.')
    if policy['test_service'] != 'misbar-consolidated-test-20261101':
        raise ValueError('Only the existing testing service is permitted.')
    prefix = policy['artifact_repository'] + '@sha256:'
    if not image.startswith(prefix) or not re.fullmatch('[a-f0-9]{64}', image[len(prefix):]):
        raise ValueError('Only a digest-pinned image in the approved private repository is permitted.')
    if execute and (not policy['allow_backend_deployment'] or os.environ.get('MISBAR_BACKEND_DEPLOY_APPROVED') != 'true'):
        raise ValueError('Backend activation has not been explicitly approved.')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', required=True)
    parser.add_argument('--execute', action='store_true')
    args = parser.parse_args()
    policy = strict_json(ROOT / 'deployment/policy.json')
    validate_target(policy, args.image, args.execute)
    if not args.execute:
        print(json.dumps({'plan_only': True, 'service': policy['test_service'], 'image': args.image}))
        return
    from guard_reviewed_main import check
    check()
    common = ['--project=' + policy['project'], '--region=' + policy['region']]
    name = policy['test_service']
    before = command('run', 'services', 'describe', name, *common)
    iam_before = command('run', 'services', 'get-iam-policy', name, *common)
    template = before['spec']['template']
    spec = template['spec']
    if (spec['containers'][0]['resources']['limits'] != {'cpu': '4', 'memory': '8Gi'} or
            spec['containerConcurrency'] != 1 or spec['timeoutSeconds'] != 600 or
            template['metadata']['annotations'].get('autoscaling.knative.dev/maxScale') != '1' or
            template['metadata']['annotations'].get('autoscaling.knative.dev/minScale') != '0' or
            spec['containers'][0]['startupProbe']['httpGet']['path'] != '/ready'):
        raise ValueError('Testing service resource contract has drifted.')
    if before['metadata'].get('annotations', {}).get('run.googleapis.com/invoker-iam-disabled') == 'true':
        raise ValueError('IAM invocation checking must stay enabled.')
    if any(member in {'allUsers', 'allAuthenticatedUsers'} for binding in iam_before.get('bindings', []) for member in binding.get('members', [])):
        raise ValueError('Testing service must remain private.')
    folder = ROOT / '.local/deployment-receipt'
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    (folder / 'before.json').write_text(json.dumps(before))
    previous = before['status']['latestReadyRevisionName']
    # Update only image. Never create a service, set IAM, or change secret bindings.
    command('run', 'services', 'update', name, '--image=' + args.image, '--quiet', *common)
    after = command('run', 'services', 'describe', name, *common)
    iam_after = command('run', 'services', 'get-iam-policy', name, *common)
    old_spec, new_spec = copy.deepcopy(spec), copy.deepcopy(after['spec']['template']['spec'])
    old_spec['containers'][0].pop('image')
    actual_image = new_spec['containers'][0].pop('image')
    if actual_image != args.image or old_spec != new_spec or iam_before != iam_after:
        raise RuntimeError('Post-deployment configuration check failed; stop and review.')
    new_annotations = after['spec']['template']['metadata']['annotations']
    client_metadata = {'run.googleapis.com/client-name', 'run.googleapis.com/client-version'}
    if any(new_annotations.get(k) != v for k, v in template['metadata']['annotations'].items()
           if k not in client_metadata):
        raise RuntimeError('Post-deployment annotations changed; stop and review.')
    if not any(c['type'] == 'Ready' and c['status'] == 'True' for c in after['status']['conditions']):
        raise RuntimeError('The /ready startup probe has not established readiness.')
    command('run', 'revisions', 'describe', previous, *common)
    rollback = f'gcloud run services update-traffic {name} --to-revisions={previous}=100 ' + ' '.join(common)
    (folder / 'rollback.txt').write_text(rollback + '\n')
    (folder / 'after.json').write_text(json.dumps(after))
    print(json.dumps({'service': name, 'revision': after['status']['latestReadyRevisionName'],
                      'previous_revision_available': previous, 'startup_readiness': True}))


if __name__ == '__main__':
    main()
