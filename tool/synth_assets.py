"""Synthesizes Rhytmaniac's original bundled audio: the demo song and hit sounds.

Everything here is generated from oscillators and noise, so the assets carry no
third-party copyright. Run from the project root:

    python tool/synth_assets.py
"""

import wave
from pathlib import Path

import numpy as np

SR = 22050
BPM = 128.0
BEAT = 60.0 / BPM
BAR = BEAT * 4
LEAD_IN = 0.5  # seconds of silence before the first downbeat
RNG = np.random.default_rng(7)

ROOT = Path(__file__).resolve().parent.parent


def note_hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def env_adsr(n, a, d, s, r, sr=SR):
    a_n, d_n, r_n = int(a * sr), int(d * sr), int(r * sr)
    s_n = max(0, n - a_n - d_n - r_n)
    e = np.concatenate([
        np.linspace(0, 1, max(a_n, 1), endpoint=False),
        np.linspace(1, s, max(d_n, 1), endpoint=False),
        np.full(s_n, s),
        np.linspace(s, 0, max(r_n, 1)),
    ])
    return e[:n] if len(e) >= n else np.pad(e, (0, n - len(e)))


def kick():
    n = int(0.35 * SR)
    t = np.arange(n) / SR
    freq = 50 + 110 * np.exp(-t * 30)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    body = np.sin(phase) * np.exp(-t * 9)
    click = RNG.standard_normal(n) * np.exp(-t * 400) * 0.3
    return (body + click) * 0.95


def snare():
    n = int(0.25 * SR)
    t = np.arange(n) / SR
    noise = RNG.standard_normal(n)
    noise = np.convolve(noise, [0.5, -0.5], mode="same")  # crude high-pass
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t * 25)
    return (noise * np.exp(-t * 18) * 0.55 + tone * 0.5)


def clap():
    n = int(0.22 * SR)
    t = np.arange(n) / SR
    noise = np.convolve(RNG.standard_normal(n), [0.5, -0.5], mode="same")
    bursts = sum(np.exp(-np.maximum(t - k * 0.009, 0) * 160) * (t >= k * 0.009) for k in range(3))
    return noise * (bursts * 0.3 + np.exp(-t * 14) * 0.5) * 0.7


def hat(open_=False):
    n = int((0.22 if open_ else 0.05) * SR)
    t = np.arange(n) / SR
    noise = RNG.standard_normal(n)
    noise = noise - np.convolve(noise, np.ones(3) / 3, mode="same")
    return noise * np.exp(-t * (14 if open_ else 90)) * 0.35


def saw(freq, n, detune=0.0):
    t = np.arange(n) / SR
    out = np.zeros(n)
    for d in (-detune, 0.0, detune):
        f = freq * (1 + d)
        out += 2 * ((t * f) % 1.0) - 1
    return out / 3


def lowpass(x, alpha):
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += alpha * (v - acc)
        y[i] = acc
    return y


def square(freq, n):
    t = np.arange(n) / SR
    return np.sign(np.sin(2 * np.pi * freq * t))


class Track:
    def __init__(self, seconds):
        self.buf = np.zeros(int(seconds * SR) + SR)

    def add(self, sample, at, gain=1.0):
        i = int(round(at * SR))
        end = min(len(self.buf), i + len(sample))
        if i < 0 or i >= len(self.buf):
            return
        self.buf[i:end] += sample[: end - i] * gain


def beat_time(bar, beat=0.0):
    return LEAD_IN + bar * BAR + beat * BEAT


