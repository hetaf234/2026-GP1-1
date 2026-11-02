"""Fetch public weights at image-build time, never while serving a user request."""
import json
from pathlib import Path

from deployment.fetch_label_model import FILES, MODEL, download, identity


def materialize(folder):
    folder = Path(folder)
    source = json.loads((folder / "source_manifest.json").read_bytes())
    if source["model"] != MODEL or set(source["files"]) != set(FILES):
        raise ValueError("Unexpected public model source.")
    if not all(identity(folder / name, source["files"][name]) for name in FILES):
        downloaded = download(folder, source["revision"])
        if downloaded["revision"] != source["revision"]:
            raise ValueError("Public model revision changed.")
    if not all(identity(folder / name, source["files"][name]) for name in FILES):
        raise ValueError("Image-build model identity differs from the approved source.")


if __name__ == "__main__":
    materialize("/opt/misbar/labels/ingredient-detection")
