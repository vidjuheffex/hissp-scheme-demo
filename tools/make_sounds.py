"""Synthesize the ambient sound loops: assets/sounds/*.ogg.

One-off asset tool, not part of the game. Every loop is seamless: noise is
shaped in the frequency domain over the whole loop (so it is periodic), slow
swells are periodic too, and events (drops, chirps, laps) that run past the
end wrap around to the start. The game fades the loops in and out; see
`update-sounds!` in src/world_game.sld.

    uv run --no-project --with numpy --with soundfile tools/make_sounds.py [names...]

With names (wind, rain, birds, crickets, water, steps, thunder), only those
are written.
"""

import sys
from pathlib import Path

import numpy as np
import soundfile

RATE = 32000
OUT = Path(__file__).resolve().parent.parent / "assets" / "sounds"
rng = np.random.default_rng(11)


def seconds(n):
    return int(n * RATE)


def shaped_noise(n, lo, hi, tilt=0.0):
    """Periodic noise between `lo` and `hi` Hz, its spectrum tilted by f^tilt."""
    spectrum = np.fft.rfft(rng.normal(size=n))
    f = np.fft.rfftfreq(n, 1.0 / RATE)
    f[0] = 1.0
    octave = np.log2(f)
    band = np.clip((octave - np.log2(lo)) * 3.0 + 0.5, 0, 1) * np.clip((np.log2(hi) - octave) * 3.0 + 0.5, 0, 1)
    x = np.fft.irfft(spectrum * band * f ** tilt, n)
    return x / (np.std(x) + 1e-9)


def swell(n, per_second):
    """Periodic slow noise from 0 to 1, changing about `per_second` times a second."""
    spectrum = np.fft.rfft(rng.normal(size=n))
    f = np.fft.rfftfreq(n, 1.0 / RATE)
    x = np.fft.irfft(spectrum * np.exp(-((f / per_second) ** 2)), n)
    return (x - x.min()) / (x.max() - x.min() + 1e-9)


def place(out, sound, at):
    """Add `sound` into `out` at sample `at`, wrapping past the end."""
    idx = (at + np.arange(len(sound))) % len(out)
    np.add.at(out, idx, sound)


def lowpass(x, cutoff):
    """One-pole lowpass, run twice around the loop so it settles seamlessly."""
    a = np.exp(-2 * np.pi * cutoff / RATE)
    y, state = np.empty_like(x), 0.0
    for _ in range(2):
        for i, v in enumerate(x):
            state = (1 - a) * v + a * state
            y[i] = state
    return y


def reverb(x, length, wet):
    """Circular convolution with a decaying noise tail `length` seconds long."""
    t = np.arange(seconds(length)) / RATE
    tail = rng.normal(size=len(t)) * np.exp(-6.9 * t / length)
    tail = np.convolve(tail, np.ones(8) / 8, "same")  # darker tail
    tail /= np.sqrt(np.sum(tail ** 2))
    padded = np.zeros(len(x))
    padded[: len(tail)] = tail
    wet_part = np.fft.irfft(np.fft.rfft(x) * np.fft.rfft(padded), len(x))
    return x + wet * wet_part


def tone(freqs, amps=None, harmonics=(1.0, 0.12)):
    """A sine (with a little overtone) following per-sample `freqs`."""
    phase = 2 * np.pi * np.cumsum(freqs) / RATE
    s = sum(h * np.sin(phase * (k + 1)) for k, h in enumerate(harmonics))
    return s if amps is None else s * amps


def hann(n):
    return np.sin(np.pi * np.arange(n) / n) ** 2


def save(name, x, peak=0.85):
    x = x - x.mean()
    x = x * (peak / np.max(np.abs(x)))
    (OUT / name).parent.mkdir(parents=True, exist_ok=True)
    soundfile.write(OUT / f"{name}.ogg", x.astype(np.float32), RATE, format="OGG", subtype="VORBIS")
    print(f"{name}.ogg  {len(x) / RATE:.2f} s")


