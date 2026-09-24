#!/usr/bin/env python3
"""Train a component-level verifier for ambiguous short yellow routes."""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage
from sklearn.metrics import precision_recall_fscore_support, roc_auc_score
from sklearn.neural_network import MLPClassifier
from sklearn.preprocessing import StandardScaler

import train_route_segmenter as route_training


RANDOM_SEED = 322569
DEPLOYMENT_ACCEPTANCE_THRESHOLD = 0.45
MAXIMUM_WHITE_ENDPOINT_FRACTION = 0.055


@dataclass
class CandidateRow:
    sample_id: str
    numeric_id: int
    role: str
    label: int
    overlap_fraction: float
    features: list[float]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", type=Path)
    parser.add_argument("output", type=Path)
    return parser.parse_args()


def candidate_rows_for_sample(
    sample: route_training.Sample,
    role: str,
) -> list[CandidateRow]:
    rgb = np.asarray(Image.open(sample.image_path).convert("RGB"), np.float32) / 255.0
    truth = np.asarray(Image.open(sample.mask_path).convert("L"), np.uint8) > 127
    anchor = route_training.player_anchor(rgb)
    if anchor is None:
        return []

    height, width = truth.shape
    dimension = float(min(width, height))
    pixel_count = width * height
    raw = route_training.fixed_threshold_probability(rgb) >= 0.5
    yy, xx = np.mgrid[0:height, 0:width]
    near_player = np.hypot(xx - anchor[0], yy - anchor[1]) <= dimension * 0.24
    closing_radius = max(2, int(round(dimension * 0.009)))
    closed = ndimage.binary_closing(
        raw & near_player,
        structure=np.ones((2 * closing_radius + 1, 2 * closing_radius + 1), bool),
    )
    component_labels, component_count = ndimage.label(
        closed, structure=np.ones((3, 3), np.uint8)
    )
    cyan = (
        (rgb[:, :, 1] >= 148 / 255)
        & (rgb[:, :, 2] >= 148 / 255)
        & ((np.minimum(rgb[:, :, 1], rgb[:, :, 2]) - rgb[:, :, 0]) >= 41 / 255)
    )
    rows: list[CandidateRow] = []

    for component_value in range(1, component_count + 1):
        component = component_labels == component_value
        ys, xs = np.nonzero(component)
        area = len(xs)
        if area < max(10, int(pixel_count * 0.00008)):
            continue
        distances = np.hypot(xs - anchor[0], ys - anchor[1])
        span_x = int(xs.max() - xs.min() + 1)
        span_y = int(ys.max() - ys.min() + 1)
        maximum_span = max(span_x, span_y)
        minor_span = min(span_x, span_y)
        radial_reach = float(distances.max() - distances.min())
        if (
            distances.min() > dimension * 0.20
            or maximum_span < dimension * 0.020
            or radial_reach < dimension * 0.010
        ):
            continue

        points = np.column_stack([xs, ys]).astype(np.float64)
        covariance = np.cov(points.T) if area > 1 else np.zeros((2, 2))
        eigenvalues = np.linalg.eigvalsh(covariance)
        elongation = float((eigenvalues[-1] + 0.001) / (eigenvalues[0] + 0.001))
        centroid_x = float(xs.mean())
        centroid_y = float(ys.mean())
        delta_x = (centroid_x - anchor[0]) / dimension
        delta_y = (centroid_y - anchor[1]) / dimension
        angle = math.atan2(delta_y, delta_x)
        boundary = component & ~ndimage.binary_erosion(
            component, structure=np.ones((3, 3), bool)
        )
        component_rgb = rgb[component]
        mean_rgb = component_rgb.mean(axis=0)
        std_rgb = component_rgb.std(axis=0)
        yellow_margin = np.minimum(component_rgb[:, 0], component_rgb[:, 1]) - component_rgb[:, 2]
        farthest_index = int(np.argmax(distances))
        far_x = int(xs[farthest_index])
        far_y = int(ys[farthest_index])
        far_region = (
            (xx - far_x) * (xx - far_x) + (yy - far_y) * (yy - far_y)
        ) <= (dimension * 0.065) ** 2
        far_rgb = rgb[far_region]
        far_max = far_rgb.max(axis=1)
        far_min = far_rgb.min(axis=1)
        far_saturation = (far_max - far_min) / np.maximum(far_max, 1e-5)
        white_far_fraction = float(np.mean((far_max >= 0.68) & (far_saturation <= 0.28)))

        expanded = ndimage.binary_dilation(component, iterations=3)
        cyan_adjacency = float(np.mean(cyan[expanded]))
        overlap = int(np.count_nonzero(component & truth))
        overlap_fraction = overlap / max(area, 1)
        truth_coverage = overlap / max(int(truth.sum()), 1)
        label = int(overlap_fraction >= 0.30 or truth_coverage >= 0.12)

        features = [
            math.log1p(area) / 10.0,
            area / pixel_count * 1000.0,
            maximum_span / dimension,
            minor_span / dimension,
            area / max(span_x * span_y, 1),
            math.log1p(elongation) / 6.0,
            float(distances.min()) / dimension,
            float(distances.max()) / dimension,
            radial_reach / dimension,
            delta_x,
            delta_y,
            math.cos(angle),
            math.sin(angle),
            float(boundary.sum()) / max(math.sqrt(area), 1.0) / 10.0,
            float(mean_rgb[0]),
            float(mean_rgb[1]),
            float(mean_rgb[2]),
            float(std_rgb[0]),
            float(std_rgb[1]),
            float(std_rgb[2]),
            float(yellow_margin.mean()),
            white_far_fraction,
            cyan_adjacency,
        ]
        rows.append(
            CandidateRow(
                sample_id=sample.sample_id,
                numeric_id=sample.numeric_id,
                role=role,
                label=label,
                overlap_fraction=overlap_fraction,
                features=features,
            )
        )
    return rows


