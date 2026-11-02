import copy
import os
import sys
import unittest
from unittest.mock import patch

from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from validate_data import ROOT, strict_json
from deploy_backend import validate_target
from distribution_gate import check
from guard_reviewed_main import check as reviewed
from firebase_distribution import release_name


class ReleaseGuards(unittest.TestCase):
    def setUp(self):
        self.policy = strict_json(ROOT / 'deployment/policy.json')
        self.image = self.policy['artifact_repository'] + '@sha256:' + 'a' * 64

    def test_default_policy_cannot_deploy_or_distribute(self):
        with self.assertRaises(ValueError):
            validate_target(self.policy, self.image, execute=True)
        with self.assertRaises(ValueError):
            check(self.policy)

    def test_stable_service_and_mutable_images_are_rejected(self):
        policy = copy.deepcopy(self.policy)
        policy['test_service'] = policy['stable_service']
        with self.assertRaises(ValueError):
            validate_target(policy, self.image)
        with self.assertRaises(ValueError):
            validate_target(self.policy, self.policy['artifact_repository'] + ':latest')

    def test_usb_url_or_direct_private_cloud_run_is_not_distribution_ready(self):
        policy = copy.deepcopy(self.policy)
        policy['allow_android_distribution'] = True
        policy['mobile_connectivity_verified'] = True
        with patch.dict(os.environ, MISBAR_ANDROID_UPLOAD_APPROVED='true'):
            for url in ['http://127.0.0.1:8080', 'https://test.run.app', 'https://user:pass@api.example.org']:
                policy['mobile_api_base_url'] = url
                with self.assertRaises(ValueError):
                    check(policy)

    def test_upload_approval_does_not_authorize_tester_delivery(self):
        policy = copy.deepcopy(self.policy)
        policy.update(allow_android_distribution=True, mobile_connectivity_verified=True,
                      mobile_api_base_url='https://api.example.org')
        with patch.dict(os.environ, MISBAR_ANDROID_UPLOAD_APPROVED='true'):
            check(policy)
            with self.assertRaises(ValueError):
                check(policy, delivery=True)

    def test_another_firebase_app_release_is_rejected(self):
        with self.assertRaises(ValueError):
            release_name('projects/other/apps/other/releases/test', self.policy['firebase_app_id'])

    def test_feature_push_and_public_repository_cannot_publish(self):
        environment = {'GITHUB_REPOSITORY': self.policy['repository'],
                       'GITHUB_REPOSITORY_ID': self.policy['repository_id'],
                       'GITHUB_REF': 'refs/heads/feature/test', 'GITHUB_EVENT_NAME': 'push'}
        with self.assertRaises(ValueError):
            reviewed(lambda path: self.fail('Feature branch must not call GitHub API'), environment)
        environment['GITHUB_REF'] = 'refs/heads/main'
        with self.assertRaises(ValueError):
            reviewed(lambda path: {'id': 1441817440, 'owner': {'id': 184541228}, 'private': False}, environment)

    def _review_fixture(self, reviews, pulls=True):
        environment = {'GITHUB_REPOSITORY': self.policy['repository'],
                       'GITHUB_REPOSITORY_ID': self.policy['repository_id'],
                       'GITHUB_REF': 'refs/heads/main', 'GITHUB_EVENT_NAME': 'push',
                       'GITHUB_SHA': 'a' * 40}
        pull = {'number': 1, 'merged_at': 'approved-fixture', 'merge_commit_sha': 'a' * 40,
                'base': {'ref': 'main'}, 'head': {'repo': {'id': 1441817440}, 'sha': 'b' * 40},
                'user': {'id': 1}}
        def get(path):
            if '/branches/' in path:
                return {'protected': True}
            if '/commits/' in path:
                return [pull] if pulls else []
            if '/reviews?' in path:
                return reviews
            return {'id': 1441817440, 'owner': {'id': 184541228}, 'private': True}
        return environment, get

    def test_current_head_approved_merge_is_accepted(self):
        env, get = self._review_fixture([{'state': 'APPROVED', 'commit_id': 'b' * 40, 'user': {'id': 2}}])
        self.assertEqual(reviewed(get, env)['reviewed_pull_request'], 1)

    def test_unreviewed_direct_main_push_is_rejected(self):
        env, get = self._review_fixture([], pulls=False)
        with self.assertRaises(ValueError):
            reviewed(get, env)

    def test_stale_self_or_superseded_approval_is_rejected(self):
        for reviews in [[{'state': 'APPROVED', 'commit_id': 'c' * 40, 'user': {'id': 2}}],
                        [{'state': 'APPROVED', 'commit_id': 'b' * 40, 'user': {'id': 1}}],
                        [{'state': 'APPROVED', 'commit_id': 'b' * 40, 'user': {'id': 2}},
                         {'state': 'CHANGES_REQUESTED', 'commit_id': 'b' * 40, 'user': {'id': 2}}]]:
            env, get = self._review_fixture(reviews)
            with self.assertRaises(ValueError):
                reviewed(get, env)
