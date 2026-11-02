import json
from pathlib import Path
import tempfile
import unittest

from deployment.gateway import seed_quality_environment


class SecretConfigurationTests(unittest.TestCase):
    def test_one_sightengine_file_supplies_both_model_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "quality.json"
            path.write_text(json.dumps({"api_user": "test-user", "api_secret": "test-secret"}))
            before = path.read_bytes()
            environment = {}
            seed_quality_environment(path, environment)
            self.assertEqual(environment, {"SIGHTENGINE_API_USER": "test-user", "SIGHTENGINE_API_SECRET": "test-secret"})
            self.assertEqual(path.read_bytes(), before)

    def test_private_process_environment_takes_precedence(self):
        environment = {"SIGHTENGINE_API_USER": "already-set", "SIGHTENGINE_API_SECRET": "already-set"}
        seed_quality_environment(Path("/missing/not-used.json"), environment)
        self.assertEqual(environment["SIGHTENGINE_API_USER"], "already-set")

    def test_invalid_configuration_does_not_publish_partial_values(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "quality.json"
            path.write_text(json.dumps({"api_user": "test-user", "api_secret": ""}))
            environment = {}
            with self.assertRaisesRegex(RuntimeError, "configuration is unavailable"):
                seed_quality_environment(path, environment)
            self.assertEqual(environment, {})


if __name__ == "__main__":
    unittest.main()