def build_song():
    # Sections, in bars.
    sections = [
        ("intro", 4), ("verse", 8), ("build", 4), ("drop", 8),
        ("break", 4), ("drop2", 8), ("outro", 4),
    ]
    total_bars = sum(b for _, b in sections)
    tr = Track(LEAD_IN + total_bars * BAR + 2.0)

    # A minor progression: Am F C G (one chord per bar).
    chords = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
    bass_roots = [45, 41, 48, 43]
    arp_pattern = [0, 1, 2, 1, 2, 0, 2, 1]
    lead_line = [76, 74, 72, 74, 76, 79, 76, 72]

    K, S, C, H, HO = kick(), snare(), clap(), hat(), hat(True)
    bar = 0
    for name, length in sections:
        for b in range(length):
            chord = chords[(bar + b) % 4]
            root = bass_roots[(bar + b) % 4]
            t0 = beat_time(bar + b)
            pad_n = int(BAR * SR)
            pad = sum(saw(note_hz(m), pad_n, 0.004) for m in chord) / 3
            pad = lowpass(pad, 0.08) * env_adsr(pad_n, 0.25, 0.3, 0.8, 0.4)
            if name == "intro":
                tr.add(pad, t0, 0.35 * (b + 1) / length)
                for i in range(8):
                    tr.add(H, t0 + i * BEAT / 2, 0.25)
            elif name == "verse":
                tr.add(pad, t0, 0.18)
                for i in (0, 2):
                    tr.add(K, t0 + i * BEAT, 0.9)
                tr.add(K, t0 + 2.5 * BEAT, 0.6)
                for i in (1, 3):
                    tr.add(S, t0 + i * BEAT, 0.7)
                for i in range(8):
                    tr.add(H, t0 + i * BEAT / 2, 0.3 if i % 2 else 0.4)
                for i in range(8):
                    n = int(BEAT / 2 * SR * 0.9)
                    bass = lowpass(saw(note_hz(root), n), 0.12) * env_adsr(n, 0.005, 0.08, 0.6, 0.05)
                    tr.add(bass, t0 + i * BEAT / 2, 0.5)
                for i in range(8):
                    m = chord[arp_pattern[i]] + 12
                    n = int(BEAT / 2 * SR * 0.8)
                    arp = square(note_hz(m), n) * env_adsr(n, 0.003, 0.1, 0.3, 0.05)
                    tr.add(lowpass(arp, 0.25), t0 + i * BEAT / 2, 0.16)
            elif name == "build":
                tr.add(pad, t0, 0.2 + 0.05 * b)
                hits = 4 * (2 ** min(b, 2))
                for i in range(hits):
                    tr.add(S, t0 + i * BAR / hits, 0.35 + 0.12 * b)
                for i in range(4):
                    tr.add(K, t0 + i * BEAT, 0.8)
            elif name in ("drop", "drop2"):
                tr.add(pad, t0, 0.15)
                for i in range(4):
                    tr.add(K, t0 + i * BEAT, 1.0)
                for i in (1, 3):
                    tr.add(C, t0 + i * BEAT, 0.8)
                for i in range(4):
                    tr.add(HO, t0 + (i + 0.5) * BEAT, 0.35)
                # Sustained sub bass: one long note per half bar (holds/sliders).
                for half in range(2):
                    n = int(BAR / 2 * SR * 0.95)
                    sub = np.sin(2 * np.pi * note_hz(root - 12) * np.arange(n) / SR)
                    sub += 0.4 * lowpass(saw(note_hz(root), n), 0.05)
                    tr.add(sub * env_adsr(n, 0.01, 0.1, 0.85, 0.08), t0 + half * BAR / 2, 0.45)
                if name == "drop":
                    # Long lead notes: two per bar.
                    for i in range(2):
                        m = lead_line[((bar + b) * 2 + i) % len(lead_line)]
                        n = int(BAR / 2 * SR * 0.9)
                        lead = lowpass(saw(note_hz(m), n, 0.006), 0.3)
                        tr.add(lead * env_adsr(n, 0.01, 0.15, 0.7, 0.1), t0 + i * BAR / 2, 0.22)
                else:
                    # Fast 16th arps.
                    for i in range(16):
                        m = chord[[0, 1, 2, 1][i % 4]] + 24
                        n = int(BEAT / 4 * SR * 0.85)
                        arp = square(note_hz(m), n) * env_adsr(n, 0.002, 0.05, 0.25, 0.03)
                        tr.add(lowpass(arp, 0.3), t0 + i * BEAT / 4, 0.14 if i % 4 else 0.2)
            elif name == "break":
                tr.add(pad, t0, 0.12)
            elif name == "outro":
                fade = 1.0 - b / length
                tr.add(pad, t0, 0.25 * fade)
                tr.add(K, t0, 0.8 * fade)
                tr.add(K, t0 + 2 * BEAT, 0.6 * fade)
                for i in range(8):
                    tr.add(H, t0 + i * BEAT / 2, 0.25 * fade)
        bar += length

    out = tr.buf
    out = np.tanh(out * 1.1)  # soft clip / glue
    out /= np.max(np.abs(out)) + 1e-9
    return out * 0.9


def tick(freq, length, decay, noise=0.0):
    n = int(length * SR)
    t = np.arange(n) / SR
    s = np.sin(2 * np.pi * freq * t) * np.exp(-t * decay)
    if noise:
        s += RNG.standard_normal(n) * np.exp(-t * decay * 3) * noise
    s /= np.max(np.abs(s)) + 1e-9
    return s * 0.8


def write_wav(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = (np.clip(data, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"wrote {path} ({len(pcm) / SR:.1f}s)")


if __name__ == "__main__":
    write_wav(ROOT / "assets/audio/ember_drift.wav", build_song())
    write_wav(ROOT / "assets/sfx/hit.wav", tick(1800, 0.06, 70, noise=0.25))
    write_wav(ROOT / "assets/sfx/hit_soft.wav", tick(900, 0.08, 50, noise=0.1))
    write_wav(ROOT / "assets/sfx/miss.wav", tick(220, 0.12, 30))
