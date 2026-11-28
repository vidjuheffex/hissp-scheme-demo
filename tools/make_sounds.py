"""Synthesize the ambient sound loops: assets/sounds/*.ogg.

One-off asset tool, not part of the game. Every loop is seamless: noise is
shaped in the frequency domain over the whole loop (so it is periodic), slow
swells are periodic too, and events (drops, chirps, laps) that run past the
end wrap around to the start. The game fades the loops in and out; see
`update-sounds!` in src/world_game.sld.

    uv run --no-project --with numpy --with soundfile tools/make_sounds.py [names...]

With names (wind, rain, birds, crickets, water, river, woods, owls, steps, thunder, cave), only those
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
    band = np.clip((octave - np.log2(lo)) * 3.0 + 0.5, 0, 1) * np.clip(
        (np.log2(hi) - octave) * 3.0 + 0.5, 0, 1
    )
    x = np.fft.irfft(spectrum * band * f**tilt, n)
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
    tail /= np.sqrt(np.sum(tail**2))
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
    soundfile.write(
        OUT / f"{name}.ogg", x.astype(np.float32), RATE, format="OGG", subtype="VORBIS"
    )
    print(f"{name}.ogg  {len(x) / RATE:.2f} s")


def wind():
    n = seconds(40)
    gust = swell(n, 0.12)
    flutter = swell(n, 0.6)
    low = shaped_noise(n, 40, 450, -0.6)
    high = shaped_noise(n, 250, 1600, -0.4)
    whistle = shaped_noise(n, 520, 700)
    return (
        low * (0.45 + 0.55 * gust)
        + high * (0.1 + 0.9 * gust**2 * (0.6 + 0.4 * flutter))
        + whistle * 0.25 * gust**4
    )


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
        for _k in range(rng.integers(2, 5)):
            length = rng.uniform(0.18, 0.35)
            m = seconds(length)
            s = np.linspace(0, 1, m)
            base = pitch * rng.uniform(0.7, 1.0)
            f = base * (
                1 + 0.25 * np.sin(np.pi * s) * rng.choice([-1, 1])
            ) + 40 * np.sin(2 * np.pi * 28 * s * length)
            notes.append((t0, tone(f, hann(m) ** 0.6, (1.0, 0.05))))
            t0 += length + rng.uniform(0.05, 0.2)
    else:  # warble: a wobbly run of notes
        length = rng.uniform(0.5, 0.9)
        m = seconds(length)
        s = np.arange(m) / RATE
        f = (
            pitch
            + 700 * np.sin(2 * np.pi * rng.uniform(18, 30) * s)
            + 500 * np.sin(2 * np.pi * 3 * s)
        )
        notes.append(
            (0.0, tone(f, hann(m) ** 0.4 * (0.6 + 0.4 * np.sin(2 * np.pi * 9 * s))))
        )
    return notes


def birds():
    n = seconds(60)
    out = np.zeros(n)
    for _ in range(7):
        kind = rng.choice(["tweet", "trill", "whistle", "warble"])
        pitch = {"tweet": 3600, "trill": 4200, "whistle": 2800, "warble": 3300}[
            kind
        ] * rng.uniform(0.8, 1.2)
        near = rng.uniform(0.2, 1.0)
        t = rng.uniform(0, 8)
        while t < 60:
            song = np.zeros(seconds(4))
            for start, note in phrase(kind, pitch):
                place(song, note, seconds(start))
            if near < 0.6:  # far off: quieter and duller
                song = lowpass(song, 2500 + 4000 * near)
            place(out, song * near**1.5, seconds(t))
            t += rng.uniform(4, 11)
    out += shaped_noise(n, 150, 2000, -0.8) * 0.01  # the open air
    return reverb(out, 1.4, 0.35)


def thrush(pitch):
    """A song thrush's phrase: a flutey motif of a few notes, repeated."""
    motif = []
    for _ in range(rng.integers(2, 4)):
        length = rng.uniform(0.07, 0.16)
        f0 = pitch * rng.uniform(0.75, 1.3)
        motif.append((length, f0, f0 * rng.uniform(0.8, 1.25)))
    notes, t = [], 0.0
    for _ in range(rng.integers(2, 4)):
        for length, f0, f1 in motif:
            m = seconds(length)
            s = np.linspace(0, 1, m)
            notes.append(
                (t, tone(f0 + (f1 - f0) * s, hann(m) ** 0.5, (1.0, 0.18, 0.04)))
            )
            t += length + 0.03
        t += 0.12
    return notes


