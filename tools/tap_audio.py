#!/usr/bin/env python3
"""Play a C64 .tap image as cassette audio.

The C64 tape waveform is a square wave whose period is the pulse length stored
in the TAP file (one whole wave per byte in TAP v0/v1).  This tool turns that
pulse train into 16-bit mono PCM and either plays it through ALSA/PulseAudio or
writes a WAV file for a phone or another player.

Usage:
    python3 tools/tap_audio.py file.tap
    python3 tools/tap_audio.py file.tap --wav file.wav
    python3 tools/tap_audio.py file.tap --device plughw:1,0 --delay 3

TAP v0/v1 (C64) is supported.  TAP v2 is a C16/Plus4 half-wave format and is
rejected here.

The audio starts after --delay seconds of silence, so there is time to press
LOAD and SPACE on the C64.
"""

import argparse
import shutil
import struct
import subprocess
import sys
import wave
from pathlib import Path

PAL_CLOCK = 985248.0
MAGIC = b"C64-TAPE-RAW"


def fail(msg: str) -> "None":
    print("tap_audio: " + msg, file=sys.stderr)
    raise SystemExit(1)


def read_tap(path: Path):
    raw = path.read_bytes()
    if len(raw) < 20 or raw[:12] != MAGIC:
        fail(f"{path}: not a C64 .tap file (missing C64-TAPE-RAW header)")

    version = raw[12]
    if version not in (0, 1):
        fail(f"{path}: TAP version {version} is not supported (need 0 or 1)")

    size = int.from_bytes(raw[16:20], "little")
    data = raw[20:]
    if 0 < size <= len(data):
        data = data[:size]
    elif size > len(data):
        fail(f"{path}: truncated TAP data (header says {size} bytes, file has {len(data)})")

    pulses = []
    i = 0
    while i < len(data):
        b = data[i]
        i += 1
        if b != 0:
            pulses.append(b * 8)
            continue

        if version == 0:
            # v0: 0 is the overflow/long pulse (>= 256 * 8 cycles).
            pulses.append(256 * 8)
        else:
            # v1: 0 is followed by a 24-bit little-endian cycle count.
            if i + 3 > len(data):
                fail(f"{path}: truncated 24-bit pulse at offset {i + 19}")
            pulses.append(data[i] | (data[i + 1] << 8) | (data[i + 2] << 16))
            i += 3

    if not pulses:
        fail(f"{path}: no pulses")
    return version, pulses


def samples_for(pulses, rate: int, clock: float, delay: float, amplitude: int):
    """Yield 16-bit little-endian PCM chunks.

    v0/v1: each pulse is one full wave, low half then high half.  The next
    pulse starts with a high->low transition, which is what the C64's FLAG
    input times.
    """
    silence = int(round(delay * rate))
    amp_lo = -amplitude
    amp_hi = amplitude
    level = 1

    def pack_level(n, value):
        if n <= 0:
            return b""
        sample = struct.pack("<h", value)
        return sample * n

    # Lead-in silence.  The level before the first pulse is high.
    remaining = silence
    while remaining > 0:
        n = min(remaining, rate // 5)
        yield struct.pack("<h", 0) * n
        remaining -= n

    cycle = 0.0
    for cycles in pulses:
        # Exact fractional sample position, no drift over a long tape.
        cycle += cycles * rate / clock
        n = int(round(cycle))
        cycle -= n
        if n < 2:
            n = 2
        half = n // 2
        if half < 1:
            half = 1
        other = n - half
        # low first, then high; level starts high, so the first sample is a
        # negative edge.
        yield pack_level(half, amp_lo)
        yield pack_level(other, amp_hi)


def main() -> None:
    ap = argparse.ArgumentParser(description="Play a C64 .tap as cassette audio")
    ap.add_argument("tap", type=Path)
    ap.add_argument("--wav", type=Path, help="write a WAV instead of playing")
    ap.add_argument("--rate", type=int, default=48000, help="sample rate (default 48000)")
    ap.add_argument("--clock", type=float, default=PAL_CLOCK,
                    help=f"C64 clock in Hz (default PAL {PAL_CLOCK:.0f})")
    ap.add_argument("--delay", type=float, default=3.0,
                    help="seconds of silence before the first pulse (default 3)")
    ap.add_argument("--volume", type=int, default=80,
                    help="volume 0..100 (default 80)")
    ap.add_argument("--device", help="ALSA device for aplay, e.g. plughw:1,0")
    ap.add_argument("--max-seconds", type=float, default=0.0,
                    help="stop after this many seconds of audio (0 = whole tape)")
    args = ap.parse_args()

    if not 0 <= args.volume <= 100:
        fail("--volume must be 0..100")
    if args.rate < 8000 or args.rate > 192000:
        fail("--rate must be 8000..192000")
    if args.delay < 0 or args.max_seconds < 0:
        fail("--delay and --max-seconds must not be negative")

    version, pulses = read_tap(args.tap)
    amp = max(1, int(32767 * args.volume / 100))

    print(f"{args.tap}: TAP v{version}, {len(pulses)} pulses, "
          f"{sum(pulses) / args.clock:.1f} s tape time", file=sys.stderr)

    samples = samples_for(pulses, args.rate, args.clock, args.delay, amp)

    if args.wav:
        with wave.open(str(args.wav), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(args.rate)
            written = 0
            for chunk in samples:
                w.writeframes(chunk)
                written += len(chunk)
                if args.max_seconds and written >= int(args.max_seconds * args.rate) * 2:
                    break
        print(f"wrote {args.wav} ({written // 2 / args.rate:.1f} s)", file=sys.stderr)
        return

    player = shutil.which("aplay")
    if not player:
        fail("aplay not found; use --wav and play it with any audio player")

    cmd = [player, "-q", "-f", "S16_LE", "-r", str(args.rate), "-c", "1"]
    if args.device:
        cmd += ["-D", args.device]
    print("playing via: " + " ".join(cmd), file=sys.stderr)
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    written = 0
    try:
        for chunk in samples:
            proc.stdin.write(chunk)
            written += len(chunk)
            if args.max_seconds and written >= int(args.max_seconds * args.rate) * 2:
                break
    except BrokenPipeError:
        pass
    finally:
        try:
            proc.stdin.close()
        except BrokenPipeError:
            pass
        rc = proc.wait()
    if rc != 0:
        fail(f"aplay exited with status {rc}")


if __name__ == "__main__":
    main()
