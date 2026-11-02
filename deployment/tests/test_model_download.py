import hashlib
from pathlib import Path
import tempfile
import unittest

from deployment.fetch_label_model import identity


class DownloadIdentityTests(unittest.TestCase):
    def test_truncated_weights_are_rejected_before_use(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "model.safetensors"
            path.write_bytes(b"partial")
            metadata = {"size": 1000, "lfs": {"sha256": "a" * 64}}
            self.assertIsNone(identity(path, metadata))

    def test_correct_length_with_changed_bytes_is_also_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "model.safetensors"
            path.write_bytes(b"wrong")
            metadata = {"size": 5, "lfs": {"sha256": hashlib.sha256(b"right").hexdigest()}}
            self.assertIsNone(identity(path, metadata))

    def test_verified_weights_and_git_objects_retain_exact_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "config.json"
            data = b'{}'
            path.write_bytes(data)
            digest = hashlib.sha256(data).hexdigest()
            self.assertEqual(identity(path, {"size": 2, "lfs": {"sha256": digest}})["sha256"], digest)
            blob = hashlib.sha1(b"blob 2\0" + data).hexdigest()
            self.assertEqual(identity(path, {"size": 2, "blobId": blob})["sha256"], digest)


if __name__ == "__main__":
    unittest.main()
