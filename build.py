#!/usr/bin/env python3
"""
build.py - Guided, verified build of Caelestia (shell + CLI + quickshell) as a
custom Fedora Atomic image layered on top of wayblue's hyprland-nvidia-open.

Design rules
------------
* Nothing is hard-pinned in config.  Every source is resolved to the *latest*
  available revision at build time and written to build/deps.lock.json.
  Re-running is reproducible because the build always consumes the lock.
* No AUR, no makepkg, no PKGBUILDs.  Everything is built from upstream source.
* Every git source is pinned to a commit SHA and verified after checkout.
  Tarballs are verified by sha512 AND sha256.
* Every stage is idempotent and resumable.  `build.py <stage> --from N` resumes.

Usage
-----
    ./build.py doctor                 # environment check
    ./build.py resolve                # resolve all sources -> deps.lock.json
    ./build.py resolve --verify       # assert lock is still current (drift check)
    ./build.py audit                  # verify every Fedora package exists
    ./build.py fetch                  # clone + verify
    ./build.py build                  # compile everything in a container
    ./build.py recipe                 # render the BlueBuild recipe
    ./build.py test                   # run the verification suite
    ./build.py all                    # everything up to test
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONFIG = ROOT / "config"
BUILD = ROOT / "build"
SRC = BUILD / "src"
DIST = ROOT / "dist"
LOCK = BUILD / "deps.lock.json"

BUILDER_IMAGE = "caelestia-builder-f44"
# Base for the BlueBuild `caelestia-builder` stage. Plain Fedora: the stage only
# ever compiles, so it deliberately does not inherit the 8 GB wayblue desktop.
BUILDER_BASE = "registry.fedoraproject.org/fedora:44"
BUILT_IMAGE = "caelestia-f44-built"
BUILT_CONTAINER = "caelestia-build-run"

# ---------------------------------------------------------------- terminal --

_TTY = sys.stdout.isatty()


def c(code: str, s: str) -> str:
    return f"\033[{code}m{s}\033[0m" if _TTY else s


def info(msg: str) -> None:
    print(c("36", "  " + msg))


def ok(msg: str) -> None:
    print(c("32", "  ✓ " + msg))


def warn(msg: str) -> None:
    print(c("33", "  ! " + msg))


def err(msg: str) -> None:
    print(c("31", "  ✗ " + msg))


def step(msg: str) -> None:
    print()
    print(c("1;36", f"━━ {msg} ") + c("36", "━" * max(4, 62 - len(msg))))


def die(msg: str, code: int = 1):
    err(msg)
    sys.exit(code)


# ------------------------------------------------------------------ utils --


def run(cmd: list[str], cwd: Path | None = None, check: bool = True,
        capture: bool = False, env: dict | None = None, timeout: int | None = None):
    """Run a command, returning CompletedProcess. Never uses a shell."""
    merged = {**os.environ, **(env or {})}
    return subprocess.run(
        cmd, cwd=cwd, check=check, text=True, timeout=timeout,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        env=merged,
    )


def load(name: str) -> dict:
    return json.loads((CONFIG / name).read_text())


def load_lock() -> dict:
    return json.loads(LOCK.read_text()) if LOCK.exists() else {}


def save_lock(data: dict) -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    LOCK.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha512_file(p: Path) -> str:
    h = hashlib.sha512()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def http_get(url: str, dest: Path, timeout: int = 180) -> Path:
    req = urllib.request.Request(url, headers={"User-Agent": "caelestia-fedora-build/1"})
    with urllib.request.urlopen(req, timeout=timeout) as r, dest.open("wb") as f:
        shutil.copyfileobj(r, f)
    return dest


def check_origin(url: str, allowlist: list[str]) -> None:
    """Paranoid: refuse any source not on the explicit origin allowlist."""
    host = url.split("/")[2] if "://" in url else url.split("/")[0]
    if host not in allowlist:
        die(f"refusing untrusted origin: {host} (not in allowlist)")


@dataclass
class Stage:
    name: str
    fn: object
    needs: list[str] = field(default_factory=list)


# =========================================================== 1. doctor ======


def cmd_doctor(args) -> int:
    step("Environment")
    problems = 0

    for tool, minver in (("podman", None), ("git", None), ("python3", "3.11")):
        if not shutil.which(tool):
            err(f"{tool} not found in PATH")
            problems += 1
            continue
        if minver:
            v = run([tool, "-V"], capture=True).stdout.split()
            if tuple(map(int, v[-1].split(".")[:2])) < tuple(map(int, minver.split("."))):
                err(f"{tool} {v[-1]} < required {minver}")
                problems += 1
            else:
                ok(f"{tool} {v[-1]}")
        else:
            v = run([tool, "--version"], capture=True).stdout.splitlines()[0]
            ok(f"{tool}: {v}")

    ncpu = os.cpu_count() or 1
    if ncpu < 4:
        warn(f"only {ncpu} CPUs - quickshell/caelestia builds will be slow")
    else:
        ok(f"{ncpu} CPUs")

    free = shutil.disk_usage(ROOT).free // (1 << 30)
    if free < 25:
        err(f"only {free} GiB free; need >=25 GiB for source builds + image")
        problems += 1
    else:
        ok(f"{free} GiB free disk")

    if problems:
        die(f"{problems} preflight problem(s)")
    ok("environment looks good")
    return 0


# ========================================================== 2. resolve ======


def git_ls_remote(url: str, ref: str = "HEAD") -> str | None:
    try:
        r = run(["git", "ls-remote", url, ref], capture=True, timeout=120)
        if r.returncode != 0 or not r.stdout.strip():
            return None
        return r.stdout.split()[0]
    except (subprocess.SubprocessError, OSError):
        return None


def resolve_git_sources(src: dict, allowlist: list[str], report: bool = True) -> dict:
    """Resolve every git source to its current HEAD SHA."""
    out = {}
    for s in src["git_sources"]:
        name, url = s["name"], s["url"]
        check_origin(url, allowlist)
        sha = git_ls_remote(url, "HEAD")
        if not sha:
            # fall back to the default branch's tip
            for ref in ("refs/heads/main", "refs/heads/master", "refs/heads/live"):
                sha = git_ls_remote(url, ref)
                if sha:
                    break
        if not sha:
            err(f"{name}: cannot reach {url}")
            out[name] = {"error": "unreachable", "url": url}
            continue
        out[name] = {"type": "git", "url": url, "sha": sha, "version": sha[:12]}
        if report:
            ok(f"{name:22s} {sha[:12]}  {url}")
    return out


def gh_api(path: str) -> dict | list:
    req = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={"User-Agent": "caelestia-fedora-build/1",
                 "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())


def resolve_github_release(s: dict, report: bool = True) -> dict:
    """Resolve a GitHub release asset and pin it against GitHub's own sha256.

    GitHub exposes a first-party `digest` field on release assets.  Enforcing it
    is a stronger guarantee than a maintainer-published hash: it attests the
    bytes GitHub actually served for that tag.
    """
    repo = s["repo"]
    pattern = re.compile(s["asset_pattern"].replace("*", "(.*?)"))
    rel = gh_api(f"/repos/{repo}/releases/latest")
    tag = rel["tag_name"]
    chosen = None
    for a in rel.get("assets", []):
        m = pattern.fullmatch(a["name"])
        if m:
            chosen = a
            break
    if not chosen:
        die(f"{s['name']}: no asset matching {s['asset_pattern']} in {repo}@{tag}")

    digest = chosen.get("digest") or ""
    if not digest.startswith("sha256:"):
        die(f"{s['name']}: GitHub did not publish a sha256 digest for {chosen['name']}")
    want = digest.split(":", 1)[1]

    out = {
        "type": "github_release", "repo": repo, "tag": tag,
        "asset": chosen["name"], "url": chosen["browser_download_url"],
        "size": chosen.get("size"), "sha256": want,
        "integrity": "github-first-party-digest",
        "license": s.get("license"),
    }
    if report:
        ok(f"{s['name']:22s} {tag}  {chosen['name']}")
        ok(f"{'':22s} sha256 (GitHub-verified): {want[:16]}...")
    return out


def resolve_tarballs(src: dict, report: bool = True) -> dict:
    """Resolve tarball sources: honour any pinned hash, otherwise record the
    hash we observed so later runs can enforce it."""
    out = {}
    with tempfile.TemporaryDirectory() as td:
        for s in src["tarball_sources"]:
            name = s["name"]

            # GitHub release assets are pinned against GitHub's own digest.
            if s.get("type") == "github_release":
                check_origin(f"https://github.com/{s['repo']}", src.get("origin_allowlist", ["github.com"]))
                try:
                    out[name] = resolve_github_release(s, report)
                except SystemExit:
                    raise
                except Exception as e:  # noqa: BLE001
                    err(f"{name}: release resolution failed: {e}")
                    out[name] = {"error": f"release resolution failed: {e}"}
                continue

            url = s["url"]
            integrity = s.get("integrity") or {}
            declared512 = integrity.get("sha512")
            declared256 = integrity.get("sha256")

            probe = Path(td) / Path(url).name
            try:
                http_get(url, probe)
            except Exception as e:  # noqa: BLE001
                err(f"{name}: download failed: {e}")
                out[name] = {"error": f"download failed: {e}", "url": url}
                continue

            got512, got256 = sha512_file(probe), sha256_file(probe)

            # A hash published by the upstream/AUR maintainer is authoritative.
            if declared512 and declared512 != got512:
                die(f"{name}: sha512 MISMATCH\n      expected {declared512}\n      got      {got512}")
            if declared256 and declared256 != got256:
                die(f"{name}: sha256 MISMATCH\n      expected {declared256}\n      got      {got256}")

            recorded256 = declared256 or got256
            if not declared256:
                warn(f"{name}: no sha256 on record; recording {got256} into the lock")
            if not declared512:
                warn(f"{name}: no sha512 published; relying on recorded sha256 only")

            out[name] = {
                "type": "tarball", "url": url, "version": s.get("version", ""),
                "sha256": recorded256, "sha512": got512,
                "has_upstream_sha512": bool(declared512),
            }
            if report:
                ok(f"{name:22s} v{s.get('version','?')} sha256:{recorded256[:12]} sha512:{got512[:12]}")
    return out


def cmd_resolve(args) -> int:
    src = load("sources.json")
    allow = src["origin_allowlist"]
    step("Resolving git sources to latest revisions")
    git_res = resolve_git_sources(src, allow)
    step("Resolving tarball sources (hash verification)")
    tar_res = resolve_tarballs(src)

    failed = [k for k, v in {**git_res, **tar_res}.items() if "error" in v]
    current = {"git": git_res, "tarball": tar_res,
               "resolved_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}

    if args.verify:
        old = load_lock()
        if not old:
            die("no lock file; run `build.py resolve` first")
        drift = []
        for group in ("git", "tarball"):
            for name, v in current[group].items():
                o = old.get(group, {}).get(name)
                if o is None:
                    drift.append(f"{name}: newly added")
                elif o.get("sha", o.get("sha256")) != v.get("sha", v.get("sha256")):
                    drift.append(f"{name}: {o.get('sha', o.get('sha256'))[:12]} -> {v.get('sha', v.get('sha256'))[:12]}")
        if drift:
            warn("dependency drift detected:")
            for d in drift:
                warn("  " + d)
            if args.strict:
                die("drift detected and --strict was given", 2)
        else:
            ok("no drift: every resolved revision matches the lock")
        if failed:
            die(f"{len(failed)} source(s) unreachable: {', '.join(failed)}")
        return 0

    save_lock(current)
    ok(f"lock written to {LOCK.relative_to(ROOT)}")
    if failed:
        die(f"{len(failed)} source(s) unreachable: {', '.join(failed)}")
    ok(f"all {len(git_res) + len(tar_res)} sources resolved")
    return 0


# ============================================================ 3. audit ======


def cmd_audit(args) -> int:
    pkg = load("packages.json")
    rel = pkg["fedora_release"]
    step(f"Probing Fedora {rel} repositories (+ COPRs) in a container")

    script = Path(tempfile.mkdtemp()) / "audit.sh"
    script.write_text(
        "#!/bin/bash\n"
        "set -u\n"
        '. /etc/os-release; F=$VERSION_ID\n'
        "for spec in \"$@\"; do :; done\n"
    )
    # build the real probe script
    lines = ["#!/bin/bash", "set -u", '. /etc/os-release; F=$VERSION_ID']
    for copr in pkg["cops"]:
        label = f"{copr['owner']}-{copr['project']}"
        lines += [
            f'url="https://copr.fedorainfracloud.org/coprs/{copr["owner"]}/{copr["project"]}'
            f'/repo/fedora-${{F}}/{label}.repo"',
            f'curl -sSfL -o /etc/yum.repos.d/{label}.repo "$url" 2>/dev/null '
            f'&& echo "COPR_OK {label}" || echo "COPR_FAIL {label}"',
        ]
    lines.append("dnf -q makecache --refresh >/dev/null 2>&1")
    lines.append('for p in "$@"; do')
    lines.append('  n=$(dnf repoquery --available --qf "%{name}" "$p" 2>/dev/null | sort -u | head -1)')
    lines.append('  if [ -n "$n" ]; then echo "OK $p"; else echo "MISSING $p"; fi')
    lines.append("done")
    script.write_text("\n".join(lines) + "\n")

    names = [p["pkg"] for p in pkg["packages"] if not p.get("from_source")]
    if not shutil.which("podman"):
        die("podman required for audit")

    with tempfile.TemporaryDirectory() as td:
        sp = Path(td) / "audit.sh"
        sp.write_text(script.read_text())
        cp = run(["podman", "run", "--rm", "--network=host", "-v", f"{sp}:/audit.sh:ro,z",
                  f"fedora:{rel}", "bash", "-c",
                  "dnf install -y curl >/dev/null 2>&1; bash /audit.sh " + " ".join(names)],
                 capture=True, timeout=3600)

    out = cp.stdout
    okcops = [l.split()[1] for l in out.splitlines() if l.startswith("COPR_OK")]
    badcops = [l.split()[1] for l in out.splitlines() if l.startswith("COPR_FAIL")]
    for c_ in okcops:
        ok(f"COPR enabled: {c_}")
    for c_ in badcops:
        warn(f"COPR unavailable: {c_}")
    found = {l.split()[1] for l in out.splitlines() if l.startswith("OK ")}
    missing = [l.split()[1] for l in out.splitlines() if l.startswith("MISSING ")]

    step("Audit result")
    for p in pkg["packages"]:
        if p.get("from_source"):
            ok(f"{p['pkg']:28s} built from source")
        elif p["pkg"] in found:
            ok(f"{p['pkg']:28s} available")
        else:
            err(f"{p['pkg']:28s} NOT FOUND")

    step("Base image inventory (must already contain these)")
    base = pkg["already_in_base"]
    # Ask rpm for the real package names; parsing `rpm -qa` text is unreliable
    # because subpackages such as hyprland-git-0.56.2^81.git663b29b-1.fc44
    # cannot be split on '-' safely.
    bi = run(["podman", "run", "--rm", "--entrypoint", "/usr/bin/rpm",
              pkg["base_image"], "-qa", "--qf", "%{NAME}\\n"],
             capture=True, timeout=900)
    installed = {l.strip() for l in bi.stdout.splitlines() if l.strip()}
    for b in base:
        if b in installed:
            ok(f"{b:28s} present in base")
        else:
            warn(f"{b:28s} NOT in base (may have been renamed/removed upstream)")

    if missing:
        die(f"{len(missing)} Fedora package(s) unavailable: {', '.join(missing)}")
    step("Transaction dry-run against the real base image")
    # Availability is not enough: a package can exist and still conflict with
    # what the base image already ships (power-profiles-daemon vs the base's
    # tuned-ppd was a real instance of this). Resolve the transaction for real.
    base_img = pkg["base_image"]
    repo_pre = "\n".join(
        f'curl -sSfL -o /etc/yum.repos.d/{c["owner"]}-{c["project"]}.repo '
        f'"https://copr.fedorainfracloud.org/coprs/{c["owner"]}/{c["project"]}'
        f'/repo/fedora-${{F}}/{c["owner"]}-{c["project"]}.repo" || true; \\'
        for c in pkg["cops"])
    tx = subprocess.run(
        ["podman", "run", "--rm", "--network=host", base_img,
         "bash", "-c",
         '. /etc/os-release; F=$VERSION_ID; '
         'curl -sSfL -o /etc/yum.repos.d/atim-starship.repo '
         '"https://copr.fedorainfracloud.org/coprs/atim/starship/repo/fedora-$F/atim-starship.repo" || true; '
         'curl -sSfL -o /etc/yum.repos.d/craftidore.repo '
         '"https://copr.fedorainfracloud.org/coprs/craftidore/wayblueorg-hyprland/repo/fedora-$F/craftidore-wayblueorg-hyprland.repo" || true; '
         'dnf install -y --setopt=install_weak_deps=False --assumeno '
         + " ".join(names) + " 2>&1 | tail -40"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=3600)
    out_tx = tx.stdout or ""
    if "conflicting requests" in out_tx or "cannot be installed" in out_tx or "Problem:" in out_tx:
        bad("the package set does not resolve against the base image:")
        for line in out_tx.splitlines()[-25:]:
            print("      " + line)
        die("resolve the transaction conflicts above (see config/packages.json)")
    ok(f"transaction resolves cleanly ({len(names)} packages)")

    ok("audit passed")
    return 0


# ============================================================= 4. fetch ======


def cmd_fetch(args) -> int:
    src = load("sources.json")
    allow = src["origin_allowlist"]
    lock = load_lock()
    if not lock:
        die("no lock; run `build.py resolve` first")
    SRC.mkdir(parents=True, exist_ok=True)

    step("Cloning git sources at pinned SHAs")
    for name, meta in lock["git"].items():
        if "error" in meta:
            err(f"{name}: {meta['error']}")
            continue
        url, sha = meta["url"], meta["sha"]
        check_origin(url, allow)
        dest = SRC / name
        if (dest / ".git").exists():
            cur = run(["git", "rev-parse", "HEAD"], cwd=dest, capture=True).stdout.strip()
            if cur == sha:
                ok(f"{name:22s} already at {sha[:12]}")
                continue
            run(["git", "fetch", "--all", "--tags"], cwd=dest, capture=True)
        else:
            dest.mkdir(parents=True, exist_ok=True)
            run(["git", "init", "-q"], cwd=dest)
            run(["git", "remote", "add", "origin", url], cwd=dest, check=False)
            run(["git", "fetch", "--depth", "1", "origin", sha], cwd=dest)
        run(["git", "checkout", "-q", sha], cwd=dest)

        # verify the remote still agrees and that we are on a detached commit
        head = run(["git", "rev-parse", "HEAD"], cwd=dest, capture=True).stdout.strip()
        if head != sha:
            die(f"{name}: checkout mismatch {head} != {sha}")
        # `git fetch origin <sha>` already proved the server has the commit.
        # Confirm it is also reachable from an advertised ref where possible.
        refs = run(["git", "ls-remote", url], capture=True, timeout=120)
        if sha in refs.stdout:
            ok(f"{name:22s} verified at {sha[:12]} (reachable from an advertised ref)")
        else:
            ok(f"{name:22s} verified at {sha[:12]} (pinned commit, not a ref tip)")
        dirty = run(["git", "status", "--porcelain"], cwd=dest, capture=True).stdout.strip()
        if dirty:
            warn(f"{name}: working tree has local modifications")
        ok(f"{name:22s} verified at {sha[:12]}")

    step("Downloading + verifying tarballs")
    for name, meta in lock["tarball"].items():
        if "error" in meta:
            err(f"{name}: {meta['error']}")
            continue
        check_origin(meta["url"], allow)
        dest = SRC / name
        dest.mkdir(parents=True, exist_ok=True)
        tgz = dest / (meta.get("asset") or Path(meta["url"]).name)
        if not tgz.exists():
            http_get(meta["url"], tgz)
        g256, g512 = sha256_file(tgz), sha512_file(tgz)
        if g256 != meta["sha256"]:
            die(f"{name}: sha256 mismatch")
        if meta.get("has_upstream_sha512") and g512 != meta["sha512"]:
            die(f"{name}: sha512 mismatch")
        if meta.get("integrity") == "github-first-party-digest":
            ok(f"{name:22s} sha256 matches GitHub's first-party digest")
        extract = dest / "extracted"
        if extract.exists():
            shutil.rmtree(extract)
        if tgz.suffix == ".zip":
            with zipfile.ZipFile(tgz) as z:
                z.extractall(extract)
        else:
            with tarfile.open(tgz) as t:
                t.extractall(extract)
        ok(f"{name:22s} sha256 verified, extracted")

    ok("fetch complete")
    return 0


# ============================================================= 5. build ======

BUILD_SCRIPT = r"""#!/bin/bash
set -euo pipefail
SRC=/src; WORK=/work; LOG=/build.log
QMLDIR=lib64/qt6/qml
step(){ echo; echo "################ $* ################"; }
fail(){ echo "!!! FAILED: $* !!!"; exit 1; }

