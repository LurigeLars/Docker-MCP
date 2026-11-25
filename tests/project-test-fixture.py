"""Run only inside a disposable synthetic test container."""
import os
from pathlib import Path
import socket
import sys

assert os.getuid() == 65532 and os.getgid() == 65532
status = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines() if ":" in line)
assert status["NoNewPrivs"].strip() == "1"
assert int(status["CapEff"].strip(), 16) == 0
assert int(status["CapPrm"].strip(), 16) == 0
assert int(status["Seccomp"].strip()) == 2
assert not Path("/var/run/docker.sock").exists()
assert not Path("/control").exists()
assert set(os.listdir("/sys/class/net")) == {"lo"}
try:
    Path("/tmp/runner-probe").write_text("ok")
    Path("/tmp/runner-probe").unlink()
except OSError:
    sys.exit(21)
try:
    Path("/unexpected-write").write_text("no")
except OSError:
    pass
else:
    sys.exit(22)
assert not Path("/unexpected-write").exists()
with socket.socket() as s:
    s.settimeout(0.5)
    try:
        s.connect(("192.0.2.1", 443))
    except OSError:
        pass
    else:
        sys.exit(23)
sys.exit(7 if sys.argv[1:] == ["fail"] else 0)