def drumming():
    """A woodpecker drumming: a fast roll of knocks on hollow wood, slowing a little."""
    out = np.zeros(seconds(1.4))
    f = rng.uniform(900, 1400)
    t, rate, loud = 0.0, rng.uniform(16, 22), 1.0
    while t < 1.1 and loud > 0.2:
        m = seconds(0.03)
        s = np.arange(m) / RATE
        knock = (
            np.sin(2 * np.pi * f * s) + 0.5 * np.sin(2 * np.pi * f * 2.3 * s)
        ) * np.exp(-s / 0.006)
        place(out, knock * loud, seconds(t))
        t += 1.0 / rate
        rate *= 0.985
        loud *= 0.96
    return out


def woods():
    """A wood by day: thrushes, a woodpecker now and then, and leaves
    stirring overhead, all in a long, soft echo."""
    n = seconds(60)
    out = np.zeros(n)
    for _ in range(4):
        pitch = rng.uniform(1900, 3000)
        near = rng.uniform(0.3, 1.0)
        t = rng.uniform(0, 6)
        while t < 60:
            song = np.zeros(seconds(5))
            for start, note in thrush(pitch):
                place(song, note, seconds(start))
            if near < 0.6:
                song = lowpass(song, 2500 + 4000 * near)
            place(out, song * near**1.5, seconds(t))
            t += rng.uniform(3, 8)
    for t in rng.uniform(0, 60, 2):
        place(out, lowpass(drumming(), 3000) * rng.uniform(0.3, 0.6), seconds(t))
    out += shaped_noise(n, 1200, 7000, -0.5) * 0.012 * (0.3 + 0.7 * swell(n, 0.25) ** 2)
    return reverb(out, 2.2, 0.5)


def hoo(pitch, length):
    """One soft, round owl hoot: a breathy onset, a little scoop up in pitch,
    then a gentle fall as it dies away."""
    m = seconds(length)
    s = np.linspace(0, 1, m)
    t = np.arange(m) / RATE
    f = pitch * (
        0.93 + 0.09 * np.sin(np.pi * np.minimum(s * 2.5, 1.0) / 2) - 0.05 * s**2
    )
    env = (
        np.clip(t / 0.06, 0, 1) ** 2
        * np.clip((m - np.arange(m)) / (0.45 * m), 0, 1) ** 1.5
    )
    voice = tone(f, env, (1.0, 0.22, 0.05))
    breath = (
        shaped_noise(m, pitch * 0.8, pitch * 3, -0.8)
        * env
        * (0.03 + 0.1 * np.exp(-t / 0.04))
    )
    return voice + breath


def owl(near):
    """An owl's call, played now and then by the game: Hoo ... Hoo."""
    out = np.zeros(seconds(5.0))
    pitch = rng.uniform(330, 370) * (1.0 if near else 0.9)
    place(out, hoo(pitch, 0.5), 0)
    place(out, hoo(pitch * 0.98, 0.6), seconds(0.5 + rng.uniform(0.9, 1.2)))
    out = lowpass(out, 1800 if near else 900)
    out = reverb(out, 2.4, 0.4 if near else 0.7)
    out *= np.clip((len(out) - np.arange(len(out))) / seconds(1.0), 0, 1)
    return out


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
            place(
                out,
                chirp_sound * gain * rng.uniform(0.85, 1.0),
                int(offset + k * period),
            )
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
        lap = (
            shaped_noise(m, 70, 900, -0.5) * rush
            + shaped_noise(m, 1200, 6000, -0.3) * fizz * 0.25
        )
        place(out, lap * size, seconds(start))
    return reverb(out, 0.5, 0.2)


