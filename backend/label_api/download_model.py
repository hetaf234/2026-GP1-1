import os
import sys
import time
import hashlib
import urllib.request
import urllib.error

REPO_ID = "openfoodfacts/ingredient-detection"
BASE_URL = f"https://huggingface.co/{REPO_ID}/resolve/main"

# Core files for the Hugging Face model
FILES = [
    {
        "filename": "config.json",
        "size": 854,
        "sha256": "4b5daeda643d147fd578f1f9ae7d2ae2a2f6a8005132fc40edc3c55dc006c9d9"
    },
    {
        "filename": "model.safetensors",
        "size": 2235424156,
        "sha256": "ca586acd223448c0aff78372639cd6203466e753c5becfda2df38bd98f18e378"
    },
    {
        "filename": "tokenizer.json",
        "size": 17082835,
        "sha256": "70dc686438b64aca1ee6b60d1aed7f7cc93a432c73ec891b31d09a4758ee695d"
    },
    {
        "filename": "tokenizer_config.json",
        "size": 1147,
        "sha256": "f90024142df07163e5e6c5b9a6ad7c8c68b22a9112af11e3db4559a9ff90f737"
    },
    {
        "filename": "special_tokens_map.json",
        "size": 280,
        "sha256": "06e405a36dfe4b9604f484f6a1e619af1a7f7d09e34a8555eb0b77b66318067f"
    },
    {
        "filename": "training_args.bin",
        "size": 5048,
        "sha256": "bb6b754d4831d03ef3b36a2ef36050f7c369bb72e6eeb8220e3a7224e5926f28"
    },
    {
        "filename": "README.md",
        "size": 1278,
        "sha256": None
    },
    {
        "filename": ".gitattributes",
        "size": 1619,
        "sha256": None
    },
    {
        "filename": "onnx.tar.gz",
        "size": 1832390840,
        "sha256": "4adbca6b2e4e21d2c1ea77e3bc73125ae3bf6e98825550528e68dbc386a645bd"
    }
]

def format_size(bytes_num):
    for unit in ['B', 'KB', 'MB', 'GB']:
        if bytes_num < 1024.0:
            return f"{bytes_num:.2f} {unit}"
        bytes_num /= 1024.0
    return f"{bytes_num:.2f} TB"

def download_file(url, target_path, expected_size=None, expected_sha256=None):
    os.makedirs(os.path.dirname(os.path.abspath(target_path)), exist_ok=True)
    temp_path = target_path + ".part"

    # Check if already complete and matches sha256
    if os.path.exists(target_path):
        current_size = os.path.getsize(target_path)
        if expected_size is None or current_size == expected_size:
            if expected_sha256:
                print(f"Checking existing {os.path.basename(target_path)}...")
                hasher = hashlib.sha256()
                with open(target_path, 'rb') as f:
                    while chunk := f.read(4 * 1024 * 1024):
                        hasher.update(chunk)
                if hasher.hexdigest() == expected_sha256:
                    print(f"✓ {os.path.basename(target_path)} already exists and verified.")
                    return True
                else:
                    print(f"Checksum mismatch for {os.path.basename(target_path)}, redownloading...")
            else:
                print(f"✓ {os.path.basename(target_path)} already exists.")
                return True

    # Resuming support
    initial_bytes = 0
    if os.path.exists(temp_path):
        initial_bytes = os.path.getsize(temp_path)
        print(f"Resuming {os.path.basename(target_path)} from {format_size(initial_bytes)}...")

    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) OpenFoodFacts-Downloader/1.0"
        }
    )
    if initial_bytes > 0:
        req.add_header("Range", f"bytes={initial_bytes}-")

    max_retries = 5
    for attempt in range(max_retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                # Handle status codes: 206 Partial Content or 200 OK
                mode = 'ab' if initial_bytes > 0 and response.status == 206 else 'wb'
                if mode == 'wb':
                    initial_bytes = 0

                total_size = response.length
                if total_size is not None:
                    total_size += initial_bytes
                elif expected_size is not None:
                    total_size = expected_size

                downloaded = initial_bytes
                last_log_time = time.time()
                bytes_since_log = 0
                start_time = time.time()

                with open(temp_path, mode) as f:
                    chunk_size = 2 * 1024 * 1024 # 2MB chunks
                    while True:
                        chunk = response.read(chunk_size)
                        if not chunk:
                            break
                        f.write(chunk)
                        downloaded += len(chunk)
                        bytes_since_log += len(chunk)

                        curr_time = time.time()
                        if curr_time - last_log_time >= 2.0: # Print every 2 seconds
                            elapsed = curr_time - last_log_time
                            speed = bytes_since_log / elapsed
                            pct = (downloaded / total_size * 100) if total_size else 0
                            print(f"  [{os.path.basename(target_path)}] {pct:.1f}% ({format_size(downloaded)} / {format_size(total_size) if total_size else '?'}) at {format_size(speed)}/s")
                            last_log_time = curr_time
                            bytes_since_log = 0

            # Verify checksum if provided
            if expected_sha256:
                print(f"Verifying SHA-256 for {os.path.basename(target_path)}...")
                hasher = hashlib.sha256()
                with open(temp_path, 'rb') as f:
                    while chunk := f.read(4 * 1024 * 1024):
                        hasher.update(chunk)
                file_hash = hasher.hexdigest()
                if file_hash != expected_sha256:
                    print(f"Hash mismatch: expected {expected_sha256}, got {file_hash}")
                    if os.path.exists(temp_path):
                        os.remove(temp_path)
                    raise ValueError(f"Checksum verification failed for {target_path}")

            os.replace(temp_path, target_path)
            print(f"✓ Completed {os.path.basename(target_path)} ({format_size(os.path.getsize(target_path))})")
            return True

        except (urllib.error.URLError, TimeoutError, ConnectionError, ValueError) as e:
            print(f"Download attempt {attempt + 1}/{max_retries} failed; private details suppressed.")
            if attempt + 1 == max_retries:
                raise RuntimeError("Model download failed; private details suppressed.") from None
            time.sleep(3)

def main():
    dest_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "ingredient-detection"))
    print(f"Downloading Open Food Facts Ingredient Detection Model into: {dest_dir}\n")

    for file_info in FILES:
        filename = file_info["filename"]
        url = f"{BASE_URL}/{filename}"
        target_path = os.path.join(dest_dir, filename)
        print(f"Downloading {filename}...")
        download_file(
            url=url,
            target_path=target_path,
            expected_size=file_info["size"],
            expected_sha256=file_info["sha256"]
        )

    print("\nExtracting onnx.tar.gz...")
    tar_path = os.path.join(dest_dir, "onnx.tar.gz")
    if os.path.exists(tar_path):
        import tarfile
        with tarfile.open(tar_path, "r:gz") as tar:
            tar.extractall(path=dest_dir)
        print("✓ Extracted ONNX files to ingredient-detection/onnx")

    print("\nAll files downloaded and verified successfully!")

if __name__ == "__main__":
    main()
