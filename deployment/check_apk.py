"""Check package, version, and the approved signing certificate before upload."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

from validate_data import ROOT, strict_json


def build_tools():
    sdk = Path(os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME', ''))
    candidates = [p for p in (sdk / 'build-tools').glob('*') if (p / 'apksigner').is_file()]
    if not candidates:
        raise ValueError('Android build-tools are required.')
    return max(candidates, key=lambda p: tuple(int(x) for x in re.findall(r'\d+', p.name)))


def inspect(apk, expected_version=None):
    policy = strict_json(ROOT / 'deployment/policy.json')
    tools = build_tools()
    signed = subprocess.run([str(tools / 'apksigner'), 'verify', '--print-certs', str(apk)],
                            capture_output=True, text=True, check=True)
    found = re.findall(r'certificate SHA-256 digest: ([a-fA-F0-9]+)', signed.stdout)
    if found != [policy['android_certificate_sha256']]:
        raise ValueError('APK signing identity does not match the installed application.')
    result = subprocess.run([str(tools / 'aapt'), 'dump', 'badging', str(apk)],
                            capture_output=True, text=True, check=True)
    first = result.stdout.splitlines()[0]
    if f"name='{policy['android_package']}'" not in first:
        raise ValueError('APK package identity changed.')
    version = int(re.search(r"versionCode='(\d+)'", first).group(1))
    if expected_version is not None and version != expected_version:
        raise ValueError('APK version code does not match this approved run.')
    return {'package': policy['android_package'], 'certificate_sha256': found[0], 'version_code': version}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    parser.add_argument('--version', type=int)
    args = parser.parse_args()
    print(json.dumps(inspect(args.apk, args.version), indent=2))
