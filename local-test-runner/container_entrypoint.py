"""Immutable-image entrypoint; archive input is always treated as hostile.

Image must be digest-pinned in operator config. The archive is copied from a
single read-only host staging file and extracted only into container tmpfs.
"""
from pathlib import Path
import os
import re
import subprocess
import tarfile
import sys

ARCHIVE = Path("/input/source.tar")
WORK = Path("/workspace")
MAX_MEMBER = 40 * 1024 * 1024
MAX_FILES = 5000

def main():
    if os.geteuid() == 0:
        raise RuntimeError("Test image must execute as non-root")
    with tarfile.open(ARCHIVE, "r:") as tar:
        entries = tar.getmembers()
        if len(entries) > MAX_FILES:
            raise RuntimeError("Too many snapshot members")
        seen = set()
        for m in entries:
            p = m.name
            parts = p.rstrip("/").split("/")
            if (p.startswith("/") or "\\" in p or ":" in p or
                    any(x in ("", ".", "..") for x in parts) or
                    any(x.casefold() in (".git", ".env", ".ssh", ".aws") for x in parts) or
                    p in seen or not (m.isfile() or m.isdir()) or m.size > MAX_MEMBER or
                    m.mode & 0o6000):
                raise RuntimeError("Unsafe source archive")
            seen.add(p)
        tar.extractall(WORK, filter="data")
    # Child inherits no auth tokens and cannot download dependencies; all
    # test dependencies must be part of the reviewed immutable image.
    env = {
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "PYTHONPATH": str(WORK),
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONNOUSERSITE": "1",
        "HOME": "/tmp",
        "TMPDIR": "/tmp",
    }
    proc = subprocess.run(
        [sys.executable, "-m", "unittest", "discover",
         "-s", "tests", "-p", "test_*.py"],
        cwd=WORK, env=env, check=False
    )
    return proc.returncode

if __name__ == "__main__":
    raise SystemExit(main())
