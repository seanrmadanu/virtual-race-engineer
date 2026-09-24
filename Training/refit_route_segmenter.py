#!/usr/bin/env python3
"""Refit the selected route model after the source-holdout audit.

The first model-selection pass remains in training_report.json. This refit
adds the newer Motorfest recording to model fitting while keeping the 108
legacy temporal-development frames out for probability calibration.
"""

from __future__ import annotations

import argparse
import json
import time
from dataclasses import asdict
from pathlib import Path

import numpy as np
from sklearn.neural_network import MLPClassifier
from sklearn.preprocessing import StandardScaler

import train_route_segmenter as training


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", type=Path)
    parser.add_argument("output", type=Path)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    samples = training.load_samples(args.dataset)
    train_samples, development_samples, source_holdout = training.assign_roles(samples)
    fit_samples = sorted(
        train_samples + source_holdout, key=lambda sample: sample.numeric_id
    )

    started = time.monotonic()
    x, y, sampling = training.sample_training_pixels(
        fit_samples, training.MODEL_WIDTH, training.MODEL_HEIGHT
    )
    scaler = StandardScaler(copy=False)
    x_scaled = scaler.fit_transform(x)
    positives = int(y.sum())
    negatives = len(y) - positives
    sample_weights = np.where(
        y == 1,
        len(y) / max(2 * positives, 1),
        len(y) / max(2 * negatives, 1),
    ).astype(np.float32)

    print(
        f"refit matrix {x.shape}; fitting MLP-20 on {len(fit_samples)} frames",
        flush=True,
    )
    model = MLPClassifier(
        hidden_layer_sizes=(20,),
        activation="relu",
        solver="adam",
        alpha=0.00025,
        batch_size=2048,
        learning_rate_init=0.002,
        max_iter=58,
        early_stopping=True,
        validation_fraction=0.12,
        n_iter_no_change=7,
        random_state=training.RANDOM_SEED + 220,
        verbose=False,
    )
    model.fit(x_scaled, y, sample_weight=sample_weights)

    print("calibrating on held-out temporal development blocks", flush=True)
    development_rows = training.predictions_for_samples(
        model,
        scaler,
        development_samples,
        training.MODEL_WIDTH,
        training.MODEL_HEIGHT,
    )
    threshold = training.choose_threshold(development_rows)
    raw_metrics = training.compute_metrics(
        development_rows, threshold, apply_postprocess=False
    )
    postprocessed_metrics = training.compute_metrics(
        development_rows, threshold, apply_postprocess=True
    )

    weights = training.folded_weights(model, scaler)
    weights["probabilityThreshold"] = threshold
    weights["selectedModel"] = "mlp_20_color_augmented_source_refit"
    weights["randomSeed"] = training.RANDOM_SEED + 220
    (args.output / "route_segmenter_weights.json").write_text(
        json.dumps(weights, indent=2)
    )
    training.write_swift_weights(
        weights,
        threshold,
        args.output / "LearnedRouteSegmenterWeights.swift",
    )
    training.save_visualizations(
        development_rows,
        threshold,
        args.output / "development_predictions",
        count=24,
    )

    report = {
        "purpose": "deployment refit after the source-holdout audit",
        "fitFrameCount": len(fit_samples),
        "calibrationFrameCount": len(development_samples),
        "fitIncludesFormerSourceHoldout": True,
        "sampling": sampling,
        "threshold": threshold,
        "trainingIterations": int(model.n_iter_),
        "trainingLoss": float(model.loss_),
        "developmentRaw": asdict(raw_metrics),
        "developmentPostprocessed": asdict(postprocessed_metrics),
        "elapsedSeconds": time.monotonic() - started,
    }
    (args.output / "deployment_refit_report.json").write_text(
        json.dumps(report, indent=2)
    )
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
