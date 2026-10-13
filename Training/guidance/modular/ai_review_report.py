"""Validate a separate AI review and prepare a non-training handoff for another reviewer.

The tool validates provenance and evidence integrity, not the correctness of AI labels.
It never writes human feedback, model weights, or app state.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inside(root, relative):
    if not isinstance(relative, str) or Path(relative).is_absolute():
        raise ValueError('Evidence path must be relative')
    resolved = (root / relative).resolve()
    if not resolved.is_relative_to(root.resolve()):
        raise ValueError('Evidence path escapes review directory')
    return resolved


def validate(review, bundle, evidence, review_root):
    if (review.get('schemaVersion') != 'racing-trainer-ai-review-v1'
            or review.get('reviewerType') != 'ai'
            or review.get('origin') != 'ai_after_model_output'
            or review.get('sawModelAnswers') is not True
            or review.get('humanApproved') is not False
            or review.get('trainingEligible') is not False
            or not review.get('reviewer', '').strip()):
        raise ValueError('AI provenance must stay explicit and unapproved')
    if evidence.get('schemaVersion') != 'racing-trainer-ai-evidence-v1':
        raise ValueError('Unsupported evidence schema')
    identities = {'sourceSHA256': bundle['source']['sha256'], 'modelSHA256': bundle['modelSHA256'],
                  'predictionsSHA256': bundle['predictionsSHA256'], 'bundleSHA256': review['bundleSHA256']}
    for key, expected in identities.items():
        if review.get(key) != expected or evidence.get(key) != expected:
            raise ValueError('Review/evidence identity mismatch')
    expected_events = {e['id']: e['time'] for e in bundle['events']}
    records = review['events']
    evidence_events = {e['eventID']: e for e in evidence['events']}
    if (len(expected_events) != len(bundle['events']) or len(records) != len(expected_events)
            or len({r['eventID'] for r in records}) != len(records)
            or set(r['eventID'] for r in records) != set(expected_events)
            or set(evidence_events) != set(expected_events)
            or len(evidence_events) != len(evidence['events'])):
        raise ValueError('Need exactly one AI review and evidence record per pilot event')
    evidence_root = inside(review_root, review['evidenceManifest']).parent
    for record in records:
        event_id, time = record['eventID'], record['time']
        if (time != expected_events[event_id] or record.get('reviewed') is not True
                or record.get('confidence') not in ['low', 'medium', 'high']
                or not record.get('observation', '').strip() or not record.get('followUp', '').strip()):
            raise ValueError('Incomplete review or incorrect event timestamp')
        direction, target = record.get('direction'), record.get('target')
        valid_pair = ((direction == 'unknown' and target == 'unknown')
                      or (direction == 'straight' and target == 'straight_segment')
                      or (direction in ['left', 'right'] and target in ['current_corner', 'next_corner']))
        if not valid_pair or record.get('basicVerdict') not in ['correct', 'wrong', 'unclear', 'unusable']:
            raise ValueError('Invalid basic-turn review')
        if record.get('cueVerdict') not in ['appropriate_abstention', 'supported_content_timing_unverified',
                'needs_timing_review', 'unnecessary_corner_warning', 'missed_visible_route_cue']:
            raise ValueError('Invalid cue assessment')
        if record.get('proposedAction') not in ['advance_warning', 'lift', 'brake', 'no_cue', 'cannot_judge', 'uncertain']:
            raise ValueError('Invalid action proposal')
        speed = record.get('speedKmh')
        if speed is not None and (not isinstance(speed, (int, float)) or not math.isfinite(speed) or speed < 0):
            raise ValueError('Invalid visible HUD reading')
        window = record.get('candidateWindow')
        if window is not None:
            if (not isinstance(window, list) or len(window) != 2
                    or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in window)
                    or not max(0, time - 2) <= window[0] <= window[1] <= time
                    or record['proposedAction'] in ['uncertain', 'cannot_judge']):
                raise ValueError('Candidate window must stay within inspected causal history')
        item = evidence_events[event_id]
        if item['time'] != time or len(item['frames']) != 4:
            raise ValueError('Incorrect visual evidence window')
        previous = -math.inf
        for frame in item['frames']:
            pts = frame['sourceTime']
            if not math.isfinite(pts) or not max(0, time - 2) - .05 <= pts <= time or pts <= previous:
                raise ValueError('Future or unordered evidence frame')
            previous = pts
            if digest(inside(evidence_root, frame['path'])) != frame['sha256']:
                raise ValueError('Evidence frame fingerprint mismatch')
        if digest(inside(evidence_root, item['contactSheet'])) != item['contactSheetSHA256']:
            raise ValueError('Contact sheet fingerprint mismatch')


def timestamp(seconds):
    return f'{int(seconds) // 60:02d}:{int(seconds) % 60:02d}'


def build(review_path, bundle_path, output):
    review = json.loads(review_path.read_text())
    bundle = json.loads(bundle_path.read_text())
    if digest(bundle_path) != review['bundleSHA256']:
        raise ValueError('Frozen pilot fingerprint mismatch')
    evidence_path = inside(review_path.parent, review['evidenceManifest'])
    evidence = json.loads(evidence_path.read_text())
    validate(review, bundle, evidence, review_path.parent)
    model_events = {e['id']: e for e in bundle['events']}
    evidence_events = {e['eventID']: e for e in evidence['events']}
    # Preserve existing work. A second reviewer must use a separate directory/file.
    output.mkdir(parents=True, exist_ok=False)
    action_counts = dict(Counter(r['proposedAction'] for r in review['events']))
    summary = {'schemaVersion': 'racing-trainer-ai-review-report-v1',
               'reviewer': review['reviewer'], 'reviewSetID': review['reviewSetID'],
               'reviewSHA256': digest(review_path), 'evidenceManifestSHA256': digest(evidence_path),
               'bundleSHA256': digest(bundle_path), 'eventsInspected': len(review['events']),
               'framesInspected': sum(len(e['frames']) for e in evidence['events']),
               'proposedActionCounts': action_counts, 'integrityChecksPassed': True,
               'labelAccuracyVerified': False, 'humanApproved': False, 'trainingEligible': False}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    # Snapshot references only; not a merge into an existing human feedback journal.
    comparisons = []
    for row in review['events']:
        model = model_events[row['eventID']]
        comparisons.append({'aiReview': row, 'frozenPipelineOutput': model,
                            'viewedEvidence': evidence_events[row['eventID']]})
    (output / 'comparison.json').write_text(json.dumps({**summary, 'events': comparisons}, indent=2) + '\n')
    template = {k: review[k] for k in ['sourceSHA256', 'modelSHA256', 'predictionsSHA256', 'bundleSHA256']}
    template.update(schemaVersion='racing-trainer-ai-verification-template-v1',
        reviewer='Claude — AI verification', reviewerType='ai', humanApproved=False, trainingEligible=False,
        verifiesReviewSetID=review['reviewSetID'], verifiesReviewSHA256=digest(review_path),
        sawCodexReviews=None, sawModelAnswers=None,
        events=[{'eventID': r['eventID'], 'time': r['time'], 'reviewed': False,
                 'verdict': 'pending', 'observation': '', 'proposedDirection': None,
                 'proposedTarget': None, 'proposedAction': None, 'candidateWindow': None,
                 'viewedFrameTimes': [], 'disagreementWithCodex': None} for r in review['events']])
    (output / 'claude.review.template.json').write_text(json.dumps(template, indent=2) + '\n')
    lines = [f'# {review["reviewer"]}', '',
             '30 pilot moments inspected using 120 sampled frames. This is an AI preliminary review, not approved training data.', '',
             '## Give Claude this task', '',
             'Review the same 30 events from Video 2. Use the original recording and the evidence manifest. ',
             'Write a separate review named **Claude — AI verification**. Start with the blank template in this folder. ',
             'If possible, inspect the footage before reading Codex conclusions. Then compare each event and record disagreements. ',
             'State whether Codex/model answers were visible. Do not claim a blind or independent test after reading them. ',
             'Do not edit Codex files, the frozen pilot, Sean\'s review journal, or model weights. Do not train. ',
             'Use uncertain when the footage cannot establish a control action or useful timing window.', '',
             '## Final human review', '',
             'Sean makes the final review in the existing app under his own name. Keep all three authors separate. ',
             'AI agreement is not approval. Preserve disagreements and the final human decision. ',
             'This separate AI schema is deliberately rejected by the trainer and is not loaded into the app\'s human-review journal. ',
             'Do not rename an AI file or change its origin to make it trainable. Approved intervals still need separate recording groups, ',
             'all action classes, validation, and deployment checks.', '',
             '## Evidence and limits', '', review['method'], '', review['scope'], '', review['windowMeaning'], '',
             'Visible HUD readings below are from the event frame. Frozen module values may come from earlier capturedAt timestamps. ',
             'A difference is not an OCR error until both readings are checked on the same source frame.', '',
             f'Candidate labels: {action_counts}. No brake or lift interval was approved.', '',
             f'- Source: `{bundle["source"]["filename"]}` / `{review["sourceSHA256"]}`',
             f'- Review fingerprint: `{summary["reviewSHA256"]}`',
             f'- Evidence manifest: [manifest](<{evidence_path.resolve()}>)',
             f'- Full AI review: [codex.review.json](<{review_path.resolve()}>)', '',
             '## Timestamp review', '',
             '| Time | Frozen pipeline | Codex observation | Visible HUD km/h | Candidate action |',
             '| --- | --- | --- | ---: | --- |']
    for row in review['events']:
        model = model_events[row['eventID']]
        lines.append(f'| {timestamp(row["time"])} | {model["direction"]} / {model["target"]}; {model["diagnostics"]["cue"]} '
                     f'| {row["direction"]} / {row["target"]} | {row["speedKmh"]} | {row["proposedAction"]} |')
    for row in review['events']:
        item = evidence_events[row['eventID']]
        sheet = evidence_path.parent / item['contactSheet']
        lines += ['', f'### {timestamp(row["time"])} · {row["eventID"]}', '',
                  f'Observation confidence: **{row["confidence"]}**. Basic verdict: **{row["basicVerdict"]}**. ',
                  f'Cue assessment: **{row["cueVerdict"]}**. Candidate window: `{row["candidateWindow"]}`.', '',
                  row['observation'], '', row['followUp'], '',
                  f'Viewed source times: {[frame["sourceTime"] for frame in item["frames"]]}.', '',
                  f'[Open four-frame evidence](<{sheet.resolve()}>).']
    (output / 'CLAUDE_HANDOFF.md').write_text('\n'.join(line.rstrip() for line in lines) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('review', type=Path)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    build(args.review, args.bundle, args.output)
