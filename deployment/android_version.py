import os
from validate_data import ROOT, strict_json

if __name__ == '__main__':
    policy = strict_json(ROOT / 'deployment/policy.json')
    version = int(policy['android_version_base']) + int(os.environ['GITHUB_RUN_NUMBER'])
    if not 1 < version < 2100000000:
        raise ValueError('Android version code is out of range.')
    print(version)
