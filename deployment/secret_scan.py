"""Scan publication candidates; never print a matched value."""
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SKIP = {'.git', '.local', '.dart_tool', '.gradle', 'node_modules', 'build', '__pycache__'}
PATTERNS = {
    'private_key': rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'service_account': rb'"type"\s*:\s*"service_account"',
    'anthropic_key': rb'sk-ant-[A-Za-z0-9_-]{20,}',
    'github_token': rb'(?:ghp_|github_pat_)[A-Za-z0-9_]{30,}',
    'aws_access_key': rb'AKIA[0-9A-Z]{16}',
    'google_api_key': rb'AIza[0-9A-Za-z_-]{30,}',
}
CLIENT_CONFIGS = {'frontend/lib/firebase_options.dart', 'frontend/android/app/google-services.json',
                  'frontend/android/app/src/misbar2/google-services.json'}


def scan(root=ROOT):
    root = Path(root)
    findings, public_configs = [], []
    if (root / '.git').is_dir():
        result = subprocess.run(['git', '-C', str(root), 'ls-files', '--cached', '--others',
                                 '--exclude-standard', '-z'], capture_output=True, check=True)
        paths = [root / item.decode() for item in result.stdout.split(b'\0') if item]
    else:
        paths = root.rglob('*')
    for path in paths:
        rel = path.relative_to(root)
        if not path.is_file() or any(part in SKIP for part in rel.parts):
            continue
        name = rel.as_posix()
        if path.suffix.lower() in {'.pt', '.pkl', '.safetensors', '.keystore', '.jks', '.apk', '.aab', '.tar', '.gz', '.log'} or path.name == 'local.properties':
            findings.append({'file': name, 'reason': 'excluded_artifact'})
        if path.name.startswith('.env') and not path.name.endswith('.example'):
            findings.append({'file': name, 'reason': 'environment_file'})
        if path.stat().st_size > 5_000_000:
            findings.append({'file': name, 'reason': 'large_file_requires_review'})
        raw = path.read_bytes()
        for kind, pattern in PATTERNS.items():
            if re.search(pattern, raw):
                if kind == 'google_api_key' and name in CLIENT_CONFIGS:
                    public_configs.append(name)
                else:
                    findings.append({'file': name, 'reason': kind})
    return {'findings': findings, 'allowed_public_firebase_configs': sorted(set(public_configs)),
            'matched_values_logged': False}


if __name__ == '__main__':
    result = scan()
    print(json.dumps(result, indent=2))
    raise SystemExit(bool(result['findings']))
