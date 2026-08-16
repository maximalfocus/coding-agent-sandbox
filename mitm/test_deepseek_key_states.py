"""Fixture coverage for issue #99: an un-provisioned key store is not an unsafe one.

`status` and `revoke` reached the secret directory's safety check without initialising it, so on the
normal first state of every stack — a fresh Docker volume, root-owned with Docker's default mode —
they reported `secret directory owner or mode is unsafe` and exited 1. Nothing was unsafe and no key
had ever been stored.

That costs twice. It teaches the operator to go fix permissions on a volume that is fine, and it
spends an alarm that should only ever mean something touched the secret directory.

The check itself is a real defence, so the point of this suite is as much what must STILL fail: a
directory owned by someone unexpected, a loosened mode, a symlink, a key file that is not ours. Each
of those has a fixture here beside the benign ones.

Runs as an ordinary user against temporary directories; no container and no key material.

Stated coverage limit: `_secure_dir`'s ownership-transfer branch is guarded by `os.geteuid() == 0`
and only runs in the container, so no fixture here reaches it — mutating it leaves this suite green.
What these fixtures do cover is the non-root repair path and every classification decision. The root
branch is covered by a live run instead: provisioning into a fresh Docker volume leaves
`drwx------ tinyproxy tinyproxy`. Do not read a green run here as evidence about that branch.
"""

import os
import pathlib
import stat
import subprocess
import sys
import tempfile

MANAGER = pathlib.Path(__file__).resolve().parent / "deepseek-key"
FIXTURE_KEY = "fixture-key-not-a-real-deepseek-key"

EXIT_OK = 0
EXIT_UNSAFE = 1
EXIT_NOT_CONFIGURED = 3

results = []


def check(name, condition, detail=""):
    results.append(bool(condition))
    print(f"  {'PASS' if condition else 'FAIL'}  {name}{'' if condition else '  <- ' + str(detail)}")


