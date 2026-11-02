r"""Run from Server: .\.venv\Scripts\python.exe check_quality.py "C:\path\image.png"""  # noqa

import argparse
import json
from pathlib import Path

from app.log_safety import install_safe_logging

install_safe_logging()

from app.services.quality_service import check_image_quality, QualityServiceError


def main():
    parser = argparse.ArgumentParser(description="Check image quality before OCR.")
    parser.add_argument("image", help="Full image path, or a path relative to the current folder")
    args = parser.parse_args()
    image_path = Path(args.image).expanduser()
    if not image_path.is_file():
        print("Image file not found. Check the supplied path.")
        print("Use Copy as path on the image and pass that full path in quotes.")
        return 1
    try:
        result = check_image_quality(image_path.read_bytes())
    except (QualityServiceError, OSError) as error:
        print("Quality check failed. Check the image and server configuration.")
        return 1
    print(json.dumps(result, indent=2))
    print("ACCEPTED: image passed the quality check." if result["accepted"]
          else "REJECTED: please retake the image.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
