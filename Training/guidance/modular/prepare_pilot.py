"""Build a 30-event development review. Suggestions are hypotheses, never truth."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
from snapshot import digest


def suggestion(row):
    geometry = row['modules'].get('geometry', {})
    value = geometry.get('value') or {}
    if geometry.get('state') != 'fresh' or row['modules'].get('validity', {}).get('state') != 'fresh':
        return 'uncertain', 'Input or route evidence is incomplete. Check whether this moment is usable.'
    if row['legacyPolicy'] == 'brake':
        return 'brake', 'Legacy threshold suggests braking. This is uncalibrated; video may not establish whether braking is needed.'
    if value.get('direction') == 'straight':
        return 'no_cue', 'Route geometry looks straight. Check the road and history; this does not establish that acceleration is safe.'
    if value.get('timing') in ['now', 'soon'] and value.get('severity') in ['medium', 'sharp', 'uTurn']:
        return 'lift', 'Possible lift before a bend. This is a review hypothesis, not a physics-derived action label.'
    return 'advance_warning', 'A route bend is visible. Check whether an advance warning is useful and when it should occur.'


def prepare(directory, destination):
    manifest = json.loads((directory / 'manifest.json').read_text())
    if manifest['schema'] != 'modular-observations-v1' or manifest['status'] != 'development_only_unreviewed_uncalibrated':
        raise ValueError('Unsupported trace or non-development source.')
    candidates, counts, latencies = [], Counter(), defaultdict(list)
    trace = directory / 'observations.jsonl'
    for line in trace.open():
        row = json.loads(line)
        counts[row['decision']['acceptedCue']] += 1
        for name, module in row['modules'].items():
            counts[f'{name}:{module["state"]}'] += 1
            latencies[name].append(module['completedAt'] - module['capturedAt'])
        if row['time'] >= 5 and abs(row['time'] % 5) < 1e-6:
            candidates.append(row)
    selected = []
    # Include previously reported errors, then spread label hypotheses across the recording.
    for time in [50, 95, 105]:
        selected.extend(row for row in candidates if row['time'] == time)
    buckets = defaultdict(list)
    for row in candidates:
        label, _ = suggestion(row)
        direction = (row['modules'].get('geometry', {}).get('value') or {}).get('direction', 'unknown')
        buckets[(label, direction)].append(row)
    for rows in buckets.values():
        # Alternate near start/end/middle to avoid a pilot concentrated in one corner.
        rows.sort(key=lambda row: hashlib.sha256(str(row['time']).encode()).hexdigest())
    while len(selected) < 30:
        before = len(selected)
        for key in sorted(buckets):
            while buckets[key]:
                row = buckets[key].pop()
                if all(abs(row['time'] - other['time']) >= 5 for other in selected):
                    selected.append(row); break
            if len(selected) == 30:
                break
        if len(selected) == before:
            raise ValueError('Not enough distinct events for a 30-event pilot.')
    events = []
    for row in sorted(selected, key=lambda row: row['time']):
        diagnostics = []
        for name in ['speed', 'minimap', 'geometry', 'validity']:
            module = row['modules'].get(name, {})
            value = module.get('value') or {}
            displayed = value.get('number', value.get('direction', value.get('flag', 'Missing')))
            evidence = dict(module.get('evidence') or {})
            if name == 'geometry' and value:
                evidence.update({key: str(value.get(key, 'Missing')) for key in ['severity', 'timing', 'turnDistance']})
                evidence['path'] = json.dumps(value.get('path', []), separators=(',', ':'))
            diagnostics.append(dict(name=name, value=str(displayed), units=module.get('units') or 'unconfirmed',
                state=module.get('state', 'missing'), confidence=module.get('confidence', 0),
                confidenceKind=module.get('confidenceKind', 'unavailable'), age=row['ages'].get(name),
                capturedAt=module.get('capturedAt'), version=module.get('version', 'unknown'),
                failure=module.get('failureReason'), evidence=evidence))
        geometry = row['modules'].get('geometry', {})
        value = geometry.get('value') or {}
        direction = value.get('direction', 'unknown') if geometry.get('state') == 'fresh' else 'unknown'
        direction = {'uTurnLeft': 'left', 'uTurnRight': 'right'}.get(direction, direction)
        target = 'unknown' if direction == 'unknown' else 'straight_segment' if direction == 'straight' else 'next_corner'
        # Map route geometry does not establish the current vehicle corner phase.
        label, rationale = suggestion(row)
        decision = row['decision']
        events.append(dict(id=f'modular-{row["time"]:07.1f}', time=row['time'], direction=direction,
            target=target, phase='unknown', reasons=['module-derived route, not vehicle steering', 'development-only pilot'],
            diagnostics=dict(cue=decision['acceptedCue'], proposedCue=decision['proposal']['cue'],
                proposalReason=decision['proposal']['reason'], origin=decision['proposal']['origin'],
                suppressionReasons=decision['suppressionReasons'], legacyPolicy=row['legacyPolicy'], modules=diagnostics,
                suggestedLabel=label, suggestedRationale=rationale)))
    pipeline_hash = manifest.get('pipelineSHA256', '')
    if len(pipeline_hash) != 64:
        raise ValueError('Replay lacks compiled-source provenance. Run a fresh native extraction.')
    bundle = dict(schemaVersion='racing-trainer-review-v2', title='Video 2 · Modular Coach · 30-event Pilot',
        source={key: manifest[key] for key in ['filename', 'sha256', 'duration']},
        modelSHA256=pipeline_hash, predictionsSHA256=digest(trace), events=events)
    with destination.open('x') as stream:
        json.dump(bundle, stream, indent=2); stream.write('\n')
    summary = dict(status='NOT_ACCURACY_RESULTS', count=manifest['sampleCount'], counters=dict(counts),
        pilotSuggestions=dict(Counter(event['diagnostics']['suggestedLabel'] for event in events)),
        latencySeconds={key: {'median': sorted(values)[len(values)//2], 'p95': sorted(values)[int(len(values)*.95)], 'max': max(values)}
                        for key, values in latencies.items()},
        limitations=['No independent accuracy labels', 'No physical calibration', 'Camera or menu recognition incomplete',
                     'Legacy policy comparison is not full tracked-engine replay', 'Both existing videos are development data'])
    with destination.with_suffix('.summary.json').open('x') as stream:
        json.dump(summary, stream, indent=2); stream.write('\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('trace_directory', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    prepare(args.trace_directory, args.destination)