def river():
    """A shallow river running over stones: a soft rush under a steady
    babble of bubbles, busier and quieter by turns."""
    n = seconds(24)
    busy = swell(n, 0.25)
    out = shaped_noise(n, 80, 1500, -0.6) * 0.15 * (0.8 + 0.2 * busy)
    out += shaped_noise(n, 1500, 6000, -0.4) * 0.02 * (0.6 + 0.4 * busy)
    for at in rng.uniform(0, 24, 2200):
        k = seconds(at)
        if rng.uniform() > 0.35 + 0.65 * busy[k]:
            continue
        f0 = np.exp(rng.uniform(np.log(350), np.log(2600)))
        loud = 0.1 * rng.lognormal(0, 0.5) * (f0 / 1000.0) ** -0.4
        place(out, bubble(f0, rng.uniform(0.05, 0.3)) * loud, k)
    for at in rng.uniform(0, 24, 60):  # the odd deeper gloop
        place(out, bubble(rng.uniform(150, 350), 0.3) * 0.2, seconds(at))
    return reverb(out, 0.4, 0.15)


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
        place(
            out,
            shaped_noise(m + 64, lo, hi)[:m]
            * burst(m, 0.0003, 0.0008)
            * gain
            * rng.lognormal(0, 0.5),
            at,
        )


def bubble(f0, rise):
    """A ringing air bubble, the sound of water (van den Doel's model): a sine
    at `f0` Hz dying away, smaller bubbles higher and quicker, gliding up in
    pitch by `rise` times the decay rate."""
    decay = 0.13 * f0 + 0.0072 * f0**1.5
    t = np.arange(seconds(5.0 / decay)) / RATE
    return tone(
        f0 * (1 + rise * decay * t),
        np.exp(-decay * t) * np.clip(t / 0.0005, 0, 1),
        (1.0,),
    )


def bubbles(out, count, start, spread, lo, hi, rise, gain):
    """`count` bubbles between `lo` and `hi` Hz, mostly early in the `spread`
    seconds from `start`; the bigger, lower ones louder."""
    for _ in range(count):
        f0 = np.exp(rng.uniform(np.log(lo), np.log(hi)))
        loud = gain * rng.lognormal(0, 0.5) * (f0 / 1000.0) ** -0.4
        place(
            out,
            bubble(f0, rise * rng.uniform(0.5, 1.5)) * loud,
            seconds(start + spread * rng.beta(1.2, 3.0)),
        )


