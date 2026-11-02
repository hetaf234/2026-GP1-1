"""Materialize an overlay for the immutable approved private model image."""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import shutil

from validate_data import ROOT, strict_json, validate


def prepare(output, root=ROOT):
    root, output = Path(root).resolve(), Path(output).resolve()
    if not output.is_relative_to(root / '.local'):
        raise ValueError('Build output must stay in this checkout .local directory.')
    validate(root)
    policy = strict_json(root / 'deployment/policy.json')
    base = policy['approved_base_image']
    prefix = 'us-central1-docker.pkg.dev/project-51f11627-cb56-4c1e-978/misbar-models/api@sha256:'
    if not base.startswith(prefix) or not re.fullmatch('[a-f0-9]{64}', base[len(prefix):]):
        raise ValueError('The approved private model image must be digest-pinned.')
    manifest = strict_json(root / 'deployment/approved-runtime.json')
    mapping = strict_json(root / 'deployment/source-map.json')
    protected = ('dish/nonlinear/', 'dish/scripts/', 'dish/manual_testing/',
                 'dish/configs/', 'dish/src/dish_identifier/assets/',
                 'dish/src/dish_identifier/frozen_runtime.py',
                 'dish/src/dish_identifier/human_labels.py')
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    for runtime, source in mapping.items():
        target = (output / runtime).resolve()
        path = (root / source).resolve()
        if not target.is_relative_to(output) or not path.is_relative_to(root):
            raise ValueError('Runtime paths cannot escape the repository.')
        if path.suffix in {'.pt', '.safetensors', '.pkl', '.keystore', '.jks'}:
            raise ValueError('Weights and signing keys must not enter Git build input.')
        raw = path.read_bytes()
        entry = {'sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw)}
        if runtime.startswith(protected) and entry != manifest['files'][runtime]:
            raise ValueError('Frozen model configuration requires separate approval: ' + runtime)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
        manifest['files'][runtime] = entry
    content = (json.dumps(manifest, indent=2) + '\n').encode()
    (output / 'bundle_manifest.json').write_bytes(content)
    digest = hashlib.sha256(content).hexdigest()
    (output / 'Dockerfile').write_text(
        f'FROM {base}\n'
        'COPY labels/ /opt/misbar/labels/\n'
        'COPY dish/ /opt/misbar/dish/\n'
        'COPY deployment/ /opt/misbar/deployment/\n'
        'COPY bundle_manifest.json /opt/misbar/bundle_manifest.json\n'
        'RUN python -B -m deployment.verify_bundle\n'
        f'LABEL misbar.bundle.manifest.sha256="{digest}"\n')
    return {'output': str(output), 'base': base, 'manifest_sha256': digest,
            'source_files': len(mapping)}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / '.local/runtime-context')
    args = parser.parse_args()
    print(json.dumps(prepare(args.output), indent=2))