def wind():
    n = seconds(40)
    gust = swell(n, 0.12)
    flutter = swell(n, 0.6)
    low = shaped_noise(n, 40, 450, -0.6)
    high = shaped_noise(n, 250, 1600, -0.4)
    whistle = shaped_noise(n, 520, 700)
    return (low * (0.45 + 0.55 * gust)
            + high * (0.1 + 0.9 * gust ** 2 * (0.6 + 0.4 * flutter))
            + whistle * 0.25 * gust ** 4)


def rain():
    n = seconds(20)
    out = shaped_noise(n, 500, 11000, -0.25) * 0.35 * (0.85 + 0.15 * swell(n, 0.3))
    for _ in range(20 * 220):
        size = rng.lognormal(0, 0.6)
        m = seconds(rng.uniform(0.006, 0.03))
        t = np.arange(m) / RATE
        fall = np.exp(-t / (m / RATE / 4))
        if rng.random() < 0.3:  # a drop on a leaf or a puddle: a short plink
            f = rng.uniform(1800, 5500) * (1 + 0.3 * t / t[-1])
            drop = tone(f, fall, (1.0,))
        else:  # a drop on the ground: a soft tick
            drop = rng.normal(size=m) * fall
            drop = np.diff(drop, prepend=0.0)
        place(out, drop * size * 0.25, rng.integers(n))
    return reverb(out, 0.6, 0.3)


def chirp(f0, f1, length, curve=1.0):
    m = seconds(length)
    s = np.linspace(0, 1, m) ** curve
    return tone(f0 + (f1 - f0) * s, hann(m))


def phrase(kind, pitch):
    """One bird's song: a list of (start seconds, sound)."""
    notes = []
    if kind == "tweet":  # a few quick descending notes
        for k in range(rng.integers(3, 7)):
            notes.append((k * 0.13, chirp(pitch * 1.35, pitch, 0.07, 0.6)))
    elif kind == "trill":  # a fast rattle up and down
        rate = rng.uniform(14, 22)
        for k in range(rng.integers(10, 22)):
            notes.append((k / rate, chirp(pitch, pitch * 1.18, 0.03)))
    elif kind == "whistle":  # slow slurred whistles with a little vibrato
        t0 = 0.0
        for k in range(rng.integers(2, 5)):
            length = rng.uniform(0.18, 0.35)
            m = seconds(length)
            s = np.linspace(0, 1, m)
            base = pitch * rng.uniform(0.7, 1.0)
            f = base * (1 + 0.25 * np.sin(np.pi * s) * rng.choice([-1, 1])) + 40 * np.sin(2 * np.pi * 28 * s * length)
            notes.append((t0, tone(f, hann(m) ** 0.6, (1.0, 0.05))))
            t0 += length + rng.uniform(0.05, 0.2)
    else:  # warble: a wobbly run of notes
        length = rng.uniform(0.5, 0.9)
        m = seconds(length)
        s = np.arange(m) / RATE
        f = pitch + 700 * np.sin(2 * np.pi * rng.uniform(18, 30) * s) + 500 * np.sin(2 * np.pi * 3 * s)
        notes.append((0.0, tone(f, hann(m) ** 0.4 * (0.6 + 0.4 * np.sin(2 * np.pi * 9 * s)))))
    return notes


def birds():
    n = seconds(60)
    out = np.zeros(n)
    for _ in range(7):
        kind = rng.choice(["tweet", "trill", "whistle", "warble"])
        pitch = {"tweet": 3600, "trill": 4200, "whistle": 2800, "warble": 3300}[kind] * rng.uniform(0.8, 1.2)
        near = rng.uniform(0.2, 1.0)
        t = rng.uniform(0, 8)
        while t < 60:
            song = np.zeros(seconds(4))
            for start, note in phrase(kind, pitch):
                place(song, note, seconds(start))
            if near < 0.6:  # far off: quieter and duller
                song = lowpass(song, 2500 + 4000 * near)
            place(out, song * near ** 1.5, seconds(t))
            t += rng.uniform(4, 11)
    out += shaped_noise(n, 150, 2000, -0.8) * 0.01  # the open air
    return reverb(out, 1.4, 0.35)


