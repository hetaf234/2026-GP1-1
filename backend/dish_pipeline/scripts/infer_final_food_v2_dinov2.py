#!/usr/bin/env python3
"""Run one-image inference with the local 121-class DINOv2 ViT-B/14 checkpoint.

This implementation intentionally contains the small DINOv2 ViT-B/14 model
definition needed by this checkpoint.  It never calls torch.hub and therefore
never downloads model code or weights.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

import torch
import torch.nn.functional as F
from PIL import Image
from torch import Tensor, nn
from torchvision import transforms
from torchvision.transforms import InterpolationMode


DEFAULT_CHECKPOINT = Path(__file__).resolve().parents[1] / "models" / "best_checkpoint.pt"
IMAGENET_MEAN = (0.485, 0.456, 0.406)
IMAGENET_STD = (0.229, 0.224, 0.225)


class PatchEmbed(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.proj = nn.Conv2d(3, 768, kernel_size=14, stride=14)

    def forward(self, images: Tensor) -> Tensor:
        return self.proj(images).flatten(2).transpose(1, 2)


class Attention(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.num_heads = 12
        self.scale = (768 // self.num_heads) ** -0.5
        self.qkv = nn.Linear(768, 768 * 3)
        self.proj = nn.Linear(768, 768)

    def forward(self, tokens: Tensor) -> Tensor:
        batch, token_count, channels = tokens.shape
        qkv = self.qkv(tokens).reshape(batch, token_count, 3, self.num_heads, channels // self.num_heads)
        qkv = qkv.permute(2, 0, 3, 1, 4)
        query, key, value = qkv.unbind(0)
        attention = (query * self.scale) @ key.transpose(-2, -1)
        attention = attention.softmax(dim=-1)
        tokens = (attention @ value).transpose(1, 2).reshape(batch, token_count, channels)
        return self.proj(tokens)


class Mlp(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.fc1 = nn.Linear(768, 3072)
        self.fc2 = nn.Linear(3072, 768)

    def forward(self, tokens: Tensor) -> Tensor:
        return self.fc2(F.gelu(self.fc1(tokens)))


class LayerScale(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.gamma = nn.Parameter(torch.ones(768))

    def forward(self, tokens: Tensor) -> Tensor:
        return tokens * self.gamma


class Block(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.norm1 = nn.LayerNorm(768, eps=1e-6)
        self.attn = Attention()
        self.ls1 = LayerScale()
        self.norm2 = nn.LayerNorm(768, eps=1e-6)
        self.mlp = Mlp()
        self.ls2 = LayerScale()

    def forward(self, tokens: Tensor) -> Tensor:
        tokens = tokens + self.ls1(self.attn(self.norm1(tokens)))
        return tokens + self.ls2(self.mlp(self.norm2(tokens)))


class DinoV2ViTB14(nn.Module):
    """DINOv2 ViT-B/14 backbone matching the checkpoint's state-dict layout."""

    def __init__(self) -> None:
        super().__init__()
        self.cls_token = nn.Parameter(torch.zeros(1, 1, 768))
        # The checkpoint uses DINOv2's native 37 x 37 positional grid.
        self.pos_embed = nn.Parameter(torch.zeros(1, 37 * 37 + 1, 768))
        self.mask_token = nn.Parameter(torch.zeros(1, 768))
        self.patch_embed = PatchEmbed()
        self.blocks = nn.ModuleList(Block() for _ in range(12))
        self.norm = nn.LayerNorm(768, eps=1e-6)

    def interpolate_pos_encoding(self, tokens: Tensor, height: int, width: int) -> Tensor:
        patch_height, patch_width = height // 14, width // 14
        if patch_height == 37 and patch_width == 37:
            return self.pos_embed
        class_position = self.pos_embed[:, :1]
        patch_positions = self.pos_embed[:, 1:].float().reshape(1, 37, 37, 768).permute(0, 3, 1, 2)
        # DINOv2 uses this 0.1 offset in its positional-embedding interpolation.
        positions = F.interpolate(
            patch_positions,
            scale_factor=((patch_height + 0.1) / 37, (patch_width + 0.1) / 37),
            mode="bicubic",
            align_corners=False,
        )
        if positions.shape[-2:] != (patch_height, patch_width):
            raise RuntimeError("DINOv2 positional-embedding interpolation produced an unexpected size")
        positions = positions.permute(0, 2, 3, 1).reshape(1, patch_height * patch_width, 768)
        return torch.cat((class_position, positions), dim=1).to(dtype=tokens.dtype)

    def forward(self, images: Tensor) -> Tensor:
        height, width = images.shape[-2:]
        tokens = self.patch_embed(images)
        class_tokens = self.cls_token.expand(tokens.shape[0], -1, -1)
        tokens = torch.cat((class_tokens, tokens), dim=1)
        tokens = tokens + self.interpolate_pos_encoding(tokens, height, width)
        for block in self.blocks:
            tokens = block(tokens)
        return self.norm(tokens)[:, 0]


