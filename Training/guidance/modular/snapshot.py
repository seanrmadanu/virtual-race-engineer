"""Preserve local code, existing predictions and model artifacts before modular work."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    args.output.mkdir(parents=True, exist_ok=False)
    entries = []
    for directory in ['Racing Trainer', 'RacingTrainerSafetyTests', 'Training/guidance',
                      'data/guidance/bootstrap/runs', 'data/guidance/bootstrap/replays']:
        for source in sorted((root / directory).rglob('*')):
            if not source.is_file() or '__pycache__' in source.parts:
                continue
            relative = source.relative_to(root)
            dest = args.output / 'files' / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, dest)
            entries.append({'path': str(relative), 'sha256': digest(source), 'copied': True})
    for source in sorted((root.parent / 'Training Video').glob('*.mp4')):
        entries.append({'path': str(source), 'sha256': digest(source), 'copied': False})
    manifest = {'schema': 'modular-baseline-snapshot-v1', 'root': str(root),
                'git_status': subprocess.check_output(['git', 'status', '--short'], cwd=root, text=True),
                'files': entries, 'note': 'Preserved baselines are not ground truth. Original reviews remain untouched.'}
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Preserved {len(entries)} artifacts: {args.output}')


if __name__ == '__main__':
    main()
