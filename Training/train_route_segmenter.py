#!/usr/bin/env python3
"""Train and audit the lightweight Motorfest minimap route segmenter.

The deployable model is intentionally tiny: a learned 3x3 RGB convolution,
ReLU, and a learned 1x1 output projection.  That architecture can be executed
directly in Swift without a third-party runtime while still replacing the old
hand-written RGB threshold with a reproducible trained model.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import time
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import log_loss
from sklearn.neural_network import MLPClassifier
from sklearn.preprocessing import StandardScaler


MODEL_WIDTH = 176
MODEL_HEIGHT = 176
PATCH_RADIUS = 1
RANDOM_SEED = 262569


@dataclass(frozen=True)
class Sample:
    sample_id: str
    numeric_id: int
    source_group_id: str
    source_name: str
    exported_split: str
    review_status: str
    image_path: Path
    mask_path: Path


@dataclass
class Metrics:
    threshold: float
    pixel_precision: float
    pixel_recall: float
    pixel_f1: float
    pixel_iou: float
    tolerant_precision: float
    tolerant_recall: float
    tolerant_f1: float
    mean_positive_iou: float
    median_positive_iou: float
    presence_accuracy: float
    empty_specificity: float
    false_positive_empty_frames: int
    positive_frames: int
    empty_frames: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=int, default=MODEL_WIDTH)
    parser.add_argument("--height", type=int, default=MODEL_HEIGHT)
    return parser.parse_args()


def load_samples(root: Path) -> list[Sample]:
    manifest = json.loads((root / "manifest.json").read_text())
    samples: list[Sample] = []
    for item in manifest["samples"]:
        sample_id = item["sampleID"]
        samples.append(
            Sample(
                sample_id=sample_id,
                numeric_id=int(sample_id.rsplit("_", 1)[1]),
                source_group_id=item.get("sourceGroupID", "legacy-unknown"),
                source_name=item.get("sourceName", "Unknown"),
                exported_split=item["split"],
                review_status=item["reviewStatus"],
                image_path=root / item["imagePath"],
                mask_path=root / item["maskPath"],
            )
        )
    return sorted(samples, key=lambda sample: sample.numeric_id)


def verify_dataset(samples: list[Sample]) -> dict:
    if not samples:
        raise ValueError("Dataset contains no samples")

    missing: list[str] = []
    dimensions: dict[str, int] = {}
    mask_values: set[int] = set()
    exact_image_hashes: dict[str, list[str]] = {}
    empty_count = 0
    positive_count = 0
    component_histogram: dict[int, int] = {}

    for sample in samples:
        if not sample.image_path.is_file() or not sample.mask_path.is_file():
            missing.append(sample.sample_id)
            continue

        with Image.open(sample.image_path) as image:
            dimensions[f"{image.width}x{image.height}"] = (
                dimensions.get(f"{image.width}x{image.height}", 0) + 1
            )
            digest = hashlib.sha256(image.tobytes()).hexdigest()
            exact_image_hashes.setdefault(digest, []).append(sample.sample_id)

        with Image.open(sample.mask_path) as mask_image:
            mask_array = np.asarray(mask_image.convert("L"), dtype=np.uint8)
            mask_values.update(int(value) for value in np.unique(mask_array))
            mask = mask_array > 127
            if mask.any():
                positive_count += 1
            else:
                empty_count += 1
            _, component_count = ndimage.label(
                mask, structure=np.ones((3, 3), dtype=np.uint8)
            )
            component_histogram[component_count] = (
                component_histogram.get(component_count, 0) + 1
            )

    if missing:
        raise ValueError(f"Missing {len(missing)} image/mask pairs: {missing[:8]}")
    if not mask_values.issubset({0, 255}):
        raise ValueError(f"Masks are not binary: {sorted(mask_values)}")

    duplicate_groups = [ids for ids in exact_image_hashes.values() if len(ids) > 1]
    return {
        "sampleCount": len(samples),
        "positiveMaskCount": positive_count,
        "emptyMaskCount": empty_count,
        "dimensions": dimensions,
        "maskValues": sorted(mask_values),
        "exactDuplicateImageGroups": duplicate_groups,
        "componentCountHistogram": {
            str(key): value for key, value in sorted(component_histogram.items())
        },
    }


def assign_roles(samples: list[Sample]) -> tuple[list[Sample], list[Sample], list[Sample]]:
    """Create train/dev/test roles without trusting the reversed export split.

    The 39 samples with a real source group are from one newer recording and
    become a one-time source holdout. Legacy samples are split into temporal
    blocks so neighboring video frames are not randomly scattered one by one.
    """

    source_holdout = [
        sample for sample in samples if sample.source_group_id != "legacy-unknown"
    ]
    legacy = [sample for sample in samples if sample.source_group_id == "legacy-unknown"]

    if source_holdout and legacy:
        test = source_holdout
        train = []
        dev = []
        for sample in legacy:
            block_index = sample.numeric_id // 12
            if block_index % 5 == 4:
                dev.append(sample)
            else:
                train.append(sample)
    else:
        train, dev, test = [], [], []
        for sample in samples:
            block_index = sample.numeric_id // 10
            selector = block_index % 10
            if selector == 8:
                dev.append(sample)
            elif selector == 9:
                test.append(sample)
            else:
                train.append(sample)

    if not train or not dev or not test:
        raise ValueError(
            f"Could not build non-empty train/dev/test roles: "
            f"{len(train)}/{len(dev)}/{len(test)}"
        )
    return train, dev, test


def resize_pair(sample: Sample, width: int, height: int) -> tuple[np.ndarray, np.ndarray]:
    with Image.open(sample.image_path) as image:
        rgb = np.asarray(
            image.convert("RGB").resize((width, height), Image.Resampling.BILINEAR),
            dtype=np.float32,
        ) / 255.0
    with Image.open(sample.mask_path) as mask_image:
        mask = np.asarray(
            mask_image.convert("L").resize((width, height), Image.Resampling.NEAREST),
            dtype=np.uint8,
        ) > 127
    return rgb, mask


def patch_features(rgb: np.ndarray) -> np.ndarray:
    padded = np.pad(
        rgb,
        ((PATCH_RADIUS, PATCH_RADIUS), (PATCH_RADIUS, PATCH_RADIUS), (0, 0)),
        mode="edge",
    )
    windows = np.lib.stride_tricks.sliding_window_view(
        padded,
        (2 * PATCH_RADIUS + 1, 2 * PATCH_RADIUS + 1),
        axis=(0, 1),
    )
    # sliding_window_view returns H,W,C,KH,KW. Deployment order is KH,KW,C.
    return windows.transpose(0, 1, 3, 4, 2).reshape(-1, 27).astype(np.float32)


def sample_training_pixels(
    samples: list[Sample], width: int, height: int
) -> tuple[np.ndarray, np.ndarray, dict]:
    rng = np.random.default_rng(RANDOM_SEED)
    feature_chunks: list[np.ndarray] = []
    label_chunks: list[np.ndarray] = []
    class_counts = {
        "positive": 0,
        "hardNegative": 0,
        "boundaryNegative": 0,
        "randomNegative": 0,
        "colorAugmented": 0,
    }

    for index, sample in enumerate(samples, start=1):
        rgb, mask = resize_pair(sample, width, height)
        features = patch_features(rgb)
        labels = mask.reshape(-1)
        flat_rgb = rgb.reshape(-1, 3)

        positive = np.flatnonzero(labels)
        negative_mask = ~mask
        red, green, blue = flat_rgb[:, 0], flat_rgb[:, 1], flat_rgb[:, 2]
        yellowish = (
            (red > 0.50)
            & (green > 0.42)
            & ((np.minimum(red, green) - blue) > 0.12)
            & (np.abs(red - green) < 0.42)
        )
        hard_negative = np.flatnonzero(yellowish & ~labels)
        boundary = ndimage.binary_dilation(mask, iterations=4) & negative_mask
        boundary_negative = np.flatnonzero(boundary)
        random_negative = np.flatnonzero(
            negative_mask.reshape(-1) & ~yellowish & ~boundary.reshape(-1)
        )

        def choose(values: np.ndarray, limit: int) -> np.ndarray:
            if len(values) <= limit:
                return values
            return rng.choice(values, size=limit, replace=False)

        selected_positive = choose(positive, 700)
        selected_hard = choose(hard_negative, 700)
        selected_boundary = choose(boundary_negative, 350)
        selected_random = choose(random_negative, 700)
        chosen = np.concatenate(
            [selected_positive, selected_hard, selected_boundary, selected_random]
        )

        if len(chosen):
            chosen_features = features[chosen]
            chosen_labels = labels[chosen].astype(np.uint8)
            feature_chunks.append(chosen_features)
            label_chunks.append(chosen_labels)

            # Capture cards, HDR tone mapping, weather, and streamed video all
            # shift the same Motorfest yellow. Add per-frame photometric
            # variants so the learned mask does not memorize one recording's
            # exact RGB values.
            augmentation_count = len(chosen) // 2
            augmentation_indices = rng.choice(
                len(chosen), size=augmentation_count, replace=False
            )
            augmented = chosen_features[augmentation_indices].reshape(-1, 9, 3).copy()
            channel_gain = rng.uniform(0.82, 1.18, size=(1, 1, 3)).astype(np.float32)
            contrast = float(rng.uniform(0.82, 1.18))
            brightness = float(rng.uniform(-0.10, 0.10))
            gamma = float(rng.uniform(0.78, 1.24))
            augmented = np.clip(
                (augmented - 0.5) * contrast + 0.5 + brightness, 0.0, 1.0
            )
            augmented = np.clip(augmented * channel_gain, 0.0, 1.0) ** gamma
            feature_chunks.append(augmented.reshape(-1, 27).astype(np.float32))
            label_chunks.append(chosen_labels[augmentation_indices])
            class_counts["colorAugmented"] += augmentation_count
        class_counts["positive"] += len(selected_positive)
        class_counts["hardNegative"] += len(selected_hard)
        class_counts["boundaryNegative"] += len(selected_boundary)
        class_counts["randomNegative"] += len(selected_random)

        if index % 80 == 0 or index == len(samples):
            print(f"feature extraction {index}/{len(samples)}", flush=True)

    x = np.concatenate(feature_chunks).astype(np.float32)
    y = np.concatenate(label_chunks).astype(np.uint8)
    order = rng.permutation(len(y))
    return x[order], y[order], class_counts


def fixed_threshold_probability(rgb: np.ndarray) -> np.ndarray:
    red = rgb[:, :, 0] * 255.0
    green = rgb[:, :, 1] * 255.0
    blue = rgb[:, :, 2] * 255.0
    detected = (
        (red >= 185)
        & (green >= 170)
        & (blue <= 115)
        & ((red - blue) >= 65)
        & ((green - blue) >= 55)
        & (np.abs(red - green) <= 75)
    )
    return detected.astype(np.float32)


def roi_mask(width: int, height: int) -> np.ndarray:
    yy, xx = np.mgrid[0:height, 0:width]
    relative_x = (xx + 0.5) / width
    relative_y = (yy + 0.5) / height
    nx = (relative_x - 0.5) / 0.5
    ny = (relative_y - 0.5) / 0.5
    return ((nx * nx + ny * ny) <= (0.88 * 0.88)) & (relative_y <= 0.89)


def player_anchor(rgb: np.ndarray) -> tuple[float, float] | None:
    height, width, _ = rgb.shape
    yy, xx = np.mgrid[0:height, 0:width]
    rx = (xx + 0.5) / width
    ry = (yy + 0.5) / height
    nx = (rx - 0.5) / 0.5
    ny = (ry - 0.5) / 0.5
    red, green, blue = rgb[:, :, 0], rgb[:, :, 1], rgb[:, :, 2]
    cyan = (
        (green >= 0.58)
        & (blue >= 0.58)
        & ((np.minimum(green, blue) - red) >= 0.16)
        & (np.abs(green - blue) <= 0.30)
        & (rx >= 0.28)
        & (rx <= 0.72)
        & (ry >= 0.50)
        & (ry <= 0.92)
        & ((nx * nx + ny * ny) <= (0.93 * 0.93))
    )
    labels, count = ndimage.label(cyan, structure=np.ones((3, 3), dtype=np.uint8))
    if not count:
        return None

    best_score = -1.0
    best_anchor: tuple[float, float] | None = None
    for label_value in range(1, count + 1):
        component_y, component_x = np.nonzero(labels == label_value)
        area = len(component_x)
        if area < max(8, int(width * height * 0.00025)):
            continue
        span_x = int(component_x.max() - component_x.min() + 1)
        span_y = int(component_y.max() - component_y.min() + 1)
        if max(span_x, span_y) > min(width, height) * 0.24:
            continue
        fill = area / max(span_x * span_y, 1)
        if fill < 0.12:
            continue
        cx = float(component_x.mean())
        cy = float(component_y.mean())
        expected_distance = math.hypot(
            (cx / max(width - 1, 1) - 0.50) / 0.30,
            (cy / max(height - 1, 1) - 0.73) / 0.26,
        )
        area_target = width * height * 0.0035
        area_score = math.exp(-abs(math.log(max(area, 1) / area_target)))
        fill_score = min(fill / 0.35, 1.0)
        location_score = max(0.0, 1.0 - expected_distance)
        score = 0.45 * area_score + 0.25 * fill_score + 0.30 * location_score
        if score > best_score:
            best_score = score
            best_anchor = (cx, cy)
    return best_anchor


def postprocess(probability: np.ndarray, rgb: np.ndarray, threshold: float) -> np.ndarray:
    height, width = probability.shape
    candidate = (probability >= threshold) & roi_mask(width, height)
    candidate = ndimage.binary_closing(candidate, structure=np.ones((3, 3), dtype=bool))
    labels, component_count = ndimage.label(
        candidate, structure=np.ones((3, 3), dtype=np.uint8)
    )
    if component_count == 0:
        return np.zeros_like(candidate)

    anchor = player_anchor(rgb)
    if anchor is None:
        return np.zeros_like(candidate)
    player_x, player_y = anchor
    minimum_dimension = float(min(width, height))
    minimum_area = max(12, int(width * height * 0.00055))
    minimum_span = max(8.0, minimum_dimension * 0.10)
    minimum_reach = max(6.0, minimum_dimension * 0.065)
    maximum_player_gap = minimum_dimension * 0.34
    maximum_chain_gap = minimum_dimension * 0.16

    components: list[dict] = []
    for label_value in range(1, component_count + 1):
        ys, xs = np.nonzero(labels == label_value)
        if not len(xs):
            continue
        distances = np.hypot(xs - player_x, ys - player_y)
        component = {
            "label": label_value,
            "area": len(xs),
            "min_x": int(xs.min()),
            "max_x": int(xs.max()),
            "min_y": int(ys.min()),
            "max_y": int(ys.max()),
            "minimum_player_distance": float(distances.min()),
            "radial_reach": float(distances.max() - distances.min()),
        }
        component["span"] = max(
            component["max_x"] - component["min_x"] + 1,
            component["max_y"] - component["min_y"] + 1,
        )
        component["minor_span"] = min(
            component["max_x"] - component["min_x"] + 1,
            component["max_y"] - component["min_y"] + 1,
        )
        component["elongation"] = component["span"] / max(
            component["minor_span"], 1
        )
        component["is_short_route"] = (
            component["area"] >= max(8, int(width * height * 0.00025))
            and component["span"] >= minimum_dimension * 0.045
            and component["radial_reach"] >= minimum_dimension * 0.025
            and component["minimum_player_distance"] <= minimum_dimension * 0.12
            and component["elongation"] >= 1.45
        )
        if component["is_short_route"] or (
            component["area"] >= minimum_area
            and component["span"] >= minimum_span
            and component["radial_reach"] >= minimum_reach
        ):
            components.append(component)

    selected = [
        component
        for component in components
        if component["minimum_player_distance"]
        <= (
            minimum_dimension * 0.12
            if component["is_short_route"]
            else maximum_player_gap
        )
    ]
    selected_labels = {component["label"] for component in selected}

    def component_gap(first: dict, second: dict) -> float:
        if first["max_x"] < second["min_x"]:
            dx = second["min_x"] - first["max_x"]
        elif second["max_x"] < first["min_x"]:
            dx = first["min_x"] - second["max_x"]
        else:
            dx = 0
        if first["max_y"] < second["min_y"]:
            dy = second["min_y"] - first["max_y"]
        elif second["max_y"] < first["min_y"]:
            dy = first["min_y"] - second["max_y"]
        else:
            dy = 0
        return math.hypot(dx, dy)

    changed = True
    while changed and selected:
        changed = False
        for component in components:
            if component["label"] in selected_labels:
                continue
            if any(component_gap(component, prior) <= maximum_chain_gap for prior in selected):
                selected.append(component)
                selected_labels.add(component["label"])
                changed = True
    return np.isin(labels, list(selected_labels)) if selected_labels else np.zeros_like(candidate)


def predictions_for_samples(
    model, scaler: StandardScaler | None, samples: list[Sample], width: int, height: int
) -> list[tuple[Sample, np.ndarray, np.ndarray, np.ndarray]]:
    rows = []
    for index, sample in enumerate(samples, start=1):
        rgb, truth = resize_pair(sample, width, height)
        if model == "fixed":
            probability = fixed_threshold_probability(rgb)
        else:
            features = patch_features(rgb)
            if scaler is not None:
                features = scaler.transform(features)
            probability = model.predict_proba(features)[:, 1].reshape(height, width)
        rows.append((sample, rgb, truth, probability.astype(np.float32)))
        if index % 60 == 0 or index == len(samples):
            print(f"prediction {index}/{len(samples)}", flush=True)
    return rows


def aggregate_pixel_counts(rows, threshold: float) -> tuple[int, int, int]:
    tp = fp = fn = 0
    for _, _, truth, probability in rows:
        prediction = (probability >= threshold) & roi_mask(truth.shape[1], truth.shape[0])
        tp += int(np.count_nonzero(prediction & truth))
        fp += int(np.count_nonzero(prediction & ~truth))
        fn += int(np.count_nonzero(~prediction & truth))
    return tp, fp, fn


def choose_threshold(rows) -> float:
    best_threshold = 0.5
    best_score = -1.0
    for threshold in np.linspace(0.10, 0.995, 120):
        tp, fp, fn = aggregate_pixel_counts(rows, float(threshold))
        iou = tp / max(tp + fp + fn, 1)
        precision = tp / max(tp + fp, 1)
        recall = tp / max(tp + fn, 1)
        # Favor precision slightly: downstream geometry cannot rescue a long
        # false route that happens to be near the player arrow.
        score = iou + 0.04 * precision - 0.02 * max(0.78 - recall, 0)
        if score > best_score:
            best_score = score
            best_threshold = float(threshold)
    return best_threshold


def compute_metrics(rows, threshold: float, apply_postprocess: bool) -> Metrics:
    tp = fp = fn = 0
    tolerant_tp_pred = tolerant_tp_truth = 0
    prediction_total = truth_total = 0
    positive_ious: list[float] = []
    presence_correct = 0
    empty_correct = 0
    false_positive_empty = 0
    positive_frames = 0
    empty_frames = 0

    for _, rgb, truth, probability in rows:
        if apply_postprocess:
            prediction = postprocess(probability, rgb, threshold)
        else:
            prediction = (probability >= threshold) & roi_mask(truth.shape[1], truth.shape[0])
        local_tp = int(np.count_nonzero(prediction & truth))
        local_fp = int(np.count_nonzero(prediction & ~truth))
        local_fn = int(np.count_nonzero(~prediction & truth))
        tp += local_tp
        fp += local_fp
        fn += local_fn

        truth_dilated = ndimage.binary_dilation(truth, iterations=2)
        prediction_dilated = ndimage.binary_dilation(prediction, iterations=2)
        tolerant_tp_pred += int(np.count_nonzero(prediction & truth_dilated))
        tolerant_tp_truth += int(np.count_nonzero(truth & prediction_dilated))
        prediction_total += int(prediction.sum())
        truth_total += int(truth.sum())

        truth_present = bool(truth.any())
        prediction_present = bool(prediction.any())
        presence_correct += int(truth_present == prediction_present)
        if truth_present:
            positive_frames += 1
            union = int(np.count_nonzero(prediction | truth))
            positive_ious.append(local_tp / max(union, 1))
        else:
            empty_frames += 1
            empty_correct += int(not prediction_present)
            false_positive_empty += int(prediction_present)

    precision = tp / max(tp + fp, 1)
    recall = tp / max(tp + fn, 1)
    tolerant_precision = tolerant_tp_pred / max(prediction_total, 1)
    tolerant_recall = tolerant_tp_truth / max(truth_total, 1)
    return Metrics(
        threshold=threshold,
        pixel_precision=precision,
        pixel_recall=recall,
        pixel_f1=2 * precision * recall / max(precision + recall, 1e-12),
        pixel_iou=tp / max(tp + fp + fn, 1),
        tolerant_precision=tolerant_precision,
        tolerant_recall=tolerant_recall,
        tolerant_f1=2
        * tolerant_precision
        * tolerant_recall
        / max(tolerant_precision + tolerant_recall, 1e-12),
        mean_positive_iou=float(np.mean(positive_ious)) if positive_ious else 0.0,
        median_positive_iou=float(np.median(positive_ious)) if positive_ious else 0.0,
        presence_accuracy=presence_correct / max(len(rows), 1),
        empty_specificity=empty_correct / max(empty_frames, 1),
        false_positive_empty_frames=false_positive_empty,
        positive_frames=positive_frames,
        empty_frames=empty_frames,
    )


def train_models(x: np.ndarray, y: np.ndarray):
    scaler = StandardScaler(copy=False)
    x_scaled = scaler.fit_transform(x)
    positives = int(y.sum())
    negatives = len(y) - positives
    weights = np.where(
        y == 1,
        len(y) / max(2 * positives, 1),
        len(y) / max(2 * negatives, 1),
    ).astype(np.float32)

    candidates = []
    print("training logistic baseline", flush=True)
    logistic = LogisticRegression(
        C=2.0,
        max_iter=180,
        solver="lbfgs",
        random_state=RANDOM_SEED,
    )
    logistic.fit(x_scaled, y, sample_weight=weights)
    candidates.append(("logistic", logistic))

    for hidden_units in (12, 20):
        print(f"training MLP-{hidden_units}", flush=True)
        model = MLPClassifier(
            hidden_layer_sizes=(hidden_units,),
            activation="relu",
            solver="adam",
            alpha=0.00025,
            batch_size=2048,
            learning_rate_init=0.002,
            max_iter=55,
            early_stopping=True,
            validation_fraction=0.12,
            n_iter_no_change=6,
            random_state=RANDOM_SEED + hidden_units,
            verbose=False,
        )
        model.fit(x_scaled, y, sample_weight=weights)
        candidates.append((f"mlp_{hidden_units}", model))
    return scaler, candidates


def folded_weights(model: MLPClassifier, scaler: StandardScaler) -> dict:
    first_weights = model.coefs_[0].astype(np.float64)
    first_bias = model.intercepts_[0].astype(np.float64)
    folded_first = first_weights / scaler.scale_[:, None]
    folded_bias = first_bias - (scaler.mean_ / scaler.scale_) @ first_weights
    output_weights = model.coefs_[1].reshape(-1).astype(np.float64)
    output_bias = float(model.intercepts_[1][0])
    return {
        "formatVersion": 1,
        "architecture": "rgb_3x3_conv_relu_1x1_sigmoid",
        "inputWidth": MODEL_WIDTH,
        "inputHeight": MODEL_HEIGHT,
        "patchSize": 3,
        "inputChannels": 3,
        "hiddenChannels": int(first_weights.shape[1]),
        "firstLayerWeightsInputMajor": folded_first.astype(np.float32).reshape(-1).tolist(),
        "firstLayerBias": folded_bias.astype(np.float32).tolist(),
        "outputWeights": output_weights.astype(np.float32).tolist(),
        "outputBias": output_bias,
    }


def write_swift_weights(payload: dict, threshold: float, output_path: Path) -> None:
    def format_array(values) -> str:
        chunks = []
        values = [float(value) for value in values]
        for start in range(0, len(values), 8):
            line = ", ".join(f"{value:.9g}" for value in values[start : start + 8])
            chunks.append("        " + line)
        return ",\n".join(chunks)

    swift = f'''import Foundation

// Generated by Training/train_route_segmenter.py.
// Dataset: 582 reviewed Motorfest minimap image/mask pairs.
nonisolated enum LearnedRouteSegmenterWeights {{

    static let inputWidth = {payload["inputWidth"]}
    static let inputHeight = {payload["inputHeight"]}
    static let patchSize = {payload["patchSize"]}
    static let inputChannels = {payload["inputChannels"]}
    static let hiddenChannels = {payload["hiddenChannels"]}
    static let probabilityThreshold: Float = {threshold:.9g}

    // Flattened as input feature (3x3 RGB) major, hidden channel minor.
    static let firstLayerWeights: [Float] = [
{format_array(payload["firstLayerWeightsInputMajor"])}
    ]

    static let firstLayerBias: [Float] = [
{format_array(payload["firstLayerBias"])}
    ]

    static let outputWeights: [Float] = [
{format_array(payload["outputWeights"])}
    ]

    static let outputBias: Float = {payload["outputBias"]:.9g}
}}
'''
    output_path.write_text(swift)


def save_visualizations(rows, threshold: float, output: Path, count: int = 20) -> None:
    output.mkdir(parents=True, exist_ok=True)
    selected_indices = np.linspace(0, len(rows) - 1, min(count, len(rows)), dtype=int)
    for output_index, row_index in enumerate(selected_indices):
        sample, rgb, truth, probability = rows[int(row_index)]
        prediction = postprocess(probability, rgb, threshold)
        image = (np.clip(rgb, 0, 1) * 255).astype(np.uint8)
        overlay = image.copy()
        overlay[prediction] = (
            0.25 * overlay[prediction] + 0.75 * np.array([255, 35, 190])
        ).astype(np.uint8)
        truth_rgb = np.zeros_like(image)
        truth_rgb[truth] = np.array([255, 255, 255], dtype=np.uint8)
        probability_rgb = np.repeat(
            (np.clip(probability, 0, 1)[:, :, None] * 255).astype(np.uint8), 3, axis=2
        )
        panel = np.concatenate([image, truth_rgb, probability_rgb, overlay], axis=1)
        Image.fromarray(panel).save(
            output / f"{output_index:02d}_{sample.sample_id}.png"
        )


def main() -> None:
    args = parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    samples = load_samples(args.dataset)
    audit = verify_dataset(samples)
    train_samples, dev_samples, test_samples = assign_roles(samples)
    audit["roles"] = {
        "train": len(train_samples),
        "development": len(dev_samples),
        "sourceHoldoutTest": len(test_samples),
        "sourceHoldoutNames": sorted({sample.source_name for sample in test_samples}),
    }
    (args.output / "dataset_audit.json").write_text(json.dumps(audit, indent=2))
    print(json.dumps(audit, indent=2), flush=True)

    start = time.monotonic()
    x, y, sample_counts = sample_training_pixels(
        train_samples, args.width, args.height
    )
    print(
        f"training matrix {x.shape}, positives={int(y.sum())}, "
        f"elapsed={time.monotonic() - start:.1f}s",
        flush=True,
    )
    scaler, candidates = train_models(x, y)

    dev_results = {}
    best = None
    for name, model in candidates:
        print(f"evaluating {name} on development blocks", flush=True)
        rows = predictions_for_samples(
            model, scaler, dev_samples, args.width, args.height
        )
        threshold = choose_threshold(rows)
        raw = compute_metrics(rows, threshold, apply_postprocess=False)
        post = compute_metrics(rows, threshold, apply_postprocess=True)
        dev_results[name] = {
            "threshold": threshold,
            "raw": asdict(raw),
            "postprocessed": asdict(post),
            "trainingIterations": int(getattr(model, "n_iter_", 0)),
            "trainingLoss": float(getattr(model, "loss_", 0.0)),
        }
        score = (
            post.tolerant_f1
            + 0.35 * post.pixel_iou
            + 0.20 * post.empty_specificity
            + 0.10 * post.presence_accuracy
        )
        if isinstance(model, MLPClassifier) and (best is None or score > best[0]):
            best = (score, name, model, threshold)

    print("evaluating fixed RGB bootstrap baseline", flush=True)
    fixed_dev_rows = predictions_for_samples(
        "fixed", None, dev_samples, args.width, args.height
    )
    dev_results["fixed_rgb_bootstrap"] = {
        "threshold": 0.5,
        "raw": asdict(compute_metrics(fixed_dev_rows, 0.5, False)),
        "postprocessed": asdict(compute_metrics(fixed_dev_rows, 0.5, True)),
    }

    if best is None:
        raise RuntimeError("No deployable MLP candidate was trained")
    _, best_name, best_model, best_threshold = best
    print(f"selected {best_name} at threshold {best_threshold:.4f}", flush=True)

    print("one-time evaluation on unseen source holdout", flush=True)
    test_rows = predictions_for_samples(
        best_model, scaler, test_samples, args.width, args.height
    )
    fixed_test_rows = predictions_for_samples(
        "fixed", None, test_samples, args.width, args.height
    )
    test_results = {
        best_name: {
            "raw": asdict(compute_metrics(test_rows, best_threshold, False)),
            "postprocessed": asdict(
                compute_metrics(test_rows, best_threshold, True)
            ),
        },
        "fixed_rgb_bootstrap": {
            "raw": asdict(compute_metrics(fixed_test_rows, 0.5, False)),
            "postprocessed": asdict(compute_metrics(fixed_test_rows, 0.5, True)),
        },
    }

    weights = folded_weights(best_model, scaler)
    weights["probabilityThreshold"] = best_threshold
    weights["selectedModel"] = best_name
    weights["randomSeed"] = RANDOM_SEED
    (args.output / "route_segmenter_weights.json").write_text(
        json.dumps(weights, indent=2)
    )
    write_swift_weights(
        weights, best_threshold, args.output / "LearnedRouteSegmenterWeights.swift"
    )
    save_visualizations(
        test_rows, best_threshold, args.output / "source_holdout_predictions"
    )

    report = {
        "datasetAudit": audit,
        "trainingSampling": sample_counts,
        "selectedModel": best_name,
        "development": dev_results,
        "sourceHoldoutTest": test_results,
        "elapsedSeconds": time.monotonic() - start,
    }
    (args.output / "training_report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