def folded_weights(model: MLPClassifier, scaler: StandardScaler) -> dict:
    first = model.coefs_[0].astype(np.float64)
    folded_first = first / scaler.scale_[:, None]
    folded_bias = model.intercepts_[0] - (scaler.mean_ / scaler.scale_) @ first
    return {
        "formatVersion": 1,
        "featureCount": int(first.shape[0]),
        "hiddenCount": int(first.shape[1]),
        "firstWeightsInputMajor": folded_first.astype(np.float32).reshape(-1).tolist(),
        "firstBias": folded_bias.astype(np.float32).tolist(),
        "outputWeights": model.coefs_[1].astype(np.float32).reshape(-1).tolist(),
        "outputBias": float(model.intercepts_[1][0]),
    }


def metrics(y: np.ndarray, probability: np.ndarray, threshold: float) -> dict:
    prediction = probability >= threshold
    precision, recall, f1, _ = precision_recall_fscore_support(
        y, prediction, average="binary", zero_division=0
    )
    return {
        "threshold": threshold,
        "precision": float(precision),
        "recall": float(recall),
        "f1": float(f1),
        "specificity": float(np.mean(~prediction[y == 0])) if np.any(y == 0) else 0,
        "auc": float(roc_auc_score(y, probability)) if len(np.unique(y)) > 1 else 0,
        "falsePositiveCount": int(np.count_nonzero(prediction & (y == 0))),
        "falseNegativeCount": int(np.count_nonzero(~prediction & (y == 1))),
    }


def write_swift(payload: dict, path: Path) -> None:
    def array(values) -> str:
        values = [float(value) for value in values]
        return ",\n".join(
            "        " + ", ".join(f"{value:.9g}" for value in values[i : i + 8])
            for i in range(0, len(values), 8)
        )

    path.write_text(
        f'''import Foundation

// Generated by Training/train_route_component_classifier.py.
nonisolated enum RouteComponentVerifierWeights {{
    static let featureCount = {payload["featureCount"]}
    static let hiddenCount = {payload["hiddenCount"]}
    static let acceptanceThreshold: Float = {payload["acceptanceThreshold"]:.9g}
    static let maximumWhiteEndpointFraction: Float = {payload["maximumWhiteEndpointFraction"]:.9g}
    static let firstWeights: [Float] = [
{array(payload["firstWeightsInputMajor"])}
    ]
    static let firstBias: [Float] = [
{array(payload["firstBias"])}
    ]
    static let outputWeights: [Float] = [
{array(payload["outputWeights"])}
    ]
    static let outputBias: Float = {payload["outputBias"]:.9g}
}}
'''
    )


