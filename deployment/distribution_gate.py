"""APK upload/delivery remains blocked until its separate approvals exist."""
import argparse
import os
from urllib.parse import urlsplit

from validate_data import ROOT, strict_json


def check(policy, delivery=False):
    if not policy['allow_android_distribution'] or os.environ.get('MISBAR_ANDROID_UPLOAD_APPROVED') != 'true':
        raise ValueError('APK upload activation has not been approved.')
    url = urlsplit(policy.get('mobile_api_base_url') or '')
    if (not policy.get('mobile_connectivity_verified') or url.scheme != 'https' or
            not url.hostname or url.hostname in {'localhost', '127.0.0.1', '10.0.2.2'} or
            url.hostname.endswith('.run.app') or url.username or url.password or url.query or url.fragment):
        raise ValueError('USB-free Firebase-authenticated connectivity is not verified.')
    if delivery and (not policy.get('allow_tester_delivery') or os.environ.get('MISBAR_TESTER_DELIVERY_APPROVED') != 'true'):
        raise ValueError('Tester release access/invitations require separate approval.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--delivery', action='store_true')
    args = parser.parse_args()
    check(strict_json(ROOT / 'deployment/policy.json'), args.delivery)
    print('Approved distribution prerequisites verified.')
