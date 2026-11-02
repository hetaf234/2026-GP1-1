"""Choose local photos and inspect the frozen Nonlinear Fusion output."""
from __future__ import annotations

import argparse
import base64
from datetime import datetime
import hashlib
import html
import importlib.util
import io
import json
from pathlib import Path
import webbrowser
import sys
import tempfile
import traceback
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
FREEZE = ROOT / "nonlinear"
# The original scorer is byte-identical to freeze v20261010_01. Only the two
# original-classifier location strings in the deployment config are portable.
SCORER_SHA = "28db1abf30719e505cc4abb75471a9b84c9e62fca785384bd62298a124099266"
CONFIG_SHA = "f2ab3cdbb44e29112e5ce11900eff2bce070461719eb66f3189fb80ca5706f5c"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load_detector(checkpoint=None):
    config_path = FREEZE / "FINAL_NONLINEAR_FUSION/config.json"
    scorer_path = FREEZE / "implementation/detector.py"
    for path, expected in ((config_path, CONFIG_SHA), (scorer_path, SCORER_SHA)):
        if digest(path) != expected:
            raise RuntimeError(f"Frozen runtime file has changed: {path.name}")
    spec = importlib.util.spec_from_file_location("manual_frozen_detector", scorer_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    detector = module.FrozenDetector(config_path.parent)
    if (detector.config["candidate"] != "FINAL_NONLINEAR_FUSION"
            or detector.config["kind"] != "NONLINEAR"
            or detector.threshold != 0.18922570362206778):
        raise RuntimeError("Unexpected frozen Nonlinear detector or threshold")
    # Resolve file locations in memory only. All original hash, mapping,
    # preprocessing and strict checkpoint checks remain in the frozen loader.
    reference = detector.config["original_classifier"]
    location = Path(checkpoint).expanduser() if checkpoint is not None else ROOT / reference["checkpoint"]
    if not location.is_file():
        raise FileNotFoundError(
            "DINOv2 checkpoint is missing. Download the original best_checkpoint.pt "
            "from the team's existing OneDrive share, place it in "
            "Dish-Recognition/models/, or pass --checkpoint /path/to/best_checkpoint.pt."
        )
    reference["checkpoint"] = str(location.resolve())
    reference["loader"] = str((ROOT / reference["loader"]).resolve())
    return detector


def choose_images():
    import tkinter as tk
    from tkinter import filedialog
    root = tk.Tk()
    root.withdraw()
    root.attributes("-topmost", True)
    try:
        return [Path(p) for p in filedialog.askopenfilenames(
            parent=root, title="Test Nonlinear Fusion — choose one or more photos",
            filetypes=[("Images", "*.jpg *.jpeg *.png *.webp *.bmp *.tif *.tiff *.gif"), ("All files", "*")],
        )]
    finally:
        root.destroy()


def predict_image(detector, image):
    """Use one DINOv2 forward pass for both the top three and frozen decision."""
    import numpy as np
    import torch

    model = detector.load_original()
    with torch.inference_mode():
        tensor = detector.transform(image.convert("RGB")).unsqueeze(0)
        logits, embeddings = model.forward_with_embedding(tensor)
    logits = logits.numpy()
    output = detector.score_embeddings(embeddings.numpy(), logits)
    # Normalize across all 121 dishes, using the frozen scorer's float64 math.
    values = logits[0].astype(np.float64)
    probabilities = np.exp(values - values.max())
    probabilities /= probabilities.sum()
    indices = np.argsort(-probabilities, kind="stable")[:3]
    top3 = [
        {"rank": rank, "dish": detector.classes[int(index)],
         "confidence": float(probabilities[index])}
        for rank, index in enumerate(indices, 1)
    ]
    return output, top3


def run_images(detector, paths):
    from PIL import Image
    results = []
    for index, path in enumerate(paths, 1):
        print(f"[{index}/{len(paths)}] {path.name}", flush=True)
        row = {"file": str(path.resolve()), "filename": path.name}
        try:
            # Keep the exact frozen RGB/resize/crop preprocessing. GIF uses its first frame.
            with Image.open(path) as source:
                image = source.convert("RGB")
            output, top3 = predict_image(detector, image)
            accepted = bool(output["accepted"][0])
            row.update(
                decision="accepted" if accepted else "rejected",
                final_label=str(output["original_predicted_classes"][0]) if accepted else None,
                message="Dish prediction accepted" if accepted else "Possibly unsupported dish — prediction withheld",
                original_dish_guess=str(output["original_predicted_classes"][0]),
                original_classifier_confidence=float(output["original_confidence"][0]),
                dinov2_top3=top3,
                nonlinear_score=float(output["score"][0]),
                threshold=detector.threshold,
                LR_score=float(output["LR_score"][0]),
                OE_score=float(output["OE_score"][0]),
            )
            image.thumbnail((560, 400))
            preview = io.BytesIO()
            image.save(preview, format="JPEG", quality=85)
            row["preview"] = base64.b64encode(preview.getvalue()).decode("ascii")
            print(f"  {row['decision'].upper()}: {row['final_label'] or row['message']}", flush=True)
            for prediction in top3:
                print(f"  {prediction['rank']}. {prediction['dish']} — {prediction['confidence']:.2%}", flush=True)
        except Exception as error:
            row.update(decision="error", message=f"{type(error).__name__}: {error}")
            print(f"  ERROR: {row['message']}", flush=True)
        results.append(row)
    return results


def write_report(detector, results, directory):
    directory.mkdir(parents=True, exist_ok=True)
    payload = {
        "model": "FINAL_NONLINEAR_FUSION",
        "created_at": datetime.now(ZoneInfo("Asia/Riyadh")).isoformat(),
        "threshold": detector.threshold,
        "decision_rule": "Accept when nonlinear_score >= threshold; otherwise withhold dish label",
        "dinov2_confidence_definition": "Softmax over all 121 supported classes; top three shown even when rejected",
        "results": [{k: v for k, v in row.items() if k != "preview"} for row in results],
    }
    (directory / "results.json").write_text(json.dumps(payload, indent=2) + "\n")
    cards = []
    escape = html.escape
    for row in results:
        preview = f'<img alt="Selected photo" src="data:image/jpeg;base64,{row["preview"]}">' if "preview" in row else ""
        if row["decision"] == "error":
            content = f'<p>{escape(row["message"])}</p>'
        else:
            label = escape(row["final_label"].replace("_", " ")) if row["final_label"] else "Possibly unsupported dish"
            predictions = "".join(
                f'<tr><td>{prediction["rank"]}</td><td>{escape(prediction["dish"].replace("_", " "))}</td>'
                f'<td>{prediction["confidence"]:.2%}</td></tr>'
                for prediction in row["dinov2_top3"]
            )
            content = f'''<h2>{label}</h2><p>{escape(row['message'])}</p>
            <h3>DINOv2 — Top 3 dishes</h3>
            <table><thead><tr><th>Rank</th><th>Dish</th><th>Confidence</th></tr></thead><tbody>{predictions}</tbody></table>
            <p class="caption">DINOv2 predictions are shown even when the nonlinear model rejects the image.
            Confidence is calculated across all 121 supported dishes.</p>
            <dl><dt>Nonlinear supportedness score</dt><dd>{row['nonlinear_score']:.6f}</dd>
            <dt>Frozen acceptance threshold</dt><dd>{row['threshold']:.6f}</dd></dl>
            <details><summary>See classifier guess and component scores</summary>
            <p>Original classifier guess: <strong>{escape(row['original_dish_guess'])}</strong><br>
            Classifier confidence: {row['original_classifier_confidence']:.2%}<br>
            LR score: {row['LR_score']:.6f} · OE score: {row['OE_score']:.6f}</p>
            <p>The original classifier always chooses one of its 121 classes. For a rejected image,
            this guess is withheld from the final label.</p></details>'''
        cards.append(f'''<article>{preview}<div class="body"><span class="badge {row['decision']}">{row['decision'].upper()}</span>
        <p class="filename">{escape(row['filename'])}</p>{content}</div></article>''')
    accepted = sum(row["decision"] == "accepted" for row in results)
    rejected = sum(row["decision"] == "rejected" for row in results)
    errors = len(results) - accepted - rejected
    classes = ", ".join(escape(c.replace("_", " ")) for c in detector.classes)
    page = f'''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Nonlinear Fusion — your photo results</title><style>
    *{{box-sizing:border-box}}body{{margin:0;background:#f5f4ef;color:#202e28;font:16px/1.6 system-ui,sans-serif}}
    main{{max-width:1120px;margin:auto;padding:40px 24px}}h1{{font-size:34px;line-height:1.2}}h2{{font-size:24px;line-height:1.3}}
    .intro{{max-width:800px}}.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(310px,1fr));gap:24px;margin:30px 0}}
    article{{background:white;border:1px solid #ddd;border-radius:18px;overflow:hidden}}img{{width:100%;height:260px;object-fit:contain;background:#eaeae5}}
    .body{{padding:24px}}.badge{{font-size:12px;font-weight:700;padding:6px 10px;border-radius:20px}}
    .accepted{{background:#d8f0e2;color:#18523a}}.rejected{{background:#ffebcd;color:#75471c}}.error{{background:#ffe0e0;color:#842020}}
    .filename{{font-size:14px;overflow-wrap:anywhere;color:#626c67}}dt{{font-size:14px;color:#626c67}}dd{{margin:0 0 10px;font-variant-numeric:tabular-nums}}
    h3{{font-size:18px;margin:24px 0 8px}}table{{width:100%;border-collapse:collapse;font-size:14px}}th,td{{text-align:left;padding:9px 5px;border-bottom:1px solid #e8ece5}}
    th:last-child,td:last-child{{text-align:right;font-variant-numeric:tabular-nums}}.caption{{font-size:13px;color:#626c67}}
    details{{font-size:14px;margin-top:20px}}summary{{cursor:pointer;font-weight:600}}a{{color:#226146}}.note{{background:#e8ece5;padding:18px 22px;border-radius:12px}}
    </style><main><p>LOCAL MODEL TESTER · FINAL_NONLINEAR_FUSION</p><h1>Your photo results</h1>
    <div class="intro"><p>{accepted} accepted · {rejected} rejected · {errors} errors</p>
    <p>The frozen model processes each photo and decides whether to accept the dish prediction.
    Every photo shows DINOv2's top three dish guesses and their confidence scores, including rejected photos.
    A rejected image receives no accepted final dish label. These decisions can be wrong in either direction.</p>
    <p class="note">The supportedness score is used for the acceptance decision; it is not a calibrated probability
    that a dish is correct. Classifier confidence is a separate value. Testing non-food, packaged-food or
    multi-dish photos is exploratory; the recorded OOD evaluation covered unsupported dishes.</p>
    <p><a href="results.json" download>Download the complete JSON output</a> · To test more photos, run the tester again.</p></div>
    <div class="grid">{''.join(cards)}</div><details><summary>See all 121 supported dish classes</summary><p>{classes}</p></details>
    <p>Model and threshold unchanged. Processed locally on CPU. JPEG, PNG, WebP, BMP, TIFF and GIF inputs supported;
    GIF uses the first frame. Convert HEIC photos to JPEG or PNG first.</p></main></html>'''
    path = directory / "results.html"
    path.write_text(page)
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", type=Path, nargs="*", help="Image files; omit to open a photo chooser")
    parser.add_argument("--checkpoint", type=Path, help="Original OneDrive checkpoint; default: Dish-Recognition/models/best_checkpoint.pt")
    parser.add_argument("--no-open", action="store_true", help="Save results without opening the report")
    parser.add_argument("--output-dir", type=Path, help="New folder for this run's output")
    args = parser.parse_args()
    paths = args.images or choose_images()
    if not paths:
        print("No photos selected.")
        return
    if args.output_dir and args.output_dir.exists():
        parser.error("Choose a new output folder so previous results are preserved.")
    print("Loading the frozen Nonlinear Fusion model. The first photo may take a moment…", flush=True)
    detector = load_detector(args.checkpoint)
    # Fail once for model/environment problems, before processing individual photos.
    detector.load_original()
    directory = args.output_dir or Path(tempfile.mkdtemp(
        prefix=datetime.now(ZoneInfo("Asia/Riyadh")).strftime("%Y%m%d_%H%M%S_"),
        dir=_results_root(),
    ))
    results = run_images(detector, paths)
    report = write_report(detector, results, directory)
    print(f"\nResults saved to: {report}", flush=True)
    if not args.no_open:
        if not webbrowser.open(report.resolve().as_uri()):
            print("Open the results.html file above in your browser.", flush=True)
    if all(row["decision"] == "error" for row in results):
        sys.exit(1)


def _results_root():
    directory = ROOT / "manual_testing/results"
    directory.mkdir(parents=True, exist_ok=True)
    return str(directory)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)
