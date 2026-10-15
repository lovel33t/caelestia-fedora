#!/bin/bash
# Report every shared library that our from-source components need but that the
# assembled runtime image does not provide.
IMG="${1:-localhost/caelestia-fedora:dev}"
podman run --rm "$IMG" bash -c '
missing=0
for so in $(find /usr/lib64/qt6/qml/Caelestia /usr/lib64/qt6/qml/Quickshell \
                -name "*.so" 2>/dev/null; \
            ls /usr/bin/quickshell /usr/bin/lazygit /usr/bin/gpu-screen-recorder 2>/dev/null); do
  for lib in $(ldd "$so" 2>/dev/null | awk "/=> not found/{print \$1}"); do
    echo "MISSING  $lib   <- $(basename $so)"
    missing=$((missing+1))
  done
done
echo "----"
echo "total missing: $missing"
echo
echo "=== is the provider package available? ==="
for p in libqalculate aubio libpipewire lm_sensors; do
  if rpm -q "$p" >/dev/null 2>&1; then echo "  present : $p"
  else
    n=$(dnf -q repoquery --available --qf "%{name}-%{evr}" "$p" 2>/dev/null | head -1)
    [ -n "$n" ] && echo "  installable: $p ($n)" || echo "  NOT FOUND: $p"
  fi
done
'