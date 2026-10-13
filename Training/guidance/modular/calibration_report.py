"""Inspect shadow evidence. Never creates an enabled SlowdownCalibration or training labels."""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1_048_576), b''):
            result.update(chunk)
    return result.hexdigest()


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def summarize(manifest, records):
    if manifest.get('schema') != 'modular-shadow-session-v1' or manifest.get('cuesEmitted') is not False:
        raise ValueError('Expected a shadow-only evidence session.')
    segments = {}; failures = Counter(); delays = []; points = []; image_hashes = {}
    for item in records:
        if item.get('type') != 'sample':
            continue
        generation = item['generation']
        source = item['source']
        pts, arrival, completed = item['sourcePTS'], item['receivedAt'], item['completedAt']
        if not all(finite(value) for value in (pts, arrival, completed)) or min(pts, arrival) < 0 or completed < arrival:
            raise ValueError('Invalid sample clocks.')
        segment = segments.setdefault(generation, dict(source=source, count=0, firstPTS=pts, lastPTS=None,
                                                       firstReceivedAt=arrival, lastReceivedAt=None))
        if segment['source'] != source:
            raise ValueError('A generation contains more than one source.')
        if segment['lastPTS'] is not None and (pts <= segment['lastPTS'] or arrival <= segment['lastReceivedAt']):
            raise ValueError('Noncausal timestamps inside one generation.')
        segment.update(count=segment['count']+1, lastPTS=pts, lastReceivedAt=arrival)
        row = item['row']
        if not finite(row['time']) or row['time'] > completed or row['time'] < arrival:
            raise ValueError('Decision row does not match completion time.')
        for module, observation in row['observations'].items():
            capture, finish = observation['capturedAt'], observation['completedAt']
            if not all(finite(value) for value in (capture, finish)) or not 0 <= capture <= finish <= row['time']:
                raise ValueError('Future or invalid observation in evidence.')
            if observation['sourceSessionID'] != generation:
                raise ValueError('Old-source observation in new generation.')
            if observation.get('failureReason'):
                failures[f"{module}:{observation['failureReason']}"] += 1
        if item['decision'].get('learnedLiveEnabled') is not False:
            raise ValueError('Unexpected learned live output.')
        speed = row['observations'].get('speed', {})
        geometry = row['observations'].get('geometry', {})
        validity = row['observations'].get('validity', {})
        points.append(dict(generation=generation, sourcePTS=pts, receiptTime=arrival,
            speed=(speed.get('value') or {}).get('number'), speedUnit=speed.get('units'),
            speedState=speed.get('state', 'missing'), speedConfidence=speed.get('confidence'),
            speedAge=row.get('ages', {}).get('speed'), geometry=geometry.get('value'),
            geometryState=geometry.get('state', 'missing'), inputState=validity.get('state', 'missing'),
            evidenceImages=item.get('evidenceImages', [])))
        names = item.get('evidenceImages', [])
        hashes = item.get('evidenceImageSHA256', {})
        if set(names) != set(hashes):
            raise ValueError('Image evidence fingerprints are missing.')
        for name in names:
            if not isinstance(name, str) or Path(name).name != name or not name.endswith('.png'):
                raise ValueError('Unsafe evidence path.')
            if not isinstance(hashes[name], str) or len(hashes[name]) != 64 or (name in image_hashes and image_hashes[name] != hashes[name]):
                raise ValueError('Invalid image evidence fingerprint.')
            image_hashes[name] = hashes[name]
        delays.append(completed-arrival)
    if len(points) != manifest.get('samples') and manifest.get('status') == 'closed':
        raise ValueError('Closed manifest sample count does not match the trace.')
    delays.sort()
    return dict(schema='calibration-evidence-report-v1', status='needs_independent_measurements',
        sourceRunID=manifest['runID'], runStatus=manifest['status'], configuration=manifest['configuration'],
        calibrationEnabled=False, learnedCuesEnabled=False, samples=len(points),
        segments=segments, moduleFailures=dict(failures),
        receiptToAnalysisCompletionSeconds=dict(count=len(delays),
            median=delays[len(delays)//2] if delays else None,
            p95=delays[min(len(delays)-1, math.ceil(len(delays)*.95)-1)] if delays else None),
        warningDelaySeconds=None, evidenceImageSHA256=image_hashes, series=points,
        limitations=['Receipt time is not camera acquisition time.',
                     'Analysis duration is not end-to-end warning delay.',
                     'Speed decrease does not establish brake or lift input.',
                     'Map scale and target speeds require independent measurements.',
                     'Source labels are identifiers, not recording content hashes.',
                     'This is neither a calibration approval nor a qualified live shadow session.'])


def prepare(session, output):
    if output.exists():
        raise ValueError('Output exists. Choose a new directory.')
    manifest_path = session / 'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('status') != 'closed' or not manifest.get('traceSHA256'):
        raise ValueError('Session is still recording, interrupted, or failed. Preserve it for diagnostics; do not calibrate from it.')
    trace = session / 'observations.jsonl'
    before = digest(trace)
    if before != manifest['traceSHA256']:
        raise ValueError('Trace fingerprint mismatch.')
    with trace.open() as handle:
        report = summarize(manifest, (json.loads(line) for line in handle))
    for name, expected in report['evidenceImageSHA256'].items():
        if (session / name).is_symlink() or digest(session / name) != expected:
            raise ValueError('Image evidence fingerprint mismatch.')
    if digest(trace) != before or json.loads(manifest_path.read_text()) != manifest:
        raise ValueError('Session changed while building the report.')
    report['traceSHA256'] = before
    report['manifestSHA256'] = digest(manifest_path)
    template = dict(schema='calibration-measurements-draft-v1', status='unreviewed',
        sourceRunID=manifest['runID'], traceSHA256=before, reviewer='', carSetupID='', hudProfile='',
        confirmedSpeedUnit='', measurements=[],
        requiredEvidence={
            'map_scale': 'Same identified corner and fixed map zoom; independently measured meters plus matching normalized distance.',
            'deceleration': 'Verified lift/brake input, speed interval, grade/setup context, and several repeat runs. Do not infer the input from speed.',
            'warning_delay': 'Input event and delivered cue timestamps on a verified common clock; shadow logs emit no cues.',
            'target_speeds': 'Reviewed acceptable cornering speeds for the confirmed car/setup; do not copy literature constants.'},
        calibrationEnabled=False)
    output.mkdir(parents=True, exist_ok=False)
    (output / 'evidence-report.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    (output / 'calibration-notes.template.json').write_text(json.dumps(template, indent=2) + '\n')
    print(f'Prepared {report["samples"]} evidence rows in {output}. No calibration or model was enabled.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('session', type=Path); parser.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        prepare(args.session, args.output)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(2, f'CALIBRATION REPORT BLOCKED: {error}\n')
