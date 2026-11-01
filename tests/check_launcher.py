#!/usr/bin/env python3
"""Run with python3 tests/check_launcher.py; no server changes or dependencies."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
ENV = {**os.environ, "TERM": "dumb", "NO_COLOR": "1", "WF_ANIMATIONS": "0", "WF_PLAIN": "1"}


def run(*args, input="", env=ENV):
    return subprocess.run(args, cwd=ROOT, env=env, input=input, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)


for script in ("install.sh", "script/linux/system/server-audit.sh"):
    assert run("bash", "-n", script).returncode == 0

listing = run("bash", "install.sh", "list")
assert listing.returncode == 0 and "40 TOOLS" in listing.stdout
assert "[ 6]  setup-motd" in listing.stdout  # Existing script numbers stay stable.
assert "[40]  server-audit" in listing.stdout
assert "\x1b" not in listing.stdout + listing.stderr

# Cancel a configuration action, then skip every stage. No script may execute.
guide = run("bash", "install.sh", "guide", input="2\n2\n1\nq\n3\n4\n3\n3\n6\n5\n2\n")
assert guide.returncode == 0, guide.stderr
for stage in range(1, 10):
    assert f"LANGKAH {stage}/9" in guide.stderr
assert "Panduan selesai" in guide.stderr and "Running " not in guide.stderr
assert "Skrip dapat mengubah server" in guide.stderr
invalid = run("bash", "install.sh", "--classic", input="00\ninvalid\nq\n")
assert invalid.returncode == 0 and invalid.stderr.count("Pilihan belum valid") == 2
assert "\x1b" not in invalid.stderr

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)
    mock = directory / "mock"
    mock.write_text('''#!/bin/bash
name=${0##*/}
printf '%s\n' "$name $*" >> "$AUDIT_CALLS"
case "$name" in
  timeout) shift; exec "$@" ;;
  uname) echo Linux ;;
  df)
    echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
    if [ "$AUDIT_CASE" = attention ]; then echo '/dev/test 100 90 10 90% /';
    else echo '/dev/test 100 20 80 20% /'; fi ;;
  *)
    [ "$AUDIT_CASE" != missing ] || exit 1
    case "$name" in
      systemctl) [ "$AUDIT_CASE" != attention ] || echo 'web.service loaded failed failed Web' ;;
      ufw) echo 'Status: active' ;;
      sshd)
        if [ "$AUDIT_CASE" = attention ]; then
          printf 'permitrootlogin yes\npasswordauthentication yes\n'
        else printf 'permitrootlogin no\npasswordauthentication no\n'; fi ;;
      ss) echo 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*' ;;
      *) exit 1 ;;
    esac ;;
esac
''')
    mock.chmod(0o755)
    for name in ("timeout", "uname", "df", "systemctl", "ufw", "firewall-cmd", "nft", "iptables", "sshd", "ss"):
        (directory / name).symlink_to(mock)
    for case in ("healthy", "attention", "missing"):
        env = {**ENV, "PATH": f"{directory}:{os.environ['PATH']}",
               "AUDIT_CASE": case, "AUDIT_CALLS": str(directory / "calls")}
        audit = run("bash", "script/linux/system/server-audit.sh", env=env)
        assert audit.returncode == 0, audit.stderr
        assert "HASIL:" in audit.stdout and "\x1b" not in audit.stdout
        if case == "healthy":
            assert "[OK] Layanan" in audit.stdout and "[INFO] SSH" in audit.stdout
        elif case == "attention":
            for check in ("disk", "inode", "Layanan", "SSH"):
                assert f"[PERHATIAN] {check}" in audit.stdout
        else:
            for check in ("Layanan", "Firewall", "SSH", "Port lokal"):
                assert f"[BELUM_DICEK] {check}" in audit.stdout
            assert "[OK] Layanan" not in audit.stdout
    calls = (directory / "calls").read_text()
    assert "sshd -T" in calls and "timeout 5" in calls
    assert not re.search(r'\b(sudo|install|restart|enable|disable)\b', calls)


def terminal_check(width=40, height=14, interrupt=False):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))
    original = termios.tcgetattr(slave)
    env = {**ENV, "TERM": "xterm", "WF_PLAIN": "0", "LINES": str(height), "COLUMNS": str(width)}
    process = subprocess.Popen(["bash", "install.sh"], cwd=ROOT, env=env,
                               stdin=slave, stdout=slave, stderr=slave)

    def expect(text):
        output = b""
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                output += os.read(master, 65536)
                frame = output.rsplit(b'\x1b[H\x1b[2J', 1)[-1]
                if text.encode() in frame and b'Nomor: pilih langsung' in frame:
                    return output
        raise AssertionError((text, output.decode(errors="replace")))

    try:
        expect("Nomor: pilih langsung")
        if interrupt:
            process.send_signal(signal.SIGINT)
        else:
            os.write(master, b"1")
            expect("LANGKAH 1/9")
            os.write(master, b"\x1b[B\n")
            frame = expect("LANGKAH 2/9")
            plain = re.sub(rb'\x1b\[[0-9;?]*[A-Za-z]', b'', frame)
            assert all(len(line) <= width for line in plain.splitlines()), plain
            os.write(master, b"q")
            expect("WANFORGE - Kelola server")
            os.write(master, b"q")
        try:
            assert process.wait(timeout=5) == (130 if interrupt else 0)
        except subprocess.TimeoutExpired:
            output = os.read(master, 65536) if select.select([master], [], [], 0)[0] else b''
            raise AssertionError(output.decode(errors="replace"))
        restored = termios.tcgetattr(slave)
        # PENDIN is terminal-driver bookkeeping, not a user input mode.
        restored[3] &= ~getattr(termios, "PENDIN", 0)
        original[3] &= ~getattr(termios, "PENDIN", 0)
        assert restored == original, "Terminal state not restored"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)


terminal_check()
terminal_check(width=80, height=24)
terminal_check(interrupt=True)
print("PASS: registry, guided flow, cancellation, audit findings, missing probes, 40/80-column TUI, interrupt, terminal restore")