def crickets():
    n = seconds(30)
    out = np.zeros(n)
    for _ in range(9):
        carrier = rng.uniform(3900, 5200)
        syllables = rng.integers(2, 5)
        rate = rng.uniform(28, 45)
        period = n / round(n / seconds(rng.uniform(0.45, 1.1)))  # whole chirps per loop
        gain = rng.uniform(0.15, 1.0) ** 1.5
        m = seconds(0.016)
        syllable = tone(np.full(m, carrier), hann(m), (1.0, 0.2, 0.05))
        chirp_sound = np.zeros(seconds(syllables / rate + 0.02))
        for k in range(syllables):
            place(chirp_sound, syllable, seconds(k / rate))
        offset = rng.uniform(0, period)
        for k in range(int(round(n / period))):
            place(out, chirp_sound * gain * rng.uniform(0.85, 1.0), int(offset + k * period))
    # The rest of the field, far off: a pulsing haze around 4.5 kHz.
    s = np.arange(n) / RATE
    chorus = shaped_noise(n, 4000, 5200) * (0.5 + 0.5 * np.sin(2 * np.pi * 30 * s)) ** 2
    out += chorus * 0.05 * (0.7 + 0.3 * swell(n, 0.2))
    return reverb(out, 0.9, 0.3)


def water():
    n = seconds(30)
    out = shaped_noise(n, 60, 400, -0.5) * 0.08
    starts, t = [], rng.uniform(0, 1)
    while t < 30 - 2.5:
        starts.append(t)
        t += rng.uniform(2.6, 4.8)
    starts = np.array(starts) * 30 / (t if t > 30 else 30)  # spread to fill the loop
    for start in starts:
        length = rng.uniform(1.8, 2.8)
        m = seconds(length)
        s = np.linspace(0, 1, m)
        rush = np.minimum(s / 0.25, 1.0) ** 2 * np.exp(-np.maximum(s - 0.25, 0) * 4)
        fizz = np.clip((s - 0.2) / 0.15, 0, 1) * np.exp(-np.maximum(s - 0.35, 0) * 3.5)
        size = rng.uniform(0.5, 1.0) * (1 - s) ** 2  # die away to nothing
        lap = (shaped_noise(m, 70, 900, -0.5) * rush
               + shaped_noise(m, 1200, 6000, -0.3) * fizz * 0.25)
        place(out, lap * size, seconds(start))
    return reverb(out, 0.5, 0.2)


def burst(m, attack, decay):
    """An envelope `m` samples long: up over `attack` seconds, then dying away to nothing."""
    t = np.arange(m) / RATE
    tail = np.clip((m - np.arange(m)) / (0.4 * m), 0, 1)  # reach silence by the end
    return np.clip(t / attack, 0, 1) * np.exp(-np.maximum(t - attack, 0) / decay) * tail


def grains(out, count, start, spread, lo, hi, gain):
    """`count` tiny crackles scattered over `spread` seconds from `start`."""
    for _ in range(count):
        m = seconds(rng.uniform(0.001, 0.004))
        at = seconds(start + spread * rng.beta(1.5, 3.0))
        place(out, shaped_noise(m + 64, lo, hi)[:m] * burst(m, 0.0003, 0.0008) * gain * rng.lognormal(0, 0.5), at)


