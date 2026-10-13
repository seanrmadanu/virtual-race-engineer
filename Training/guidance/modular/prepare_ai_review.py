"""Extract causal visual evidence. This script does not generate review labels."""
import argparse
from bisect import bisect_right
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prepare(bundle_path, video, output):
    bundle = json.loads(bundle_path.read_text())
    if sha256(video) != bundle['source']['sha256']:
        raise ValueError('Recording identity mismatch')
    # Do not overwrite a previous evidence set or reviewer work.
    output.mkdir(parents=True, exist_ok=False)
    probe = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_frames',
        '-show_entries', 'frame=best_effort_timestamp_time', '-of', 'json', str(video)]))
    pts = [float(frame['best_effort_timestamp_time']) for frame in probe['frames']]
    if not pts or any(a >= b for a, b in zip(pts, pts[1:])):
        raise ValueError('Video timestamps must be strictly increasing')
    selected = []
    events = []
    for event in bundle['events']:
        targets = [event['time'] - 2, event['time'] - 4 / 3, event['time'] - 2 / 3, event['time']]
        frames = []
        for target in targets:
            index = bisect_right(pts, max(0, target) + 1e-7) - 1
            if index < 0 or pts[index] > event['time'] + 1e-7:
                raise ValueError('No causal evidence frame')
            selected.append(index)
            frames.append({'frameIndex': index, 'sourceTime': pts[index]})
        events.append({'eventID': event['id'], 'time': event['time'], 'frames': frames,
                       'contactSheet': event['id'] + '.jpg'})
    indices = sorted(set(selected))
    file_names = {index: f'frame-{i + 1:03d}.png' for i, index in enumerate(indices)}
    # Balanced expression avoids FFmpeg's parser depth limit for many samples.
    def selection_sum(values):
        if len(values) == 1:
            return f'eq(n,{values[0]})'
        middle = len(values) // 2
        return f'({selection_sum(values[:middle])}+{selection_sum(values[middle:])})'

    selection = selection_sum(indices)
    subprocess.run(['ffmpeg', '-v', 'error', '-nostdin', '-i', str(video), '-an',
                    '-vf', f"select='{selection}',drawbox=x=0:y=0:w=640:h=360:color=black:t=fill",
                    '-fps_mode', 'vfr', str(output / 'frame-%03d.png')], check=True)

    def sheet(event):
        command = ['ffmpeg', '-v', 'error', '-nostdin']
        for frame in event['frames']:
            frame['path'] = file_names[frame['frameIndex']]
            frame['sha256'] = sha256(output / frame['path'])
            command += ['-i', str(output / frame['path'])]
        filters = ';'.join(f'[{i}:v]scale=960:540[v{i}]' for i in range(4))
        filters += ';[v0][v1][v2][v3]xstack=inputs=4:layout=0_0|960_0|0_540|960_540[out]'
        subprocess.run(command + ['-filter_complex', filters, '-map', '[out]', '-frames:v', '1',
                                 '-q:v', '2', str(output / event['contactSheet'])], check=True)
        event['contactSheetSHA256'] = sha256(output / event['contactSheet'])

    with ThreadPoolExecutor(max_workers=3) as workers:
        list(workers.map(sheet, events))
    manifest = {'schemaVersion': 'racing-trainer-ai-evidence-v1',
                'sourceSHA256': bundle['source']['sha256'], 'bundleSHA256': sha256(bundle_path),
                'modelSHA256': bundle['modelSHA256'], 'predictionsSHA256': bundle['predictionsSHA256'],
                'mask': {'x': 0, 'y': 0, 'width': 640, 'height': 360,
                         'reason': 'Exclude steering-wheel and physical input inset'},
                'sampling': 'Four source frames in the two seconds ending at each event. Not continuous playback.',
                'contactSheetOrder': ['top-left', 'top-right', 'bottom-left', 'bottom-right'],
                'events': events}
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Prepared {len(events)} events / {len(indices)} frames at {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--video', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    prepare(args.bundle, args.video, args.output)