def main() -> None:
    args = parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    samples = route_training.load_samples(args.dataset)
    train_samples, development_samples, source_holdout = route_training.assign_roles(samples)
    roles = {
        sample.sample_id: "train" for sample in train_samples
    } | {
        sample.sample_id: "development" for sample in development_samples
    } | {
        sample.sample_id: "sourceHoldout" for sample in source_holdout
    }

    rows: list[CandidateRow] = []
    for index, sample in enumerate(samples, start=1):
        rows.extend(candidate_rows_for_sample(sample, roles[sample.sample_id]))
        if index % 60 == 0 or index == len(samples):
            print(f"component extraction {index}/{len(samples)} rows={len(rows)}", flush=True)

    fit_rows = [row for row in rows if row.role == "train"]
    development_rows = [row for row in rows if row.role == "development"]
    test_rows = [row for row in rows if row.role == "sourceHoldout"]
    x = np.asarray([row.features for row in fit_rows], np.float32)
    y = np.asarray([row.label for row in fit_rows], np.uint8)
    scaler = StandardScaler()
    x_scaled = scaler.fit_transform(x)
    positive_count = int(y.sum())
    negative_count = len(y) - positive_count
    sample_weight = np.where(
        y == 1,
        len(y) / max(2 * positive_count, 1),
        len(y) / max(2 * negative_count, 1),
    )
    model = MLPClassifier(
        hidden_layer_sizes=(12,),
        activation="relu",
        alpha=0.001,
        batch_size=min(256, len(y)),
        learning_rate_init=0.003,
        max_iter=350,
        early_stopping=True,
        validation_fraction=0.18,
        n_iter_no_change=18,
        random_state=RANDOM_SEED,
    )
    model.fit(x_scaled, y, sample_weight=sample_weight)

    development_x = scaler.transform(
        np.asarray([row.features for row in development_rows], np.float32)
    )
    development_y = np.asarray([row.label for row in development_rows], np.uint8)
    development_probability = model.predict_proba(development_x)[:, 1]
    best_threshold = 0.5
    best_score = -1.0
    for threshold in np.linspace(0.30, 0.98, 100):
        current = metrics(development_y, development_probability, float(threshold))
        score = current["f1"] + 0.25 * current["specificity"] + 0.10 * current["precision"]
        if score > best_score:
            best_score = score
            best_threshold = float(threshold)

    test_x = scaler.transform(np.asarray([row.features for row in test_rows], np.float32))
    test_y = np.asarray([row.label for row in test_rows], np.uint8)
    test_probability = model.predict_proba(test_x)[:, 1]
    report = {
        "rowCounts": {
            "train": len(fit_rows),
            "development": len(development_rows),
            "sourceHoldout": len(test_rows),
        },
        "classCounts": {
            "trainPositive": positive_count,
            "trainNegative": negative_count,
            "developmentPositive": int(development_y.sum()),
            "developmentNegative": int(len(development_y) - development_y.sum()),
            "sourceHoldoutPositive": int(test_y.sum()),
            "sourceHoldoutNegative": int(len(test_y) - test_y.sum()),
        },
        "development": metrics(development_y, development_probability, best_threshold),
        "sourceHoldout": metrics(test_y, test_probability, best_threshold),
        "sourceHoldoutPredictions": [
            {
                "sampleID": row.sample_id,
                "label": row.label,
                "probability": float(probability),
            }
            for row, probability in zip(test_rows, test_probability)
        ],
        "knownHardNegatives": [
            {
                "sampleID": row.sample_id,
                "role": row.role,
                "probability": float(model.predict_proba(
                    scaler.transform(np.asarray([row.features], np.float32))
                )[0, 1]),
            }
            for row in rows
            if row.numeric_id in {52, 308, 520, 521} and row.label == 0
        ],
        "deploymentPolicy": {
            "acceptanceThreshold": DEPLOYMENT_ACCEPTANCE_THRESHOLD,
            "maximumWhiteEndpointFraction": MAXIMUM_WHITE_ENDPOINT_FRACTION,
            "purpose": (
                "Frame-level short-route recovery after normal geometry fails; "
                "the white-endpoint gate blocks reviewed objective-ring and "
                "bottom-HUD connector negatives without running the full "
                "segmentation fallback."
            ),
        },
    }
    payload = folded_weights(model, scaler)
    payload["acceptanceThreshold"] = DEPLOYMENT_ACCEPTANCE_THRESHOLD
    payload["maximumWhiteEndpointFraction"] = MAXIMUM_WHITE_ENDPOINT_FRACTION
    (args.output / "route_component_verifier_weights.json").write_text(
        json.dumps(payload, indent=2)
    )
    (args.output / "route_component_verifier_report.json").write_text(
        json.dumps(report, indent=2)
    )
    write_swift(
        payload,
        args.output / "RouteComponentVerifierWeights.swift",
    )
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