class DinoClassifier(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.backbone = DinoV2ViTB14()
        self.head = nn.Linear(768, 121)

    def forward(self, images: Tensor) -> Tensor:
        return self.head(self.backbone(images))

    def forward_with_embedding(self, images: Tensor) -> tuple[Tensor, Tensor]:
        embedding = self.backbone(images)
        logits = self.head(embedding)
        return logits, embedding


def choose_device() -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_checkpoint(path: Path) -> tuple[DinoClassifier, list[str], dict, dict]:
    if not path.is_file():
        raise FileNotFoundError(f"Checkpoint not found: {path}")
    checkpoint = torch.load(path, map_location="cpu", weights_only=False)
    mapping = checkpoint.get("class_to_idx")
    classes = checkpoint.get("classes")
    preprocessing = checkpoint.get("preprocessing")
    if checkpoint.get("architecture") != "DINOv2_ViTB14":
        raise RuntimeError(f"Expected DINOv2_ViTB14, found {checkpoint.get('architecture')!r}")
    if not isinstance(mapping, dict) or len(mapping) != 121 or set(mapping.values()) != set(range(121)):
        raise RuntimeError("Checkpoint does not contain a valid contiguous 121-class class_to_idx mapping")
    ordered_classes = [name for name, index in sorted(mapping.items(), key=lambda item: item[1])]
    if classes != ordered_classes:
        raise RuntimeError("Checkpoint classes list does not agree with its class_to_idx mapping")
    if not isinstance(preprocessing, dict):
        raise RuntimeError("Checkpoint does not include preprocessing metadata")
    expected_preprocessing = {"image_size": 336, "eval_resize": 378,
                              "mean": IMAGENET_MEAN, "std": IMAGENET_STD}
    for key, expected in expected_preprocessing.items():
        actual = tuple(preprocessing.get(key, ())) if key in {"mean", "std"} else preprocessing.get(key)
        if actual != expected:
            raise RuntimeError(f"Unexpected checkpoint preprocessing for {key}: {preprocessing.get(key)!r}")
    state = checkpoint.get("model_state_dict")
    if not isinstance(state, dict) or tuple(state.get("head.weight", ()).shape) != (121, 768):
        raise RuntimeError("Checkpoint does not contain the expected 121 x 768 classifier head")
    model = DinoClassifier()
    model.load_state_dict(state, strict=True)
    return model, ordered_classes, preprocessing, checkpoint


def make_transform(preprocessing: dict) -> transforms.Compose:
    return transforms.Compose([
        transforms.Resize(preprocessing["eval_resize"], interpolation=InterpolationMode.BICUBIC),
        transforms.CenterCrop(preprocessing["image_size"]),
        transforms.ToTensor(),
        transforms.Normalize(preprocessing["mean"], preprocessing["std"]),
    ])


def main() -> None:
    parser = argparse.ArgumentParser(description="Classify one image with the local final 121-class DINOv2 checkpoint.")
    parser.add_argument("image", type=Path, nargs="?", help="Image to classify")
    parser.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT,
                        help=f"Checkpoint to use (default: {DEFAULT_CHECKPOINT})")
    parser.add_argument("--verify-only", action="store_true", help="Verify checkpoint compatibility without opening an image")
    args = parser.parse_args()
    if not args.verify_only and args.image is None:
        parser.error("image is required unless --verify-only is specified")

    model, classes, preprocessing, checkpoint = load_checkpoint(args.checkpoint)
    print(f"Checkpoint: {args.checkpoint}")
    print(f"SHA-256: {sha256(args.checkpoint)}")
    print("Architecture: DINOv2 ViT-B/14 (12 blocks, 12 attention heads, 768 embedding dimensions, 14px patches)")
    print(f"Classes: {len(classes)} (indices 0–120; mapping loaded directly from the checkpoint)")
    print("Validation/inference transform: Resize(378, bicubic) → CenterCrop(336) → ToTensor → ImageNet normalization")
    if args.verify_only:
        return

    device = choose_device()
    model.to(device).eval()
    try:
        with Image.open(args.image) as source:
            image = make_transform(preprocessing)(source.convert("RGB")).unsqueeze(0).to(device)
    except (OSError, ValueError) as error:
        raise RuntimeError(f"Could not read image {args.image}: {error}") from error
    with torch.inference_mode():
        probabilities = model(image).softmax(dim=1)[0].cpu()
    scores, indices = probabilities.topk(5)
    print(f"Device: {device.type.upper()}")
    print(f"Predicted class: {classes[indices[0].item()]}")
    print(f"Confidence: {scores[0].item() * 100:.2f}%")
    print("Top 5 predictions:")
    for rank, (index, score) in enumerate(zip(indices.tolist(), scores.tolist(), strict=True), start=1):
        print(f"  {rank}. {classes[index]} — {score * 100:.2f}%")


if __name__ == "__main__":
    main()