def run(command, path, stdin=None):
    proc = subprocess.run(
        [sys.executable, str(MANAGER), command, "--path", str(path)],
        input=stdin, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def fresh_volume():
    """What Docker hands a container for a brand-new named volume: 0755, and empty."""
    base = pathlib.Path(tempfile.mkdtemp())
    directory = base / "deepseek"
    directory.mkdir(mode=0o755)
    os.chmod(directory, 0o755)
    return directory / "api-key"


def provisioned():
    path = fresh_volume()
    code, out = run("store", path, stdin=FIXTURE_KEY + "\n")
    assert code == EXIT_OK, f"fixture setup failed: {out}"
    return path


print("== the defect: a never-provisioned store is not an unsafe one ==")
path = fresh_volume()
code, out = run("status", path)
check("status does not report the directory as unsafe", "unsafe" not in out, out.strip())
check("status says no key is configured", "not configured" in out.lower(), out.strip())
check("status uses its own exit code, not the unsafe one",
      code == EXIT_NOT_CONFIGURED, f"exit={code}")

code, out = run("delete", path)
check("revoke does not report the directory as unsafe", "unsafe" not in out, out.strip())
check("revoke says the key is already absent", "already absent" in out.lower(), out.strip())
check("revoke on an untouched store succeeds", code == EXIT_OK, f"exit={code}")

print("== provisioning still works, and repairs the fresh volume ==")
path = fresh_volume()
code, out = run("store", path, stdin=FIXTURE_KEY + "\n")
check("store on a fresh volume succeeds", code == EXIT_OK, out.strip())
check("store tightens the directory to 0700",
      stat.S_IMODE(os.lstat(path.parent).st_mode) == 0o700,
      oct(stat.S_IMODE(os.lstat(path.parent).st_mode)))
check("the key file is 0600", stat.S_IMODE(os.lstat(path).st_mode) == 0o600,
      oct(stat.S_IMODE(os.lstat(path).st_mode)))
code, out = run("status", path)
check("status then reports the key as ready", code == EXIT_OK and "ready" in out, out.strip())

print("== after a revoke, the store is un-provisioned rather than broken ==")
path = provisioned()
code, out = run("delete", path)
check("revoke of a real key succeeds", code == EXIT_OK and "revoked" in out, out.strip())
code, out = run("status", path)
check("status after revoke says no key is configured",
      code == EXIT_NOT_CONFIGURED and "not configured" in out.lower(), f"exit={code} {out.strip()}")
check("status after revoke does not claim the file is unsafe", "unsafe" not in out, out.strip())
code, out = run("delete", path)
check("a second revoke says already absent",
      code == EXIT_OK and "already absent" in out.lower(), out.strip())

print("== what must STILL be refused: this issue must not weaken the check ==")
# A directory that is ours but has been loosened.
path = provisioned()
os.chmod(path.parent, 0o755)
code, out = run("status", path)
check("a loosened directory mode is still unsafe",
      code == EXIT_UNSAFE and "unsafe" in out, f"exit={code} {out.strip()}")

# A loosened key file inside a correct directory.
path = provisioned()
os.chmod(path, 0o644)
code, out = run("status", path)
check("a loosened key file mode is still unsafe",
      code == EXIT_UNSAFE and "unsafe" in out, f"exit={code} {out.strip()}")

# A root-owned directory is only benign while it is EMPTY. A key already sitting in one was not put
# there by this tool.
path = fresh_volume()
path.write_text("planted-by-someone-else")
code, out = run("status", path)
check("a key present in an unclaimed directory is still unsafe",
      code == EXIT_UNSAFE and "unsafe" in out, f"exit={code} {out.strip()}")

# A symlinked directory.
base = pathlib.Path(tempfile.mkdtemp())
(base / "real").mkdir(mode=0o700)
os.symlink(base / "real", base / "deepseek")
code, out = run("status", base / "deepseek" / "api-key")
check("a symlinked secret directory is refused",
      code == EXIT_UNSAFE, f"exit={code} {out.strip()}")

# A symlinked key file, which O_NOFOLLOW must catch rather than read through.
path = provisioned()
target = path.parent / "elsewhere"
target.write_text(FIXTURE_KEY)
os.chmod(target, 0o600)
path.unlink()
os.symlink(target, path)
code, out = run("status", path)
check("a symlinked key file is refused, not followed",
      code == EXIT_UNSAFE, f"exit={code} {out.strip()}")
check("a symlinked key file is not reported as merely un-provisioned",
      code != EXIT_NOT_CONFIGURED, f"exit={code}")

# A directory that is not a directory.
base = pathlib.Path(tempfile.mkdtemp())
(base / "deepseek").write_text("not a directory")
code, out = run("status", base / "deepseek" / "api-key")
check("a non-directory secret path is refused", code == EXIT_UNSAFE, f"exit={code} {out.strip()}")

# revoke must refuse a tampered store rather than report it away. Reporting "already absent" for a
# store it could not verify would leave a real key in place while saying it was gone — the worst
# possible reading, and one a narrower `except` would have produced.
path = provisioned()
os.chmod(path.parent, 0o755)
code, out = run("delete", path)
check("revoke of a tampered store is refused",
      code == EXIT_UNSAFE and "unsafe" in out, f"exit={code} {out.strip()}")
check("revoke of a tampered store does not claim the key is absent",
      "already absent" not in out.lower(), out.strip())
check("revoke of a tampered store leaves the key in place", path.exists())

print("== the two conditions are distinguishable without reading the message ==")
check("un-provisioned and unsafe use different exit codes", EXIT_NOT_CONFIGURED != EXIT_UNSAFE)
check("neither is zero", EXIT_NOT_CONFIGURED != 0 and EXIT_UNSAFE != 0)
# sidecar-entrypoint.sh runs `deepseek-key validate || abort`, so ALLOW_DEEPSEEK must still fail
# closed when no key has been provisioned. A zero here would silently enable the route without one.
path = fresh_volume()
code, out = run("validate", path)
check("validate still fails closed on an un-provisioned store", code != 0, f"exit={code}")
path = provisioned()
code, out = run("validate", path)
check("validate succeeds on a provisioned store", code == EXIT_OK, f"exit={code} {out.strip()}")
check("validate stays quiet when it succeeds", out.strip() == "", out.strip())

print("== no key material is ever printed ==")
path = provisioned()
for command in ("status", "validate"):
    code, out = run(command, path)
    check(f"{command} does not echo the key", FIXTURE_KEY not in out, out.strip())

passed = sum(results)
print(f"\n{passed}/{len(results)} checks passed")
sys.exit(0 if passed == len(results) else 1)
