#!/usr/bin/env python3
"""Compare the fixed external-playback echo in a local AECProbe run.

Requires numpy and ffmpeg. This measures the whole capture path, including any
system ducking/noise suppression, not an isolated algorithmic ERLE measurement.
"""
import argparse
import json
import math
import subprocess
from pathlib import Path

import numpy as np

RATE = 16000


def samples(path):
    result = subprocess.run([
        'ffmpeg', '-nostdin', '-v', 'error', '-i', str(path),
        '-ac', '1', '-ar', str(RATE), '-f', 'f32le', '-'
    ], check=True, capture_output=True)
    return np.frombuffer(result.stdout, dtype='<f4').astype(np.float64)


def db(rms):
    return 20 * math.log10(max(float(rms), 1e-12))


def rms(signal):
    return float(np.sqrt(np.mean(signal * signal))) if len(signal) else 0.0


def measure(signal, reference):
    if len(signal) < len(reference) + RATE:
        raise ValueError('Recording is too short for the reference playback')
    if not np.isfinite(signal).all() or not np.isfinite(reference).all():
        raise ValueError('Audio contains nonfinite samples')
    size = 1 << (len(signal) + len(reference) - 1).bit_length()
    # c[k] = sum(signal[k+j] * reference[j]), for valid playback offsets.
    correlation = np.fft.irfft(np.fft.rfft(signal, size) * np.conj(np.fft.rfft(reference, size)), size)
    low, high = int(1.5 * RATE), min(int(4.5 * RATE), len(signal) - len(reference))
    if high <= low:
        raise ValueError('No valid playback alignment range')
    offset = low + int(np.argmax(np.abs(correlation[low:high])))
    segment = signal[offset:offset + len(reference)]
    ref_energy = float(np.dot(reference, reference))
    normalized = float(np.dot(segment, reference) / max(np.linalg.norm(segment) * np.linalg.norm(reference), 1e-20))
    gain = float(np.dot(segment, reference) / max(ref_energy, 1e-20))
    return {
        'duration_seconds': len(signal) / RATE,
        'playback_offset_seconds': offset / RATE,
        'playback_rms_dbfs': db(rms(segment)),
        'initial_quiet_rms_dbfs': db(rms(signal[:int(0.75 * RATE)])),
        'peak_dbfs': db(np.max(np.abs(signal))),
        'reference_correlation': normalized,
        'reference_projection_db': db(abs(gain)),
        'clipped_sample_count': int(np.count_nonzero(np.abs(signal) >= 0.999)),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    parser.add_argument('reference', type=Path)
    args = parser.parse_args()
    result = json.loads((args.folder / 'result.json').read_text())
    if result['state'] != 'completed':
        raise ValueError('Probe did not complete: ' + str(result))
    for phase in result['phases']:
        if phase['configurationChanged'] or phase['writeError'] or phase['frames'] == 0:
            raise ValueError('Capture invalid: ' + str(phase))
    reference = samples(args.reference)
    if rms(reference) < 1e-5:
        raise ValueError('Reference is silent')
    baseline = measure(samples(args.folder / 'baseline.caf'), reference)
    processed = measure(samples(args.folder / 'processed.caf'), reference)
    output = {
        'devices': json.loads((args.folder / 'devices.json').read_text()),
        'baseline': baseline, 'processed': processed,
        'capture_path_level_reduction_db': baseline['playback_rms_dbfs'] - processed['playback_rms_dbfs'],
        'limitations': [
            'Sequential physical speaker/microphone captures; keep environment and volume fixed.',
            'Reduction includes any system ducking, noise suppression and input path gain changes.',
            'Does not test near-end speech preservation, double-talk or subtitle accuracy.',
        ],
    }
    (args.folder / 'analysis.json').write_text(json.dumps(output, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(output, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