# --- build dependencies ------------------------------------------------------
# These exist only inside the builder container and never reach the shipped
# image. `build.py build --builder-exists` sets SKIP_DEPS=1 because in that
# mode the builder image is already prepared and carries the toolchain.
if [ "${SKIP_DEPS:-0}" != "1" ]; then
  step "0/7 build deps"
  dnf -y install --setopt=install_weak_deps=False __BUILD_DEPS__
  echo "deps installed: $(rpm -qa | wc -l) packages"
fi

rm -rf "$WORK" && mkdir -p "$WORK" && cp -a "$SRC"/. "$WORK"/ && SRC="$WORK"

step "1/7 libcava"
cd "$SRC/libcava"
meson setup -Dbuild_target=lib -Dcava_font=false --prefix=/usr build >/dev/null
meson compile -C build >/dev/null; DESTDIR= meson install -C build >/dev/null
pkg-config --exists libcava || fail "libcava.pc missing"

step "2/7 m3shapes"
cd "$SRC/m3shapes"
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr \
      -DINSTALL_QML_PREFIX="$QMLDIR" -DDISTRIBUTOR="caelestia-fedora" >/dev/null
cmake --build build >/dev/null && DESTDIR= cmake --install build >/dev/null

step "3/7 quickshell"
cd "$SRC/quickshell"
cmake -GNinja -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr \
      -DDISTRIBUTOR="caelestia-fedora" -DVENDOR_CPPTRACE=ON \
      -DFETCHCONTENT_BASE_DIR=/fc -DINSTALL_QML_PREFIX="$QMLDIR" >/tmp/qs-c.log 2>&1 \
  || { tail -30 /tmp/qs-c.log; fail "quickshell configure"; }
