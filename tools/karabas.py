#!/usr/bin/env python3
"""Send an AT+KARABAS command to the board over /dev/ttyACM0 and print the reply."""
import argparse
import os
import select
import sys
import termios
import time


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    iflag = 0
    oflag = 0
    lflag = 0
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, termios.B115200, termios.B115200, cc])
    return fd


def send(fd, cmd, wait=1.0):
    os.write(fd, (cmd + "\r\n").encode())
    end = time.time() + wait
    data = b""
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            data += chunk
    return data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", nargs="?", default="AT+KARABAS=version")
    ap.add_argument("--port", default="/dev/ttyACM0")
    ap.add_argument("--wait", type=float, default=1.0)
    args = ap.parse_args()
    fd = open_port(args.port)
    try:
        out = send(fd, args.command, args.wait)
        sys.stdout.write(out.decode("utf-8", "replace"))
        if out and not out.endswith(b"\n"):
            print()
    finally:
        os.close(fd)


if __name__ == "__main__":
    main()
