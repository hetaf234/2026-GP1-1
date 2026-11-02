"""Cross-check documentation, inactive templates and publication permissions."""
import json
from pathlib import Path
import re
import subprocess
import yaml

from validate_data import ROOT, strict_json


def validate():
    required = ['Purpose', 'Contents', 'Important Files', 'How It Works', 'When to Modify', 'Dependencies', 'Important Notes']
    folders = ['frontend', 'backend', 'data', 'deployment', 'docs', '.github', '.github/workflows', 'security_tests']
    for folder in folders:
        text = (ROOT / folder / 'README.md').read_text()
        if not all('## ' + title in text for title in required):
            raise ValueError('Incomplete folder documentation: ' + folder)
    pins = strict_json(ROOT / 'deployment/action-pins.json')
    workflows = ROOT / '.github/workflows'
    if list(workflows.glob('*.yml')) or list(workflows.glob('*.yaml')):
        raise ValueError('Preparation must not activate a workflow.')
    for path in workflows.glob('*.yml.disabled'):
        data = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
        if 'pull_request_target' in data['on']:
            raise ValueError('Untrusted privileged PR trigger.')
        for job in data['jobs'].values():
            permissions = job.get('permissions', data.get('permissions', {}))
            if permissions.get('contents') != 'read':
                raise ValueError('Workflow must not write repository contents.')
            for step in job.get('steps', []):
                if 'uses' in step:
                    action, digest = step['uses'].rsplit('@', 1)
                    if not re.fullmatch('[a-f0-9]{40}', digest) or digest != pins[action]['sha']:
                        raise ValueError('Action is not pinned to the reviewed commit.')
                if 'run' in step:
                    if re.search(r'git\s+(commit|push|merge|tag)\b|git\s+config\s+user\.', step['run']):
                        raise ValueError('Automated Git publication/identity change is prohibited.')
                    subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True,
                                   capture_output=True)
        if path.name != 'ci.yml.disabled':
            if data['on']['push']['branches'] != ['main']:
                raise ValueError('Only main can publish.')
            if any(p.startswith('docs') for p in data['on']['push']['paths']):
                raise ValueError('Documentation must not trigger publication.')
    policy = strict_json(ROOT / 'deployment/policy.json')
    for flag in ['allow_backend_deployment', 'allow_android_distribution', 'allow_tester_delivery', 'mobile_connectivity_verified']:
        if policy[flag] is not False:
            raise ValueError('Remote activation remains unapproved: ' + flag)
    return {'folder_readmes': len(folders), 'inactive_workflows': 3,
            'action_commit_pins': True, 'embedded_shell_syntax': True,
            'cloud_activation_flags': 'all disabled'}


if __name__ == '__main__':
    print(json.dumps(validate(), indent=2))
