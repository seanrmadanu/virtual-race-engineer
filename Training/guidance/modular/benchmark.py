"""Event timing metrics and separate confidence bins. No agreement-as-truth metric."""
import argparse
import json
import math
from pathlib import Path


def confidence_bins(samples):
    """Call separately per module/target; each sample needs an independent correctness label."""
    bins = []
    for index in range(5):
        lower, upper = index / 5, (index + 1) / 5
        group = [item for item in samples if lower <= item['score'] <= upper and
                 (index == 4 or item['score'] < upper)]
        bins.append({'lower': lower, 'upper': upper, 'count': len(group),
                     'meanScore': sum(item['score'] for item in group) / len(group) if group else None,
                     'observedErrorRate': sum(not item['correct'] for item in group) / len(group) if group else None})
    return bins


def event_metrics(predictions, references, early_late_tolerance=2):
    """Predictions are cue onsets, not repeated 10-Hz state rows.

    References include reviewed no-cue windows. Unannotated predictions are unscored.
    Match a reference once, using only the same action. Report abstention separately.
    """
    used = set(); matched = []; false = 0; unscored = 0; abstained = 0
    for prediction in sorted(predictions, key=lambda item: item['time']):
        time, cue = prediction['time'], prediction['cue']
        if not math.isfinite(time):
            raise ValueError('Nonfinite cue timestamp.')
        if cue == 'cannot_judge':
            abstained += 1; continue
        if cue == 'no_cue':
            continue
        choices = []
        for index, reference in enumerate(references):
            if index in used or reference['action'] != cue:
                continue
            start, end = reference['start'], reference['end']
            error = time - start if time < start else time - end if time > end else 0
            if abs(error) <= early_late_tolerance:
                choices.append((abs(error), index, error))
        if choices:
            _, index, error = min(choices); used.add(index); matched.append(error)
        elif any(reference['start'] - early_late_tolerance <= time <= reference['end'] + early_late_tolerance
                 for reference in references):
            false += 1
        else:
            unscored += 1
    positive = sum(reference['action'] != 'no_cue' for reference in references)
    return {'referenceCueEvents': positive, 'onTime': matched.count(0),
            'early': sum(value < 0 for value in matched), 'late': sum(value > 0 for value in matched),
            'missed': positive - len(used), 'falseCuesInReviewedWindows': false,
            'timingErrorsSeconds': matched, 'abstainedOnsets': abstained, 'unscoredOutsideReviewedWindows': unscored}


def compare(payload):
    if payload.get('schema') != 'modular-benchmark-v1' or not payload.get('sourceSHA256') or not payload.get('reviewer'):
        raise ValueError('Identified recording and reviewed reference intervals required.')
    references = payload['references']
    for item in references:
        if not all(math.isfinite(item[key]) for key in ['start', 'end']) or not 0 <= item['start'] <= item['end']:
            raise ValueError('Invalid reviewed timing interval.')
    systems = payload['systems']
    if len(systems) < 2:
        raise ValueError('Compare at least two systems on identical decision timestamps.')
    timestamps = None; report = {}
    for name, rows in systems.items():
        current = [row['time'] for row in rows]
        if current != sorted(set(current)) or (timestamps is not None and current != timestamps):
            raise ValueError('Systems did not run on identical unique ordered decision timestamps.')
        timestamps = current
        onsets = []; previous = None
        for row in rows:
            if row['cue'] != previous:
                onsets.append(row)
            previous = row['cue']
        metrics = event_metrics(onsets, references)
        reviewed_rows = [row for row in rows if any(ref['start'] <= row['time'] <= ref['end'] for ref in references)]
        metrics['answerCoverageInReviewedWindows'] = (sum(row['cue'] != 'cannot_judge' for row in reviewed_rows) / len(reviewed_rows)) if reviewed_rows else None
        report[name] = metrics
    return {'schema': 'modular-benchmark-results-v1', 'sourceSHA256': payload['sourceSHA256'], 'systems': report,
            'referenceProvenance': payload.get('referenceProvenance', 'post_output_review_not_blind'),
            'qualification': 'Not a release gate by itself. Needs held-out recordings and safety/shadow review.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('input', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args()
    result = compare(json.loads(args.input.read_text()))
    with args.output.open('x') as stream: json.dump(result, stream, indent=2)
