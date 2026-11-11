#!/usr/bin/env python3
"""Type a string into the board one character at a time, then press Enter.

The C64 KERNAL scans its keyboard matrix ~60 times per second, so a burst of
characters sent as one HID report loses most of them.  Sending one character
per AT+KARABAS=type: command with a delay works.
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
KARABAS = os.path.join(HERE, "karabas.py")


def send(cmd):
    subprocess.run([sys.executable, KARABAS, cmd], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    if len(sys.argv) < 2:
        print("usage: type_slow.py TEXT [--no-enter] [--delay 0.25]")
        return 1
    text = sys.argv[1]
    delay = 0.25
    if "--delay" in sys.argv:
        delay = float(sys.argv[sys.argv.index("--delay") + 1])
    for ch in text:
        send("AT+KARABAS=type:" + ch)
        time.sleep(delay)
    if "--no-enter" not in sys.argv:
        send("AT+KARABAS=key:enter")
    return 0


if __name__ == "__main__":
    sys.exit(main())