def footstep(surface):
    """One step, heel then toe, on `surface`."""
    out = np.zeros(seconds(0.45))
    toe = rng.uniform(0.05, 0.085)
    for at, gain in ((0.0, 1.0), (toe, rng.uniform(0.5, 0.8))):
        if surface == "grass":
            m = seconds(0.25)
            place(out, gain * (shaped_noise(m, 50, 260) * burst(m, 0.004, 0.035) * 0.6
                               + shaped_noise(m, 900, 6000, -0.3) * burst(m, 0.01, 0.06)
                               + shaped_noise(m, 2500, 9000) * burst(m, 0.03, 0.09) * 0.3), seconds(at))
        elif surface == "dirt":
            m = seconds(0.2)
            place(out, gain * (shaped_noise(m, 60, 400) * burst(m, 0.003, 0.03)
                               + shaped_noise(m, 400, 3000) * burst(m, 0.006, 0.05) * 0.25), seconds(at))
            grains(out, int(30 * gain), at, 0.12, 1500, 7000, 0.6)
        elif surface == "rock":
            m = seconds(0.15)
            f = rng.uniform(220, 420)
            t = np.arange(m) / RATE
            knock = (np.sin(2 * np.pi * f * t) + 0.4 * np.sin(2 * np.pi * f * 2.7 * t)) * np.exp(-t / 0.025)
            place(out, gain * (knock * 0.7
                               + shaped_noise(m, 2000, 9000) * burst(m, 0.0005, 0.006)
                               + shaped_noise(m, 800, 4000) * burst(m, 0.01, 0.04) * 0.12), seconds(at))
        elif surface == "snow":
            m = seconds(0.3)
            place(out, gain * shaped_noise(m, 40, 200) * burst(m, 0.01, 0.05) * 0.7, seconds(at))
            grains(out, int(110 * gain), at, 0.2, 900, 5000, 0.5)
        else:  # water
            m = seconds(0.4)
            place(out, gain * (shaped_noise(m, 300, 5000, -0.3) * burst(m, 0.015, 0.14)
                               + shaped_noise(m, 90, 500) * burst(m, 0.02, 0.1) * 0.6), seconds(at))
            for _ in range(int(5 * gain)):  # drops falling back
                d = seconds(rng.uniform(0.03, 0.07))
                t = np.arange(d) / RATE
                f = rng.uniform(600, 1800) * (1 + 1.5 * t / t[-1])
                place(out, tone(f, np.exp(-t / 0.015), (1.0,)) * 0.15, seconds(at + rng.uniform(0.06, 0.3)))
    fade = np.ones(len(out))
    fade[-seconds(0.05):] = np.linspace(1, 0, seconds(0.05))
    return out * fade


FOOTSTEP_LOUDNESS = {"grass": 0.5, "dirt": 0.65, "rock": 0.6, "snow": 0.55, "water": 0.7}


def thunder(near):
    """A roll of thunder: a crack and ripping first if `near`, then rumbles."""
    n = seconds(9.0)
    t = np.arange(n) / RATE
    # Rolling: a run of swells, each later one quieter.
    roll = np.zeros(n)
    at = 0.0 if near else rng.uniform(0.3, 0.8)
    loud = 1.0
    while at < 6.0:
        rise, fall = rng.uniform(0.05, 0.3), rng.uniform(0.5, 1.6)
        s = t - at
        roll += loud * np.where(s < 0, 0, np.clip(s / rise, 0, 1) * np.exp(-np.maximum(s - rise, 0) / fall))
        at += rng.uniform(0.4, 1.4)
        loud *= rng.uniform(0.55, 0.9)
    roll *= np.clip((n - np.arange(n)) / seconds(1.5), 0, 1)
    out = shaped_noise(n, 22, 160 if not near else 260, -0.9) * roll
    out += shaped_noise(n, 150, 500, -0.6) * roll * 0.25  # so small speakers hear it too
    if near:
        out += shaped_noise(n, 150, 1200, -0.5) * roll ** 2 * 0.35
        m = seconds(1.0)
        out[:m] += shaped_noise(m, 500, 9000, -0.3) * burst(m, 0.002, 0.07) * 1.8
        for _ in range(rng.integers(4, 9)):  # ripping
            m = seconds(rng.uniform(0.04, 0.12))
            place(out, shaped_noise(m, 300, 4000, -0.4) * burst(m, 0.003, 0.03) * rng.uniform(0.5, 1.2),
                  seconds(rng.uniform(0.02, 0.7)))
    return reverb(out, 1.8, 0.3)


def make(name, make_sound):
    if len(sys.argv) < 2 or name in sys.argv[1:]:
        make_sound()


if __name__ == "__main__":
    make("wind", lambda: save("wind", wind()))
    make("rain", lambda: save("rain", rain()))
    make("birds", lambda: save("birds", birds()))
    make("crickets", lambda: save("crickets", crickets()))
    make("water", lambda: save("water", water()))
    make("steps", lambda: [save(f"steps/{surface}-{k}", footstep(surface), loudness)
                           for surface, loudness in FOOTSTEP_LOUDNESS.items() for k in range(1, 5)])
    make("thunder", lambda: [save(f"thunder-{kind}-{k}", thunder(kind == "near"), 0.9)
                             for kind in ("near", "far") for k in (1, 2)])