def footstep(surface):
    """One step, heel then toe, on `surface`."""
    out = np.zeros(seconds(0.8 if surface == "water" else 0.45))
    toe = rng.uniform(0.05, 0.085)
    for at, gain in ((0.0, 1.0), (toe, rng.uniform(0.5, 0.8))):
        if surface == "grass":
            m = seconds(0.25)
            place(
                out,
                gain
                * (
                    shaped_noise(m, 50, 260) * burst(m, 0.004, 0.035) * 0.6
                    + shaped_noise(m, 900, 6000, -0.3) * burst(m, 0.01, 0.06)
                    + shaped_noise(m, 2500, 9000) * burst(m, 0.03, 0.09) * 0.3
                ),
                seconds(at),
            )
        elif surface == "dirt":
            m = seconds(0.2)
            place(
                out,
                gain
                * (
                    shaped_noise(m, 60, 400) * burst(m, 0.003, 0.03)
                    + shaped_noise(m, 400, 3000) * burst(m, 0.006, 0.05) * 0.25
                ),
                seconds(at),
            )
            grains(out, int(30 * gain), at, 0.12, 1500, 7000, 0.6)
        elif surface == "rock":
            # A dull, unpitched thud: solid stone doesn't ring, so no tones.
            m = seconds(0.2)
            place(
                out,
                gain
                * (
                    shaped_noise(m, 55, 280, -0.4) * burst(m, 0.001, 0.022)
                    + shaped_noise(m, 250, 1400, -0.6) * burst(m, 0.0008, 0.01) * 0.45
                    + shaped_noise(m, 900, 4500, -0.5) * burst(m, 0.008, 0.045) * 0.07
                ),
                seconds(at),
            )
            grains(out, int(8 * gain), at + 0.005, 0.06, 1800, 5000, 0.25)
        elif surface == "snow":
            m = seconds(0.3)
            place(
                out,
                gain * shaped_noise(m, 40, 200) * burst(m, 0.01, 0.05) * 0.7,
                seconds(at),
            )
            grains(out, int(110 * gain), at, 0.2, 900, 5000, 0.5)
        elif at == 0.0:  # water: the foot plunging in, the leg pulled out, then drips
            m = seconds(0.3)
            place(
                out,
                shaped_noise(m, 1500, 12000, -0.2) * burst(m, 0.002, 0.045) * 0.45,
                0,
            )  # spray
            place(
                out,
                lowpass(shaped_noise(m, 150, 1500, -0.8) * burst(m, 0.015, 0.05), 1200)
                * 0.2,
                0,
            )
            bubbles(out, 160, 0.0, 0.1, 600, 6000, 0.12, 0.25)
            bubbles(out, 3, 0.01, 0.06, 250, 500, 0.3, 0.25)  # gloops
            lift = rng.uniform(0.18, 0.26)
            place(
                out,
                shaped_noise(m, 2000, 12000, -0.2) * burst(m, 0.004, 0.04) * 0.25,
                seconds(lift),
            )
            bubbles(out, 70, lift, 0.1, 700, 5000, 0.15, 0.18)
            bubbles(
                out, 30, 0.06, 0.35, 2500, 7000, 0.2, 0.12
            )  # droplets pattering back
            bubbles(
                out, 8, lift + 0.08, 0.35, 1200, 3500, 0.3, 0.15
            )  # drips plinking back
    fade = np.ones(len(out))
    fade[-seconds(0.05) :] = np.linspace(1, 0, seconds(0.05))
    return out * fade


FOOTSTEP_LOUDNESS = {
    "grass": 0.5,
    "dirt": 0.65,
    "rock": 0.7,
    "snow": 0.55,
    "water": 0.7,
}


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
        roll += loud * np.where(
            s < 0, 0, np.clip(s / rise, 0, 1) * np.exp(-np.maximum(s - rise, 0) / fall)
        )
        at += rng.uniform(0.4, 1.4)
        loud *= rng.uniform(0.55, 0.9)
    roll *= np.clip((n - np.arange(n)) / seconds(1.5), 0, 1)
    out = shaped_noise(n, 22, 160 if not near else 260, -0.9) * roll
    out += (
        shaped_noise(n, 150, 500, -0.6) * roll * 0.25
    )  # so small speakers hear it too
    if near:
        out += shaped_noise(n, 150, 1200, -0.5) * roll**2 * 0.35
        m = seconds(1.0)
        out[:m] += shaped_noise(m, 500, 9000, -0.3) * burst(m, 0.002, 0.07) * 1.8
        for _ in range(rng.integers(4, 9)):  # ripping
            m = seconds(rng.uniform(0.04, 0.12))
            place(
                out,
                shaped_noise(m, 300, 4000, -0.4)
                * burst(m, 0.003, 0.03)
                * rng.uniform(0.5, 1.2),
                seconds(rng.uniform(0.02, 0.7)),
            )
    return reverb(out, 1.8, 0.3)


