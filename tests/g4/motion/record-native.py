#!/usr/bin/env python3
"""Sample a live QML engine and encode its timestamped PNGs, outside git.

Run after sourcing the task Qt/NVM environment. This is an instrumented
fixture demonstration, not a compositor/input/fps/NFR measurement.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def source_snapshot():
    names = subprocess.check_output(
        ['git', 'ls-files', '-z', 'shell', 'tests/g4'], cwd=ROOT).decode().split('\0')
    names += [str(p.relative_to(ROOT)) for p in HERE.rglob('*') if p.is_file()]
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
            for name in sorted(set(names)) if name and (ROOT / name).is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    if out.is_relative_to(ROOT):
        parser.error('output must be outside the repository')
    out.mkdir(parents=True, exist_ok=True)
    frames_dir = out / 'frames'
    frames_dir.mkdir(exist_ok=True)
    if any(frames_dir.iterdir()):
        parser.error('use a fresh output directory; existing frames are preserved')
    qt = Path(os.environ['QT_PREFIX'])
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        parser.error('installed ffmpeg is required')
    before = source_snapshot()
    (out / 'sources-before.json').write_text(json.dumps(before, indent=2) + '\n')
    commands = []

    def run(command, log_name):
        with (out / log_name).open('w') as log:
            code = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT).returncode
        commands.append({'command': command, 'exit': code, 'log': log_name})
        (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        if code:
            raise SystemExit(code)

    run(['node', 'tests/g4/visual/stage-providers.mjs'], 'provider-staging.log')
    run(['python3', 'tests/g4/visual/stage-assistant.py'], 'assistant-staging.log')
    staged = ROOT / 'tests/g4/visual/.staged'
    link = staged / 'motion-recording'
    if link.is_symlink():
        link.unlink()
    elif link.exists():
        parser.error('refusing to replace a non-symlink motion-recording path')
    link.symlink_to(out, target_is_directory=True)
    env = os.environ.copy()
    env.update(QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software',
               QSG_INFO='1', QT_DEBUG_PLUGINS='1')
    command = [str(qt / 'bin/qmltestrunner'), '-import', str(ROOT / 'tests/g4/visual/stubs'),
               '-input', str(HERE / 'samples/NativeMotion.qml')]
    frames, events, provenance = [], [], []
    with (out / 'qml.log').open('w') as log, (out / 'timestamps.jsonl').open('w') as timestamps:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, bufsize=1)
        try:
            for line in process.stdout:
                wall_ns, monotonic_ns = time.time_ns(), time.monotonic_ns()
                log.write(line)
                for marker, dest in [('MOTION_FRAME ', frames), ('MOTION_EVENT ', events),
                                     ('MOTION_PROVENANCE ', provenance)]:
                    if marker in line:
                        row = json.loads(line.split(marker, 1)[1])
                        row.update(receive_wall_ns=wall_ns, receive_monotonic_ns=monotonic_ns)
                        dest.append(row)
                        timestamps.write(json.dumps({'kind': marker.strip(), **row}) + '\n')
            code = process.wait()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait()
    commands.append({'command': command, 'exit': code, 'log': 'qml.log'})
    (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    after = source_snapshot()
    (out / 'sources-after.json').write_text(json.dumps(after, indent=2) + '\n')
    if before != after:
        raise SystemExit('source changed while recording')
    if code:
        raise SystemExit(code)
    if len(frames) < 2 or not provenance:
        raise SystemExit('missing native frames/provenance')
    intervals = []
    concat = ['ffconcat version 1.0']
    for index, frame in enumerate(frames):
        path = Path(frame['file']).resolve()
        if not path.is_relative_to(frames_dir) or not path.is_file():
            raise SystemExit('native frame missing or outside output')
        frame['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        duration = ((frames[index + 1]['sample_wall_start_ms'] - frame['sample_wall_start_ms']) / 1000
                    if index + 1 < len(frames) else 0.04)
        if duration <= 0:
            raise SystemExit('non-monotonic sample wall clock; inspect timestamps')
        intervals.append(duration)
        concat += [f"file 'frames/{path.name}'", 'option framerate 1000', f'duration {duration:.6f}']
    # ffconcat needs the final original image repeated to retain its duration.
    concat += [f"file 'frames/{Path(frames[-1]['file']).name}'", 'option framerate 1000']
    (out / 'frames.ffconcat').write_text('\n'.join(concat) + '\n')
    run([ffmpeg, '-hide_banner', '-nostdin', '-y', '-safe', '0', '-i', str(out / 'frames.ffconcat'),
         '-fps_mode', 'vfr', '-enc_time_base', '1:1000', '-c:v', 'libx264', '-preset', 'medium',
         '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(out / 'native-motion.mp4')], 'ffmpeg.log')
    manifest = {
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(),
        'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT)),
        'fixture': True, 'evidence_class': 'development', 'time_scale': 1,
        'capture': 'QtTest grabImage from a running native QML engine; no image interpolation',
        'platform_requested': 'offscreen', 'backend_requested': 'software',
        'provenance_from_executable': provenance, 'commands': commands,
        'events': events, 'frames': frames, 'frame_count': len(frames),
        'sampled_wall_duration_s': (frames[-1]['sample_wall_start_ms'] - frames[0]['sample_wall_start_ms']) / 1000,
        'video_duration_from_concat_s': sum(intervals),
        'encoding': 'variable timestamps from actual sample wall clock; final original frame repeated once',
        'monotonic_timestamps': 'Python time.monotonic_ns at receipt of each QML log; includes pipe/receiver delay',
        'limitations': ['instrumented offscreen/software with layer-shell stubs and fixture session/turn/windows',
                        'sampling and encoding add overhead; not frame-time/NFR or physical Wayfire/OS focus proof',
                        'candidate parameters await owner confirmation'],
        'video': {'file': 'native-motion.mp4', 'sha256': hashlib.sha256((out / 'native-motion.mp4').read_bytes()).hexdigest()},
        'sources_unchanged_during_recording': before == after,
    }
    (out / 'recording.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps({'video': str(out / 'native-motion.mp4'), 'frames': len(frames),
                      'duration_s': manifest['sampled_wall_duration_s'], 'events': len(events), 'exit': code}))


if __name__ == '__main__':
    main()
