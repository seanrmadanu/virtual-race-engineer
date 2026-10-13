"""Human-gated structured training. All inputs must be development recordings."""
import argparse
from collections import Counter
import json
from pathlib import Path
import numpy as np
from snapshot import digest
from temporal import CLASSES, FEATURES, TemporalNetwork, features


def reviewed_intervals(bundle, feedback):
    if bundle['schemaVersion'] != 'racing-trainer-review-v2' or feedback['schemaVersion'] != 'racing-trainer-feedback-v2':
        raise ValueError('Version 2 pilot and feedback required.')
    for feedback_key, expected in [('sourceSHA256', bundle['source']['sha256']),
                                   ('modelSHA256', bundle['modelSHA256']), ('predictionsSHA256', bundle['predictionsSHA256'])]:
        if feedback.get(feedback_key) != expected:
            raise ValueError('Feedback identity does not match the pilot.')
    notes = [note for note in feedback['notes'] if note['category'] == 'slowdown_timing']
    by_id = {note['eventID']: note for note in notes}
    if len(by_id) != len(notes) or len(bundle['events']) < 30:
        raise ValueError('Need the full 30-event pilot without duplicate reviews.')
    intervals = []
    for event in bundle['events']:
        note = by_id.get(event['id'], {})
        if not note.get('reviewed') or not note.get('reviewer', '').strip() or note.get('time') != event['time'] or note.get('verdict') == 'pending':
            raise ValueError(f'Human review required for {event["id"]}. Training stopped.')
        if note.get('origin') != 'human_after_model_output' or note.get('sawModelAnswers') is not True:
            raise ValueError('Unsupported review provenance.')
        label = note.get('slowdown', {})
        action = label.get('action')
        if action in ['uncertain', 'cannot_judge'] or note['verdict'] in ['unclear', 'unusable']:
            continue
        if action not in CLASSES:
            raise ValueError('Missing explicit human action label.')
        start, end = float(label['start']), float(label['end'])
        if not np.isfinite([start, end]).all() or not 0 <= start <= end < bundle['source']['duration']:
            raise ValueError('Invalid reviewed timing interval.')
        if not start - 10 <= event['time'] <= end + 10:
            raise ValueError('Interval is too far from its reviewed event; review a closer timestamp.')
        intervals.append((start, end, action, event['id']))
    for index, (start, end, action, _) in enumerate(intervals):
        for other_start, other_end, other_action, _ in intervals[index+1:]:
            if max(start, other_start) <= min(end, other_end) and action != other_action:
                raise ValueError('Conflicting action labels overlap.')
    return intervals


def train(config_path, output):
    config = json.loads(config_path.read_text())
    group_splits = {}; datasets = {'train': [], 'validation': []}; provenance = []
    for item in config['sources']:
        split, group = item['split'], item['sourceGroup']
        if split not in datasets or not group:
            raise ValueError('Only explicit train/validation groups are accepted. Do not load final-test footage.')
        if group in group_splits and group_splits[group] != split:
            raise ValueError('Source-group leakage across splits.')
        group_splits[group] = split
        bundle = json.loads(Path(item['bundle']).read_text())
        feedback = json.loads(Path(item['feedback']).read_text())
        intervals = reviewed_intervals(bundle, feedback)  # Gate before reading features or creating output.
        trace = Path(item['trace'])
        if digest(trace) != bundle['predictionsSHA256']:
            raise ValueError('Trace changed after review.')
        # Exact copies must not cross splits, even if a supplied group name differs.
        source = bundle['source']['sha256']
        if source in group_splits and group_splits[source] != split:
            raise ValueError('Identical source appears in both splits.')
        group_splits[source] = split
        for line in trace.open():
            row = json.loads(line)
            matches = [interval for interval in intervals if interval[0] - 1e-8 <= row['time'] <= interval[1] + 1e-8]
            if matches:
                datasets[split].append((features(row['history']), CLASSES.index(matches[0][2])))
        provenance.append({'source': source, 'sourceGroup': group, 'split': split, 'bundleHash': digest(Path(item['bundle'])),
                           'feedbackHash': digest(Path(item['feedback'])), 'traceHash': digest(trace)})
    if any(not values for values in datasets.values()):
        raise ValueError('Need reviewed examples from separate source recordings for training and validation.')
    class_counts = Counter(label for _, label in datasets['train'])
    if any(class_counts[index] < 2 for index in range(len(CLASSES))):
        raise ValueError('Pilot lacks reviewed examples for each action. Do not fill gaps with automatic labels.')
    if output.exists():
        raise ValueError('Output exists; choose a new model directory.')
    x, y = zip(*datasets['train']); model = TemporalNetwork()
    loss = model.fit(np.stack(x), np.array(y))
    validation_x, validation_y = zip(*datasets['validation'])
    probabilities, _ = model.forward(np.stack(validation_x))
    output.mkdir(parents=True, exist_ok=False)
    np.savez(output / 'weights.npz', **model.params)
    np.savez(output / 'parity_inputs.npz', x=np.stack(validation_x), probabilities=probabilities)
    card = dict(schema='structured-slowdown-v1', status='experimental_shadow_only', trainedFrom='new_random_weights',
        architecture='causal_conv3_tanh_meanpool_softmax', features=FEATURES, classes=CLASSES,
        observations='actual_module_outputs_including_missingness', sourceGroups=provenance,
        finalTrainingLoss=loss, developmentValidationFrameAccuracy=float((probabilities.argmax(1) == validation_y).mean()),
        confidence='uncalibrated_class_scores', liveEnabled=False,
        limitations=['Small pilot is not an accuracy study', 'Post-output reviews are not blind ground truth',
                     'No event-level superiority or deployment qualification claimed'])
    (output / 'model.json').write_text(json.dumps(card, indent=2) + '\n')
    print(f'Saved experimental model to {output}; learned live cues remain disabled.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('config', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        train(args.config, args.output)
    except (ValueError, KeyError, FileNotFoundError) as error:
        parser.exit(2, f'TRAINING BLOCKED: {error}\n')
