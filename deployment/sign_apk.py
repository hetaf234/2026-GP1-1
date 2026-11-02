"""Sign a prebuilt artifact with the existing approved key, then verify identity."""
import argparse
import os
from pathlib import Path
import subprocess

from check_apk import build_tools, inspect


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--version', type=int, required=True)
    args = parser.parse_args()
    key = Path(os.environ['MISBAR_SIGNING_KEYSTORE']).resolve()
    temporary = Path(os.environ['RUNNER_TEMP']).resolve()
    if not key.is_relative_to(temporary):
        raise ValueError('Signing keys must only exist in protected runner temporary storage.')
    tool = build_tools() / 'apksigner'
    subprocess.run([str(tool), 'sign', '--ks', str(key), '--ks-key-alias', 'androiddebugkey',
                    '--ks-pass', 'env:MISBAR_SIGNING_PASSWORD', '--key-pass', 'env:MISBAR_SIGNING_PASSWORD',
                    '--out', str(args.output), str(args.apk)], check=True)
    print(inspect(args.output, args.version))