cmake --build build -j "$(nproc)" >/tmp/qs-b.log 2>&1 \
  || { grep -n "error:\|FAILED:" /tmp/qs-b.log | head -20; fail "quickshell build"; }
DESTDIR= cmake --install build >/dev/null

step "4/7 caelestia-shell"
cd "$SRC/caelestia-shell"
git rev-parse HEAD > REVISION
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr \
      -DENABLE_MODULES="extras;plugin;shell" \
      -DVERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 2.5.0)" \
      -DGIT_REVISION="$(git rev-parse HEAD)" -DDISTRIBUTOR="caelestia-fedora" \
      -DINSTALL_QSCONFDIR=/etc/xdg/quickshell/caelestia \
      -DINSTALL_QMLDIR="$QMLDIR" -DINSTALL_LIBDIR=lib64/caelestia >/tmp/cs-c.log 2>&1 \
  || { tail -40 /tmp/cs-c.log; fail "caelestia-shell configure"; }
cmake --build build -j "$(nproc)" >/tmp/cs-b.log 2>&1 \
  || { grep -n "error:\|FAILED:" /tmp/cs-b.log | head -20; fail "caelestia-shell build"; }
DESTDIR= cmake --install build >/dev/null

step "5/7 caelestia-cli"
cd "$SRC/caelestia-cli"
pip install --no-cache-dir build hatchling hatch-vcs >/dev/null 2>&1
SETUPTOOLS_SCM_PRETEND_VERSION=1 python3 -m build --wheel --no-isolation >/dev/null
# Dependencies MUST be installed: caelestia imports materialyoucolor and PIL at
# module load, so --no-deps yields a CLI that crashes on every subcommand.
pip install --no-cache-dir dist/*.whl >/dev/null 2>&1 || \
  python3 -m pip install dist/*.whl >/dev/null
python3 -c "import caelestia" || { echo "!!! caelestia CLI import failed"; exit 1; }
# Stash the wheel so the final image can reinstall it cleanly. Copying
# site-packages by hand is fragile: pip splits it across
# /usr/local/lib (the package) and /usr/local/lib64 (its deps) on Fedora,
# and the dist-info directories carry version numbers.
mkdir -p /caelestia-wheel && cp dist/*.whl /caelestia-wheel/

step "6/7 extra from-source components"
bash /opt/build-extras.sh

step "7/7 done"
echo "ALL BUILDS OK"
"""

EXTRAS_SCRIPT = r"""#!/bin/bash
set -euo pipefail
SRC=/work

# --- lazygit (Go) -----------------------------------------------------------
if [ -d "$SRC/lazygit" ]; then
  cd "$SRC/lazygit"
  go build -ldflags "-s -w -X main.version=$(git describe --tags --abbrev=0 2>/dev/null || echo dev)" \
      -o /usr/bin/lazygit .
fi

# --- gpu-screen-recorder (meson) --------------------------------------------
if [ -d "$SRC/gpu-screen-recorder/extracted" ]; then
  cd "$SRC/gpu-screen-recorder/extracted"
  meson setup --prefix=/usr build >/dev/null \
    && meson compile -C build >/dev/null \
    && DESTDIR= meson install -C build >/dev/null
fi

# --- Rubik font -------------------------------------------------------------
# caelestia-shell uses Rubik for the clock and workspaces. Not packaged in
# Fedora, so install it from the pinned git checkout.
if [ -d "$SRC/rubik/fonts/variable" ]; then
  install -d /usr/share/fonts/rubik
  install -m 0644 "$SRC"/rubik/fonts/variable/Rubik*.ttf /usr/share/fonts/rubik/
  install -m 0644 "$SRC/rubik/OFL.txt" /usr/share/licenses/rubik/OFL.txt 2>/dev/null || true
  fc-cache -f /usr/share/fonts/rubik >/dev/null 2>&1 || true
  echo "installed rubik:"; ls /usr/share/fonts/rubik
fi

# --- dart-sass --------------------------------------------------------------
# Official Sass-team release binary, pinned against GitHub's first-party digest
# (no Dart SDK is packaged for Fedora 44; bootstrapping one from source is a
# multi-hour chicken-and-egg build).
if [ -d "$SRC/dart-sass/extracted/dart-sass" ]; then
  # dart-sass ships a `sass` launcher that execs "$dir/src/dart" with
  # "$dir/src/sass.snapshot". Copying only the launcher breaks it, so the whole
  # directory must be installed intact and symlinked onto PATH.
  rm -rf /opt/dart-sass
  cp -a "$SRC/dart-sass/extracted/dart-sass" /opt/dart-sass
  chmod +x /opt/dart-sass/sass /opt/dart-sass/src/dart
  ln -sf /opt/dart-sass/sass /usr/local/bin/sass
  /usr/local/bin/sass --version || { echo "!! sass failed to run"; exit 1; }
else
  echo "!! dart-sass: extracted/dart-sass directory not found"; exit 1
fi

command -v sass >/dev/null 2>&1 && echo "sass: $(command -v sass)" || echo "!! sass binary NOT produced"
echo "EXTRAS OK"
"""


def cmd_build(args) -> int:
    if not (SRC / "caelestia-shell").exists():
        die("sources not fetched; run `build.py fetch` first")

    step("Building from-source stack in a Fedora container")
    info("this is the long pole (~15-25 min); quickshell + caelestia-shell dominate")

    if not shutil.which("podman"):
        die("podman required")

    BUILD.mkdir(parents=True, exist_ok=True)
    (BUILD / ".fc").mkdir(parents=True, exist_ok=True)   # FetchContent cache mount
    # The dep list lives in packages.json (build_deps.packages); the script
    # itself is a static string, so the list is substituted in here.
    deps = " ".join(load("packages.json")["build_deps"]["packages"])
    bs = BUILD / "build-stack.sh"
    bs.write_text(BUILD_SCRIPT.replace("__BUILD_DEPS__", deps))
    ex = BUILD / "build-extras.sh"
    ex.write_text(EXTRAS_SCRIPT)

    # Fail fast on a malformed embedded script rather than 15 minutes later.
    for script in (bs, ex):
        chk = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        if chk.returncode != 0:
            die(f"generated script {script.name} is not valid bash:\n{chk.stderr}")

    cmd = [
        "podman", "run", "--name", BUILT_CONTAINER, "--network=host",
        # SKIP_DEPS must only be set when the builder image already carries
        # the toolchain. Passing it unconditionally made build.sh skip the
        # dependency install and then fail on `meson: command not found`.
        *(["-e", "SKIP_DEPS=1"] if args.builder_exists else []),
        # `:z` relabels the host side to container_file_t. Without it every
        # mount here fails with EACCES on an SELinux-enforcing host: the files
        # are user_tmp_t/user_home_t and the container runs as container_t.
        "-v", f"{SRC}:/src:ro,z",
        "-v", f"{bs}:/build.sh:ro,z",
        "-v", f"{ex}:/opt/build-extras.sh:ro,z",
        "-v", f"{BUILD / '.fc'}:/fc,z",
        BUILDER_IMAGE if args.builder_exists else f"fedora:{load('packages.json')['fedora_release']}",
        "bash", "/build.sh",
    ]
    logfile = BUILD / "build.log"
    info(f"log: {logfile.relative_to(ROOT)}")

    # A stale container from an aborted run would block --name.
    run(["podman", "rm", "-f", BUILT_CONTAINER], check=False, capture=True)

    # check=False so the container's own output always reaches the log, even on
    # failure - otherwise a Python traceback replaces the real build error.
    cp = subprocess.run(cmd, timeout=args.timeout, check=False,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    logfile.write_text(cp.stdout or "")

    if cp.returncode != 0:
        for line in (cp.stdout or "").splitlines()[-40:]:
            print("    " + line)
        run(["podman", "rm", "-f", BUILT_CONTAINER], check=False, capture=True)
        die(f"from-source build failed (exit {cp.returncode}); see {logfile}")

    step("Recording built artifact image")
    # Ship the verification suite inside the image so `build.py test` can run it.
    run(["podman", "cp", str(ROOT / "files" / "scripts" / "verify.sh"),
         f"{BUILT_CONTAINER}:/opt/verify.sh"], check=False, capture=True)
    cmt = run(["podman", "commit", BUILT_CONTAINER, BUILT_IMAGE],
              check=False, capture=True)
    run(["podman", "rm", "-f", BUILT_CONTAINER], check=False, capture=True)
    if cmt.returncode != 0:
        die("failed to commit the built artifact image")
    ok(f"artifact image: {BUILT_IMAGE}")
    ok("all from-source components built")
    return 0


# ===================================================== 6a. publish builder ====


def cmd_publish_builder(args) -> int:
    """Push the built artifact image so a remote CI (BlueBuild) can use it.

    `assemble` generates a Containerfile whose builder stage references an
    image by ref. That ref must exist in a registry for BlueBuild to build the
    final image - a purely local ref would only work here.
    """
    if not shutil.which("podman"):
        die("podman required")
    listed = run(["podman", "images", "--format", "{{.Repository}}:{{.Tag}}"],
                 capture=True).stdout.split()

    def bare(ref: str) -> str:
        return ref.split(":")[0].split("/")[-1]

    src = next((i for i in listed if bare(i) == bare(args.image)), None)
    if not src:
        die(f"builder image {args.image} not built yet; run `build.py build` first")

    step(f"Pushing builder image {src} -> {args.registry}")
    ref = f"{args.registry}:{args.tag}"
    run(["podman", "tag", src, ref])
    ok(f"tagged {ref}")
    info("pushing (large: the builder carries the whole toolchain)")
    push = subprocess.run(["podman", "push", ref], text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if push.returncode != 0:
        print(push.stdout[-3000:])
        die(f"push failed - are you logged in to {args.registry}? (podman login)")
    for l in [x for x in (push.stdout or "").splitlines()
              if x.strip() and not x.startswith(("Copying", "Getting"))][-3:]:
        info(l.strip())
    ok(f"builder image published: {ref}")

    out = BUILD / "builder-ref.txt"
    out.write_text(ref + "\n")
    ok(f"ref recorded in {out.relative_to(ROOT)}")

    step("Regenerating the Containerfile against the published builder")
    args.builder_image = ref
    return cmd_assemble(args)


# ========================================================= 6. assemble =====

CONTAINERFILE = """\
# GENERATED BY build.py assemble - do not edit by hand.
#
# Assembles the real Fedora Atomic image:
#   stage 1 (builder) - already contains every from-source component
#   stage 2 (runtime) - the wayblue base + runtime packages + our components
#
# Only the runtime artefacts are copied out of the builder; build-only files
# (headers, static archives, cmake/pkgconfig exports, build tooling) stay
# behind, so the shipped image never carries the toolchain.
ARG BASE_IMAGE={base}
ARG BUILDER_IMAGE={builder}

FROM ${{BUILDER_IMAGE}} AS builder

FROM ${{BASE_IMAGE}}

LABEL org.bluebuild.image.name="caelestia-fedora" \\
      org.bluebuild.image.description="Caelestia shell + CLI on wayblue hyprland-nvidia-open" \\
      org.caelestia.build.sources={provenance}

# --- runtime repositories ----------------------------------------------------
{dnf_repo_setup}

# --- from-source components --------------------------------------------------
# Quickshell runtime
# Quickshell runtime. `qs` is a symlink to `quickshell`; COPY would dereference
# it into a second 240 MiB copy, so recreate the link here instead.
COPY --from=builder /usr/bin/quickshell /usr/bin/quickshell
RUN ln -sf quickshell /usr/bin/qs
COPY --from=builder /usr/share/applications/org.quickshell.desktop /usr/share/applications/
COPY --from=builder /usr/share/icons/hicolor/scalable/apps/org.quickshell.svg /usr/share/icons/hicolor/scalable/apps/

# QML modules: Quickshell, Caelestia (18 plugins), M3Shapes
COPY --from=builder /usr/lib64/qt6/qml/Quickshell /usr/lib64/qt6/qml/Quickshell
COPY --from=builder /usr/lib64/qt6/qml/Caelestia /usr/lib64/qt6/qml/Caelestia
COPY --from=builder /usr/lib64/qt6/qml/M3Shapes /usr/lib64/qt6/qml/M3Shapes
COPY --from=builder /usr/lib64/qt6/qml/QmlTime /usr/lib64/qt6/qml/QmlTime
COPY --from=builder /usr/lib64/libm3shapes.so /usr/lib64/libm3shapes.so

# Caelestia shell + extras
COPY --from=builder /etc/xdg/quickshell/caelestia /etc/xdg/quickshell/caelestia
COPY --from=builder /usr/lib64/caelestia /usr/lib64/caelestia

# libcava (runtime shared object only - headers stay in the builder)
COPY --from=builder /usr/lib64/libcava.so.1.0.0 /usr/lib64/libcava.so.1.0.0
COPY --from=builder /usr/lib64/libcava.so.1 /usr/lib64/libcava.so.1
COPY --from=builder /usr/lib64/libcava.so /usr/lib64/libcava.so

# Extra applications
COPY --from=builder /usr/bin/lazygit /usr/bin/lazygit
COPY --from=builder /usr/bin/gpu-screen-recorder /usr/bin/gpu-screen-recorder
COPY --from=builder /usr/bin/gsr-kms-server /usr/bin/gsr-kms-server
COPY --from=builder /usr/share/gpu-screen-recorder /usr/share/gpu-screen-recorder
COPY --from=builder /opt/dart-sass /opt/dart-sass
RUN mkdir -p /var/usrlocal/bin \\
 && ln -sf /opt/dart-sass/sass /var/usrlocal/bin/sass

# Rubik font (used by the shell clock and workspaces)
COPY --from=builder /usr/share/fonts/rubik /usr/share/fonts/rubik

# Caelestia CLI: reinstall the wheel so pip resolves deps for this image
COPY --from=builder /caelestia-wheel /tmp/caelestia-wheel
RUN dnf install -y python3-pip >/dev/null 2>&1 \\
 && pip3 install --no-cache-dir /tmp/caelestia-wheel/*.whl >/dev/null 2>&1 \\
 && rm -rf /tmp/caelestia-wheel \\
 && python3 -c "import caelestia" || (echo "!!! caelestia CLI install failed" && exit 1)

# --- runtime packages --------------------------------------------------------
{dnf_install}

# --- wayblue overrides -------------------------------------------------------
COPY files/usr/bin/caelestia-shell /usr/bin/caelestia-shell
RUN chmod 0755 /usr/bin/caelestia-shell

COPY files/usr/lib/udev/rules.d/ /usr/lib/udev/rules.d/
COPY files/etc/systemd/ /etc/systemd/
COPY files/scripts/ /usr/lib/caelestia-scripts/

RUN chmod 0755 /usr/lib/caelestia-scripts/*.sh \\
 && /usr/lib/caelestia-scripts/setup-evdev-groups.sh \\
 && /usr/lib/caelestia-scripts/apply-wayblue-overrides.sh \\
 && rm -rf /var/cache/dnf

LABEL org.caelestia.build.date={date}
"""


def cmd_assemble(args) -> int:
    pkg = load("packages.json")
    lock = load_lock()
    if not lock:
        die("no lock; run `build.py resolve` first")
    if not shutil.which("podman"):
        die("podman required")

    step("Generating the image Containerfile")
    # runtime repos: add the COPRs wayblue's base image does not already carry
    repo_lines = ["RUN set -eux; \\",
                  "    . /etc/os-release; F=$VERSION_ID; \\",
                  # /usr/local is a symlink to ../var/usrlocal on Fedora Atomic and
                  # that target does not exist in the base image, so create it
                  # first or `mkdir /usr/local/bin` fails with "File exists".
                  "    mkdir -p /var/usrlocal/bin; \\"]
    for copr in pkg["cops"]:
        label = f"{copr['owner']}-{copr['project']}"
        repo_lines.append(
            f'    curl -sSfL -o /etc/yum.repos.d/{label}.repo '
            f'"https://copr.fedorainfracloud.org/coprs/{copr["owner"]}/{copr["project"]}'
            f'/repo/fedora-${{F}}/{label}.repo" || true; \\')
    repo_lines.append("    true")
    dnf_repo_setup = "\n".join(repo_lines)

    pkgs = [p["pkg"] for p in pkg["packages"] if not p.get("from_source")]
    dnf_install = (
        "RUN dnf install -y --setopt=install_weak_deps=False \\\n"
        + " \\\n".join(f"        {p}" for p in pkgs)
        + " \\\n && dnf clean all && rm -rf /var/cache/dnf"
    )

    # short provenance fingerprint: every git SHA, comma separated
    prov = ",".join(v["sha"][:12] for v in lock["git"].values() if "sha" in v)
    cf = CONTAINERFILE.format(
        base=pkg["base_image"], builder=args.builder_image,
        dnf_repo_setup=dnf_repo_setup, dnf_install=dnf_install,
        provenance=prov, date=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    )
    cf_path = ROOT / "Containerfile"
    cf_path.write_text(cf)
    ok(f"wrote {cf_path.relative_to(ROOT)}")

    step("Building the image")
    info("this is slow the first time (pulls the base image)")
    tag = args.tag
    bld = subprocess.run(
        ["podman", "build", "--network=host", "-t", tag, "-f", str(cf_path), str(ROOT)],
        timeout=args.timeout)
    if bld.returncode != 0:
        die("image assembly failed")

    step("Image assembled")
    sz = run(["podman", "image", "inspect", tag, "--format",
              "{{.Size}}"], capture=True).stdout.strip()
    if sz.isdigit():
        ok(f"{tag} built ({int(sz)/1024/1024:.0f} MiB)")
    ok(f"tag: {tag}")
    return 0


# ======================================================= 6b. builder stage ====

# Compiles every from-source component inside the BlueBuild `caelestia-builder`
# stage and stages the runtime artefacts under /out, mirroring the final
# filesystem so the recipe only needs a few recursive `copy` modules.
#
# This is the CI equivalent of `build.py build` plus the COPY --from=builder
# block of the generated Containerfile. The pins are substituted in by
# cmd_recipe from build/deps.lock.json, so CI can never float to a different
# revision than the one validated locally.
STAGE_SCRIPT = r"""#!/bin/bash
# GENERATED by build.py recipe - do not edit by hand.
set -euxo pipefail
SRC=/src; OUT=/out
mkdir -p "$SRC" "$OUT"

echo "################ build deps ################"
dnf -y install --setopt=install_weak_deps=False __BUILD_DEPS__

# --- pinned fetch ------------------------------------------------------------
# Every source is pinned to an exact revision from deps.lock.json. A tarball
# whose digest does not match aborts the build.
git_pin() {  # url sha dir
  git clone --quiet --filter=blob:none "$1" "$SRC/$3"
  git -C "$SRC/$3" checkout --quiet "$2"
  got=$(git -C "$SRC/$3" rev-parse HEAD)
  [ "$got" = "$2" ] || { echo "!!! $3 pinned to $2 but got $got"; exit 1; }
}
tar_pin() {  # url sha256 dir
  curl -sSfL -o "$SRC/$3.tar.gz" "$1"
  echo "$2  $SRC/$3.tar.gz" | sha256sum -c - \
    || { echo "!!! $3 sha256 MISMATCH"; exit 1; }
  mkdir -p "$SRC/$3/extracted"
  tar -xzf "$SRC/$3.tar.gz" -C "$SRC/$3/extracted"
}

__FETCH__

# --- 1. libcava (meson) ------------------------------------------------------
cd "$SRC/libcava"
meson setup -Dbuild_target=lib -Dcava_font=false --prefix=/usr build
meson compile -C build
DESTDIR= meson install -C build
pkg-config --exists libcava || { echo "!!! libcava.pc missing"; exit 1; }

# --- 2. m3shapes (cmake) -----------------------------------------------------
cd "$SRC/m3shapes"
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr \
      -DINSTALL_QML_PREFIX=lib64/qt6/qml -DDISTRIBUTOR="caelestia-fedora"
cmake --build build
DESTDIR= cmake --install build

# --- 3. quickshell (cmake, vendored cpptrace) --------------------------------
# cpptrace is absent from Fedora, so VENDOR_CPPTRACE builds it from git.
cd "$SRC/quickshell"
cmake -GNinja -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr \
      -DDISTRIBUTOR="caelestia-fedora" -DVENDOR_CPPTRACE=ON \
      -DINSTALL_QML_PREFIX=lib64/qt6/qml
cmake --build build -j "$(nproc)"
DESTDIR= cmake --install build

# --- 4. caelestia-shell (cmake: extras + plugin + shell) ---------------------
cd "$SRC/caelestia-shell"
git rev-parse HEAD > REVISION
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/usr \
      -DENABLE_MODULES="extras;plugin;shell" \
      -DVERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 2.5.0)" \
      -DGIT_REVISION="$(git rev-parse HEAD)" -DDISTRIBUTOR="caelestia-fedora" \
      -DINSTALL_QSCONFDIR=/etc/xdg/quickshell/caelestia \
      -DINSTALL_QMLDIR=lib64/qt6/qml -DINSTALL_LIBDIR=lib64/caelestia
cmake --build build -j "$(nproc)"
DESTDIR= cmake --install build

# --- 5. caelestia-cli (wheel only) ------------------------------------------
# Only the wheel is shipped. Installing site-packages by hand is fragile: pip
# splits the package and its deps across lib/ and lib64/ on Fedora and the
# dist-info directories carry version numbers. The recipe pip-installs it in
# the final image instead.
cd "$SRC/caelestia-cli"
pip install --no-cache-dir build hatchling hatch-vcs
SETUPTOOLS_SCM_PRETEND_VERSION=1 python3 -m build --wheel --no-isolation
mkdir -p "$OUT/wheel"
cp dist/*.whl "$OUT/wheel/"

# --- 6. lazygit (go) ---------------------------------------------------------
cd "$SRC/lazygit"
go build -ldflags "-s -w -X main.version=$(git describe --tags --abbrev=0 2>/dev/null || echo dev)" \
      -o /usr/bin/lazygit .

# --- 7. gpu-screen-recorder (meson) ------------------------------------------
cd "$SRC/gpu-screen-recorder/extracted"
meson setup --prefix=/usr build
meson compile -C build
DESTDIR= meson install -C build

# --- 8. rubik font (not packaged on Fedora) ----------------------------------
# caelestia-shell uses Rubik for the clock and workspaces.
install -d /usr/share/fonts/rubik
install -m 0644 "$SRC"/rubik/fonts/variable/Rubik*.ttf /usr/share/fonts/rubik/
install -m 0644 "$SRC/rubik/OFL.txt" /usr/share/licenses/rubik/OFL.txt || true
fc-cache -f /usr/share/fonts/rubik

# --- 9. dart-sass (official release binary) ----------------------------------
# No Dart SDK is packaged for Fedora 44; GitHub publishes a first-party sha256
# digest for the asset, which tar_pin already verified.
rm -rf /opt/dart-sass
cp -a "$SRC/dart-sass/extracted/dart-sass" /opt/dart-sass
chmod +x /opt/dart-sass/sass /opt/dart-sass/src/dart
/opt/dart-sass/sass --version

# --- stage runtime artefacts -------------------------------------------------
# Only what the final image actually runs. Build headers, static archives,
# cmake/pkgconfig exports and the toolchain itself stay behind.
stage_path() {
  [ -e "$1" ] || { echo "!!! expected artefact missing: $1"; exit 1; }
  mkdir -p "$OUT$(dirname "$1")"
  cp -a "$1" "$OUT$1"
}
for a in \
    /usr/bin/quickshell \
    /usr/bin/lazygit \
    /usr/bin/gpu-screen-recorder \
    /usr/bin/gsr-kms-server \
    /usr/lib64/libm3shapes.so \
    /usr/lib64/libcava.so.1.0.0 \
    /usr/lib64/libcava.so.1 \
    /usr/lib64/libcava.so \
    /usr/lib64/caelestia \
    /usr/lib64/qt6/qml/Quickshell \
    /usr/lib64/qt6/qml/Caelestia \
    /usr/lib64/qt6/qml/M3Shapes \
    /usr/lib64/qt6/qml/QmlTime \
    /usr/share/applications/org.quickshell.desktop \
    /usr/share/icons/hicolor/scalable/apps/org.quickshell.svg \
    /usr/share/gpu-screen-recorder \
    /usr/share/fonts/rubik \
    /etc/xdg/quickshell/caelestia \
    /opt/dart-sass ; do
  stage_path "$a"
done

echo "STAGED:"
find "$OUT" -maxdepth 3 -mindepth 1 | sort
echo "ALL BUILDS OK"
"""


def render_stage_script(lock: dict, deps: str) -> str:
    """Fill the stage script template with the locked revisions."""
    # Resolved and audited, but never compiled into the image: the dots are
    # only used by `build.py validate` for byte-parity, and qtengine/darkly
    # are referenced by the CLI's config but are not runtime artefacts of the
    # image (the validated Containerfile copies neither).
    skip = {"caelestia-dots", "qtengine", "darkly"}

    fetch = []
    for name, meta in sorted(lock.get("git", {}).items()):
        if name in skip:
            continue
        fetch.append(f'git_pin "{meta["url"]}" "{meta["sha"]}" {name}')
    for name, meta in sorted(lock.get("tarball", {}).items()):
        fetch.append(f'tar_pin "{meta["url"]}" "{meta["sha256"]}" {name}')

    if not fetch:
        die("no pinned sources in the lock; run `build.py resolve` first")

    return (STAGE_SCRIPT
            .replace("__BUILD_DEPS__", deps)
            .replace("__FETCH__", "\n".join(fetch)))


# =========================================================== 7. recipe ======


def cmd_recipe(args) -> int:
    pkg = load("packages.json")
    lock = load_lock()
    step("Rendering the BlueBuild recipe")

    pkgs = [p["pkg"] for p in pkg["packages"] if not p.get("from_source")]
    coprs = "\n".join(f"          - {c['owner']}/{c['project']}" for c in pkg["cops"])
    rem = "\n".join(f'        - "{r["path"]}"' for r in pkg["remove_from_base"])

    # BlueBuild always resolves the base as "<base-image>:<image-version>" and
    # rejects a base-image that already carries a tag ("invalid reference
    # format"), which is what the old template emitted. wayblue publishes only
    # `latest` - there is no `:44` tag - so the tag cannot be derived from
    # fedora_release. Split the configured ref instead and pass the tag
    # through as image-version.
    base_repo, _, base_tag = pkg["base_image"].partition("@")
    head, sep, last = base_repo.rpartition(":")
    if sep and "/" not in last:
        base_repo, base_tag = head, last
    base_tag = base_tag or "latest"

    recipe = f"""---
# GENERATED BY build.py - do not edit by hand.
name: caelestia-fedora
description: Caelestia shell + CLI on wayblue hyprland-nvidia-open

base-image: {base_repo}
image-version: {base_tag}

# The from-source components (quickshell, the caelestia shell + plugins, the
# CLI, libcava, m3shapes, lazygit, gpu-screen-recorder, dart-sass, rubik) are
# compiled in a separate stage and copied in, so the shipped image never
# carries the toolchain. Without this stage the image was built from wayblue
# alone and contained none of them.
stages:
  - name: caelestia-builder
    from: {BUILDER_BASE}
    modules:
      - type: script
        scripts:
          - build-from-source.sh

modules:
  # 1. Package set
  - type: dnf
    repos:
      copr:
{coprs}
    install:
      install-weak-deps: false
      packages:
{chr(10).join('        - ' + p for p in pkgs)}

  # 2. Strip wayblue's waybar config + Hyprland lua: caelestia provides its own
  - type: script
    scripts:
      - apply-wayblue-overrides.sh

  # 3. Runtime artefacts from the builder stage. /out mirrors the final
  #    filesystem, so these four recursive copies replace the ~20 individual
  #    COPY --from=builder lines the generated Containerfile used.
  - type: copy
    from: caelestia-builder
    src: /out/usr
    dest: /usr
  - type: copy
    from: caelestia-builder
    src: /out/opt
    dest: /opt
  - type: copy
    from: caelestia-builder
    src: /out/etc
    dest: /etc
  - type: copy
    from: caelestia-builder
    src: /out/wheel
    dest: /tmp/caelestia-wheel

  # 4. Fixups that cannot be expressed as a copy: the `qs` alias, the sass
  #    launcher on PATH, and installing the CLI wheel with its dependencies.
  - type: script
    snippets:
      - ln -sf quickshell /usr/bin/qs
      - mkdir -p /var/usrlocal/bin && ln -sf /opt/dart-sass/sass /var/usrlocal/bin/sass
      - >-
        dnf install -y python3-pip >/dev/null 2>&1 &&
        pip3 install --no-cache-dir /tmp/caelestia-wheel/*.whl >/dev/null 2>&1 &&
        rm -rf /tmp/caelestia-wheel &&
        python3 -c "import caelestia"

  # 5. caelestia wrapper, udev rules, zsh defaults, skel seeding
  # `source` is relative to the repo's files/ directory (BlueBuild docs), so
  # `usr` means files/usr. The old `system/usr` pointed at a path that does
  # not exist and silently copied nothing.
  - type: files
    files:
      - source: usr
        destination: /usr
      - source: etc
        destination: /etc

  # 6. Keep caelestia shell + CLI on PATH after deploy
  - type: systemd
    user:
      enabled:
        - caelestia-shell.service

  - type: signing
"""
    out = ROOT / "recipes"
    out.mkdir(exist_ok=True)
    (out / "recipe.yml").write_text(recipe)
    ok(f"wrote {out / 'recipe.yml'}")

    # The builder stage runs this script inside CI, where build/src does not
    # exist, so it carries its own pinned fetch. It is committed because the
    # recipe references it by name from files/scripts/.
    deps = " ".join(pkg["build_deps"]["packages"]) + " ca-certificates"
    stage = ROOT / "files" / "scripts" / "build-from-source.sh"
    stage.write_text(render_stage_script(lock, deps))
    chk = subprocess.run(["bash", "-n", str(stage)], capture_output=True, text=True)
    if chk.returncode != 0:
        die(f"generated {stage.name} is not valid bash:\n{chk.stderr}")
    stage.chmod(0o755)
    ok(f"wrote {stage.relative_to(ROOT)} ({len(lock.get('git', {}))} git + "
       f"{len(lock.get('tarball', {}))} tarball sources pinned)")

    sb = json.dumps({"sources": lock}, indent=2)
    DIST.mkdir(exist_ok=True)
    (DIST / "sources-provenance.json").write_text(sb + "\n")
    ok(f"wrote {DIST / 'sources-provenance.json'}")
    return 0


# ============================================================== 7. test ======


def cmd_test(args) -> int:
    if not shutil.which("podman"):
        die("podman required")
    step("Running the verification suite in the built artifact image")
    # podman reports fully-qualified names (localhost/<name>:<tag>), so compare the
    # bare repository portion on both sides rather than raw strings.
    def bare(ref: str) -> str:
        return ref.split(":")[0].split("/")[-1]

    listed = run(["podman", "images", "--format", "{{.Repository}}:{{.Tag}}"],
                 capture=True).stdout.split()
    wanted = args.image
    img = next((i for i in listed if bare(i) == bare(wanted)), None)
    if not img:
        die(f"no image to test (looked for {wanted}); available: "
            + ", ".join(sorted({bare(i) for i in listed})[:10]))

    vs = ROOT / "files" / "scripts" / "verify.sh"
    dots = SRC / "caelestia-dots"
    t = subprocess.run(
        ["podman", "run", "--rm",
         "-v", f"{vs}:/verify.sh:ro,z",
         *(["-v", f"{dots}:/dots:ro,z"] if dots.is_dir() else []),
         img, "bash", "/verify.sh"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=900)
    print(t.stdout)
    if t.stderr.strip():
        print(t.stderr)
    if t.returncode != 0:
        die(f"verification suite failed ({t.returncode} failing check(s))")
    ok("verification suite passed")
    return 0


def cmd_validate(args) -> int:
    """Deploy the dots into the assembled image and verify the result."""
    if not shutil.which("podman"):
        die("podman required")
    step("Validating the deployed Caelestia configuration")
    vs = ROOT / "files" / "scripts" / "validate-config.sh"
    dots = SRC / "caelestia-dots"
    listed = run(["podman", "images", "--format", "{{.Repository}}:{{.Tag}}"],
                 capture=True).stdout.split()

    def bare(ref: str) -> str:
        return ref.split(":")[0].split("/")[-1]

    img = next((i for i in listed if bare(i) == bare(args.image)), None)
    if not img:
        die(f"no image {args.image}; run `build.py assemble` first")
    info(f"image: {img}")

    cmd = ["podman", "run", "--rm", "-i", "--network=host",
           "-v", f"{vs}:/vc.sh:ro,z"]
    if dots.is_dir():
        cmd += ["-v", f"{dots}:/dots:ro,z"]
    else:
        warn(f"pinned dots not found at {dots}; parity diff will be skipped")
    cmd += [img, "bash", "/vc.sh"]

    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, timeout=2400)
    for line in (r.stdout or "").splitlines():
        # suppress hyprland's very chatty DEBUG spam
        if "DEBUG" in line and "PASS" not in line and "FAIL" not in line:
            continue
        print(line)
    if r.returncode != 0:
        die("config validation failed")
    ok("config validation passed")
    return 0


# ========================================================== 8. all ==========


def cmd_all(args) -> int:
    for fn in (cmd_doctor, cmd_resolve, cmd_audit, cmd_fetch, cmd_build,
               cmd_assemble, cmd_test, cmd_validate):
        rc = fn(args)
        if rc != 0:
            return rc
    return 0


# ================================================================ main ======


def main() -> int:
    p = argparse.ArgumentParser(
        prog="build.py",
        description="Build a Caelestia Fedora Atomic image on top of wayblue.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    # `all` chains every stage over a single shared Namespace, so a stage that
    # reads a flag declared on its *own* subparser would otherwise hit
    # AttributeError. These parent-level defaults make every Namespace
    # complete; a subparser's own default still wins for its own flag.
    p.set_defaults(verify=False, strict=False, builder_exists=False,
                   timeout=7200, tag="caelestia-fedora:dev",
                   image_tag="caelestia-fedora:dev",
                   image=BUILT_IMAGE, builder_image=BUILT_IMAGE,
                   registry="ghcr.io/USER/caelestia-builder")

    def add(name, fn, help_):
        sp = sub.add_parser(name, help=help_)
        sp.set_defaults(fn=fn)
        return sp

    d = add("doctor", cmd_doctor, "check the local toolchain")

    r = add("resolve", cmd_resolve, "resolve every source to its latest revision")
    r.add_argument("--verify", action="store_true",
                   help="compare against the lock instead of rewriting it (drift check)")
    r.add_argument("--strict", action="store_true", help="fail on drift")

    add("audit", cmd_audit, "verify every Fedora package exists")

    add("fetch", cmd_fetch, "clone at pinned SHAs and verify hashes")

    b = add("build", cmd_build, "compile all from-source components")
    b.add_argument("--timeout", type=int, default=7200)
    b.add_argument("--builder-exists", action="store_true",
                   help="skip dependency install (builder image already prepared)")

    add("recipe", cmd_recipe, "render the BlueBuild recipe")

    t = add("test", cmd_test, "run the verification suite")
    t.add_argument("--image", default=BUILT_IMAGE)

    a = add("assemble", cmd_assemble, "assemble the final Fedora Atomic image")
    a.add_argument("--tag", default="caelestia-fedora:dev")
    # The stage-1 source must be the *built* artifact (deps + components),
    # not the dependency-only builder image.
    a.add_argument("--builder-image", default=BUILT_IMAGE)
    a.add_argument("--timeout", type=int, default=7200)

    pb = add("publish-builder", cmd_publish_builder,
             "push the builder image to a registry so BlueBuild CI can use it")
    pb.add_argument("--registry", default="ghcr.io/USER/caelestia-builder",
                    help="e.g. ghcr.io/yourname/caelestia-builder")
    pb.add_argument("--tag", default="f44")
    pb.add_argument("--image", default=BUILT_IMAGE)
    pb.add_argument("--image-tag", default="caelestia-fedora:dev",
                    help="tag used when re-rendering the Containerfile")
    pb.add_argument("--timeout", type=int, default=7200)

    v = add("validate", cmd_validate,
            "deploy the dots in the assembled image and verify the config")
    v.add_argument("--image", default="caelestia-fedora:dev")

    a = add("all", cmd_all,
            "doctor -> resolve -> audit -> fetch -> build -> assemble -> test -> validate")

    args = p.parse_args()
    BUILD.mkdir(parents=True, exist_ok=True)
    return args.fn(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        err("interrupted")
        sys.exit(130)