def cave_space(x, wet, tail, reflect=1.0):
    """`x` heard in a cave: a few irregular early reflections, then a smooth
    diffuse tail `tail` seconds long that darkens as it dies (the highs go
    first, as they do off damp rock). `wet` scales the tail's energy against
    the dry sound's; `reflect` scales the early reflections. Evenly spaced echoes are
    what a pair of parallel walls sounds like, and they rattle; reflections
    here fall at random times and levels, and the tail is noise, never a copy
    of the sound."""
    m = seconds(tail)
    t = np.arange(m) / RATE
    low = shaped_noise(m, 90, 1400, -0.3) * np.exp(-6.9 * t / tail)
    high = shaped_noise(m, 1400, 7000, -0.4) * np.exp(-6.9 * t / (0.4 * tail)) * 0.7
    diffuse = (low + high) * np.clip(
        t / 0.03, 0, 1
    )  # builds up as the reflections thicken
    diffuse *= wet / np.sqrt(np.sum(diffuse**2))
    early = np.zeros(m)
    for at in np.sort(rng.uniform(0.012, 0.14, rng.integers(5, 8))):
        early[seconds(at)] += rng.uniform(0.3, 0.6) * np.exp(-at / 0.09)
    early = reflect * np.convolve(
        early, hann(6) / np.sum(hann(6)), "same"
    )  # rock takes the edge off
    ir = early + diffuse
    n = len(x) + m
    dry = np.zeros(n)
    dry[: len(x)] = x
    out = dry + np.fft.irfft(np.fft.rfft(dry) * np.fft.rfft(ir, n), n)
    fade = np.ones(n)
    fade[-seconds(0.15) :] = np.linspace(1, 0, seconds(0.15))
    return out * fade


def bloop(f0, tau, gain):
    """A water drop's bloop: a round sine at `f0` Hz that starts a little low,
    swoops up to `f0` as the bubble settles, and rings for `tau` seconds."""
    t = np.arange(seconds(7 * tau)) / RATE
    glide = f0 * (1 - 0.2 * np.exp(-t / 0.01))
    return tone(glide, np.exp(-t / tau) * np.clip(t / 0.001, 0, 1) * gain, (1.0, 0.08))


def drip():
    """One drop falling into a still pool, heard in a cave: a low, round bloop
    (a bigger drop rings lower and longer), sometimes with a smaller droplet
    landing a moment later. No click, no high ring: the bright parts sounded
    like chirps."""
    x = np.zeros(seconds(0.6))
    f0 = np.exp(rng.uniform(np.log(380), np.log(800)))
    tau = rng.uniform(0.035, 0.06) * np.sqrt(600 / f0)
    place(x, bloop(f0, tau, 1.0), 0)
    if rng.uniform() < 0.5:
        place(x, bloop(1.5 * f0, 0.6 * tau, 0.35), seconds(rng.uniform(0.12, 0.22)))
    return cave_space(x, 0.35, 0.9, reflect=0.4)  # a drop in a pool: a light room


def cave_step(surface):
    """A step on `surface` ("rock" or "water") as the cave answers it. The
    tail is shorter than the drips' so quick strides don't smear together."""
    dry = footstep(surface)
    return cave_space(dry, 0.9 if surface == "rock" else 0.6, 1.3)


def make_cave():
    """Cave sounds: the drips and the steps in a cave. Own random stream, so
    the other sounds don't change when these are made."""
    global rng
    rng = np.random.default_rng(23)
    for k in (1, 2, 3):
        save(f"cave/drip-{k}", drip(), 0.5)
    for surface in ("rock", "water"):
        for k in range(1, 5):
            save(f"steps/cave-{surface}-{k}", cave_step(surface), 0.65)


def make(name, make_sound):
    if len(sys.argv) < 2 or name in sys.argv[1:]:
        make_sound()


if __name__ == "__main__":
    make("wind", lambda: save("wind", wind()))
    make("rain", lambda: save("rain", rain()))
    make("birds", lambda: save("birds", birds()))
    make("crickets", lambda: save("crickets", crickets()))
    make("water", lambda: save("water", water()))
    make("river", lambda: save("river", river()))
    make("woods", lambda: save("woods", woods()))
    make("owls", lambda: [save(f"owl-{k}", owl(k == 1), 0.8) for k in (1, 2)])
    make(
        "steps",
        lambda: [
            save(f"steps/{surface}-{k}", footstep(surface), loudness)
            for surface, loudness in FOOTSTEP_LOUDNESS.items()
            for k in range(1, 5)
        ],
    )
    make(
        "thunder",
        lambda: [
            save(f"thunder-{kind}-{k}", thunder(kind == "near"), 0.9)
            for kind in ("near", "far")
            for k in (1, 2)
        ],
    )
    make("cave", make_cave)
