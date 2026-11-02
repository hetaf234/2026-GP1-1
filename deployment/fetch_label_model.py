"""Download only inference assets from the public model; verify revision and hashes."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import ssl
import time
from urllib.request import Request, urlopen

import certifi

MODEL = "openfoodfacts/ingredient-detection"
FILES = ("config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json")
CONTEXT = ssl.create_default_context(cafile=certifi.where())


def open_url(url):
    return urlopen(Request(url, headers={"User-Agent": "Misbar-deployment-preparation/1.0"}), context=CONTEXT, timeout=90)


def model_source(revision):
    with open_url(f"https://huggingface.co/api/models/{MODEL}/revision/{revision}?blobs=true") as response:
        info = json.load(response)
    revision = info["sha"]
    if len(revision) != 40 or any(ch not in "0123456789abcdef" for ch in revision):
        raise ValueError("A fixed model commit is required.")
    siblings = {entry["rfilename"]: entry for entry in info["siblings"]}
    return {"model": MODEL, "revision": revision, "files": {name: siblings[name] for name in FILES}}


def identity(path, metadata):
    path = Path(path)
    if not path.is_file() or path.stat().st_size != metadata["size"]:
        return None
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    lfs = metadata.get("lfs")
    if lfs:
        expected = lfs.get("sha256") or lfs.get("oid")
        if expected != digest:
            return None
    else:
        blob = hashlib.sha1(b"blob " + str(path.stat().st_size).encode() + b"\0" + path.read_bytes()).hexdigest()
        if blob != metadata["blobId"]:
            return None
    return {"bytes": path.stat().st_size, "sha256": digest}


def parallel_weights(output, revision, name, metadata):
    """Resume fixed byte ranges; accept only exact 206 ranges and final SHA-256."""
    size, chunk = metadata["size"], 32 * 1024 * 1024
    expected = metadata["lfs"]["sha256"]
    parts = output / (".parts-" + expected)
    parts.mkdir(exist_ok=True)

    def fetch(index):
        start, end = index * chunk, min(size, (index + 1) * chunk) - 1
        destination = parts / f"{index:04d}"
        count = end - start + 1
        if destination.is_file() and destination.stat().st_size == count:
            return destination
        for attempt in range(3):
            partial = parts / f"{index:04d}.partial"
            try:
                url = f"https://huggingface.co/{MODEL}/resolve/{revision}/{name}?download=true&misbar_segment={index}"
                request = Request(url, headers={"User-Agent": "Misbar-download/1.0", "Range": f"bytes={start}-{end}"})
                with urlopen(request, context=CONTEXT, timeout=90) as response, partial.open("wb") as dest:
                    if response.status != 206 or response.headers.get("Content-Range") != f"bytes {start}-{end}/{size}":
                        raise ValueError("Server did not honor the exact model byte range.")
                    written = 0
                    while block := response.read(min(1024 * 1024, count - written + 1)):
                        written += len(block)
                        if written > count:
                            raise ValueError("Model segment exceeded its expected size.")
                        dest.write(block)
                if partial.stat().st_size != count:
                    raise ValueError("Model segment was incomplete.")
                partial.replace(destination)
                return destination
            except Exception:
                if attempt == 2:
                    raise RuntimeError("Model segment download failed: " + str(index)) from None
                time.sleep(2 ** attempt)

    segments = (size + chunk - 1) // chunk
    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = [pool.submit(fetch, index) for index in range(segments)]
        for completed, future in enumerate(as_completed(futures), 1):
            future.result()
            print(f"Verified model transfer segments: {completed}/{segments}", flush=True)
    assembled = output / (name + ".assembled")
    with assembled.open("wb") as dest:
        for index in range(segments):
            with (parts / f"{index:04d}").open("rb") as source:
                while block := source.read(1024 * 1024):
                    dest.write(block)
    if identity(assembled, metadata) is None:
        raise ValueError("Assembled model weights failed their source SHA-256 check.")
    assembled.replace(output / name)


def download(output, revision="main"):
    output = Path(output)
    receipt = output / "download_manifest.json"
    if receipt.is_file():
        revision = json.loads(receipt.read_bytes())["revision"]
    source = model_source(revision)
    revision, siblings = source["revision"], source["files"]
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"model": MODEL, "revision": revision, "files": {}}
    for name in FILES:
        metadata = siblings[name]
        target = output / name
        checked = identity(target, metadata)
        if checked is None:
            print("Downloading " + name + " (" + str(metadata["size"]) + " bytes)", flush=True)
            if metadata["size"] > 32 * 1024 * 1024:
                parallel_weights(output, revision, name, metadata)
            else:
                from huggingface_hub import hf_hub_download
                # Public download only; do not use a personal Hugging Face token.
                hf_hub_download(MODEL, name, revision=revision, local_dir=output, token=False, force_download=True)
            checked = identity(target, metadata)
            if checked is None:
                raise ValueError("Downloaded model identity mismatch: " + name)
        manifest["files"][name] = checked
    temp = output / "download_manifest.json.partial"
    temp.write_text(json.dumps(manifest, indent=2) + "\n")
    temp.replace(receipt)
    print(json.dumps(manifest, indent=2), flush=True)
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--revision", default="main")
    parser.add_argument("--metadata-only", action="store_true")
    args = parser.parse_args()
    if args.metadata_only:
        source = model_source(args.revision)
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / "source_manifest.json").write_text(json.dumps(source, indent=2) + "\n")
        print(json.dumps({"model": source["model"], "revision": source["revision"], "files": list(source["files"])}))
    else:
        download(args.output, args.revision)
