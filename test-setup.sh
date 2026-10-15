#!/usr/bin/env bash
# test-setup.sh - exercise setup.py's non-interactive logic against real data.
# Verifies the registry-probing and signature-detection code paths, which are
# the parts most likely to silently break.
set -uo pipefail
cd "$(dirname "$0")"

FAILED=0
ok()  { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
bad() { printf '\033[31m  ✗ %s\033[0m\n' "$*"; FAILED=$((FAILED+1)); }
step(){ printf '\n\033[1;36m━━ %s \033[0m\n' "$*"; }

step "syntax"
for f in setup.py build.py; do
  python3 -c "import ast;ast.parse(open('$f').read())" && ok "$f parses" || bad "$f parse error"
done

step "state machine / resume logic"
python3 - <<'PY'
import json, os, sys, tempfile, pathlib
sys.path.insert(0, '.')
import setup
# exercise load/save round-trip and phase labels
d = tempfile.mkdtemp()
setup.STATE = pathlib.Path(d) / "setup-state.json"
assert setup.load_state() == {}, "fresh state must be empty"
setup.save_state({"phase": 3, "image": "ghcr.io/u/r", "digest": "sha256:abc"})
s = setup.load_state()
assert s["phase"] == 3 and s["image"] == "ghcr.io/u/r", f"round-trip failed: {s}"
print("  state round-trip OK")
# a committed image with a real digest, as ghcr would report
setup.save_state({"phase": 4, "image": "ghcr.io/u/r",
                  "digest": "sha256:" + "ab"*32})
s = setup.load_state()
assert s["digest"].startswith("sha256:")
print("  digest persisted OK")
PY
[ $? -eq 0 ] && ok "state persistence" || bad "state persistence"

step "ostree detection"
python3 - <<'PY'
import sys
sys.path.insert(0, '.')
import setup
r = setup.is_ostree_system()
print(f"  is_ostree_system() -> {r}")
assert isinstance(r, bool)
PY
[ $? -eq 0 ] && ok "is_ostree_system() returns a bool" || bad "is_ostree_system()"

step "live registry probe: ghcr.io (public, real image)"
python3 - <<'PY'
import sys
sys.path.insert(0, '.')
import setup
# wayblueorg/hyprland-nvidia-open is a public signed image
d, signed = setup.fetch_manifest_digest("ghcr.io", "wayblueorg/hyprland-nvidia-open", "latest")
print(f"  digest = {d}")
print(f"  signed = {signed}")
assert d and d.startswith("sha256:"), "no digest returned for a known public image"
assert signed is True, "wayblue is signed by BlueBuild; detection failed"
print("  probe + signature detection OK")
PY
[ $? -eq 0 ] && ok "registry probe against ghcr.io" || bad "registry probe"

step "registry probe: nonexistent repo must fail cleanly"
python3 - <<'PY'
import sys
sys.path.insert(0, '.')
import setup
d, _ = setup.fetch_manifest_digest("ghcr.io", "this-org-does-not-exist-xyz/nope", "latest")
assert d is None, f"expected None for a missing repo, got {d}"
print("  missing repo handled gracefully")
PY
[ $? -eq 0 ] && ok "missing repo handled" || bad "missing repo handling"

step "generated CI files are valid"
python3 - <<'PY'
import sys
sys.path.insert(0, '.')
import setup
# The template uses placeholders substituted at write time, so the final
# GitHub expressions must NOT be present in the template itself.
wf = setup.BLUEBUILD_WORKFLOW
assert "__GITHUB_ACTOR__" in wf and "__GITHUB_TOKEN__" in wf, "placeholders missing"
assert "${{ github.actor }}" not in wf, "expression was baked into the template"
assert "${{{{" not in wf, "double-braced expression leaked into the template"
assert "bluebuild/bluebuild-action@v1" in wf
assert "id-token: write" in wf, "keyless signing needs id-token: write"
assert "permissions:" in wf and "packages: write" in wf, "needs packages: write"

# Render exactly as phase1 does and validate the result.
rendered = (wf.replace("__GITHUB_ACTOR__", "${{ github.actor }}")
              .replace("__GITHUB_TOKEN__", "${{ secrets.GITHUB_TOKEN }}")
              .replace("__REPO__", "owner/name"))
assert "${{ github.actor }}" in rendered
assert "ghcr.io/owner/name/${{ IMAGE_NAME }}" in rendered
try:
    import yaml
    d = yaml.safe_load(rendered)
    # YAML 1.1 turns an unquoted `on:` into the boolean True, which breaks the
    # GitHub trigger. Assert the key is literally "on".
    assert "on" in d, f"trigger key missing - got {list(d.keys())} (is 'on' quoted?)"
    assert True not in d, "unquoted 'on' parsed as boolean True - workflow is broken"
    print("  rendered workflow is valid YAML and the 'on:' trigger is intact")
except ImportError:
    print("  (pyyaml not installed; expression checks only)")
b = setup.BLUEPRINT
assert "blueprint:" in b and "name:" in b
print("  templates OK")
PY
[ $? -eq 0 ] && ok "CI templates" || bad "CI templates"

step "CI templates parse as real YAML (via container with pyyaml)"
cat > /tmp/_yamlcheck.py <<'PYEOF'
import yaml, sys
sys.path.insert(0, '/w')
import setup
wf = (setup.BLUEBUILD_WORKFLOW
      .replace("__GITHUB_ACTOR__", "${{ github.actor }}")
      .replace("__GITHUB_TOKEN__", "${{ secrets.GITHUB_TOKEN }}")
      .replace("__REPO__", "owner/name"))
d = yaml.safe_load(wf)
assert "on" in d and True not in d, f"bad trigger: {list(d.keys())}"
j = d["jobs"]["build"]
assert j["permissions"]["id-token"] == "write", "keyless signing needs id-token"
assert j["permissions"]["packages"] == "write", "needs packages: write to push"
assert j["steps"][2]["with"]["IMAGE_NAME"] == "ghcr.io/owner/name/${{ IMAGE_NAME }}"
print("  workflow YAML valid; perms and image ref correct")
PYEOF
if podman run --rm -v "$PWD:/w:ro" -v /tmp/_yamlcheck.py:/yc.py:ro \
     docker.io/library/fedora:42 \
     bash -c 'dnf install -y python3-pyyaml >/dev/null 2>&1 && python3 /yc.py' 2>&1 | tail -4
then ok "strict YAML validation"; else bad "strict YAML validation"; fi
rm -f /tmp/_yamlcheck.py

step "dry-run phase1 (answers 'no' to the push, so nothing is uploaded)"
cp -a . /tmp/setup-test-clone 2>/dev/null
cd /tmp/setup-test-clone
rm -f setup-state.json
# gh owner, repo, registry, <no> to pushing the builder, <no> to committing.
printf 'testowner\ncaelestia-test\nghcr.io\nn\nn\n' | \
  timeout 180 python3 setup.py phase1 > /tmp/phase1.out 2>&1
rc=$?
echo "  --- output tail ---"
tail -12 /tmp/phase1.out | sed 's/^/    /'
# Declining the publish must still let the rest of phase1 complete, so the
# CI files and the state file get written.
if [ -f setup-state.json ]; then
  ok "setup-state.json written even when the publish is declined"
  python3 - <<'PY'
import json
d = json.load(open('setup-state.json'))
assert d.get('image') == 'ghcr.io/testowner/caelestia-test', d.get('image')
assert d.get('builder') == 'ghcr.io/testowner/caelestia-builder', d.get('builder')
assert d.get('sig_ref').startswith('ostree-image-signed:'), d.get('sig_ref')
assert d.get('unsig_ref').startswith('ostree-unverified-registry:'), d.get('unsig_ref')
print('    image   :', d['image'])
print('    builder :', d['builder'])
print('    sig_ref :', d['sig_ref'])
PY
  [ $? -eq 0 ] && ok "state contains correct derived refs" || bad "state refs"
  [ -f .github/workflows/build.yml ] && ok "workflow file written" || bad "workflow file"
  [ -f blueprint.yml ] && ok "blueprint written" || bad "blueprint"
  grep -q 'ghcr.io/testowner/caelestia-test/\${{ IMAGE_NAME }}' .github/workflows/build.yml \
    && ok "workflow points at the chosen repo" || bad "workflow image name"
  grep -q 'name: Build' .github/workflows/build.yml && ok "workflow has a name" || bad "workflow name"
else
  bad "setup-state.json not written (rc=$rc)"
fi
cd - >/dev/null

step "publish set: what git add -A would upload"
# README is personal operator notes and must not reach the public repo, but
# the Containerfile/blueprint/workflow are exactly what BlueBuild consumes -
# ignoring those would silently produce a repo that cannot build.
(
  cd /tmp/setup-test-clone || exit 1
  git init -q
  git add -A
  must_ignore="README.md setup-state.json build dist"
  must_track="Containerfile blueprint.yml .github/workflows/build.yml"
  for f in $must_ignore; do
    git check-ignore -q "$f" && echo "  IGNORED  $f" || echo "  LEAKED   $f"
  done
  for f in $must_track; do
    git check-ignore -q "$f" && echo "  IGNORED! $f" || echo "  tracked  $f"
  done
  echo "--- staged list ---"
  git status --porcelain | awk '{print $2}' | sort
)
staged=$(cd /tmp/setup-test-clone 2>/dev/null && git diff --cached --name-only 2>/dev/null)
echo "$staged" | grep -qx "README.md" && bad "README.md would be uploaded" || ok "README.md excluded"
echo "$staged" | grep -qx "setup-state.json" && bad "setup-state.json would be uploaded" || ok "setup-state.json excluded"
for f in Containerfile blueprint.yml .github/workflows/build.yml; do
  echo "$staged" | grep -qx "$f" && ok "$f included (BlueBuild needs it)" \
                                  || bad "$f missing - CI would fail"
done

step "status command"
./setup.py status >/dev/null 2>&1 && ok "status runs" || bad "status"
./setup.py status | sed 's/^/    /'

rm -rf /tmp/setup-test-clone
echo
if [ "$FAILED" -eq 0 ]; then printf '\033[1;32m==== SETUP TESTS PASSED ====\033[0m\n'
else printf '\033[1;31m==== SETUP TESTS: %d FAILED ====\033[0m\n' "$FAILED"; fi
exit $FAILED