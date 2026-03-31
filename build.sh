#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODPROBED_DB="$HOME/.config/modprobed.db"
: "${MODPROBED_DB:?}"

echo "=== Refreshing module database ==="
if [[ ! -f "$MODPROBED_DB" ]]; then
  echo "FAIL: Missing modprobed database at $MODPROBED_DB"
  exit 1
fi
modprobed-db store

echo "=== Fetching Arch linux PKGBUILD ==="
rm -rf "$SCRIPT_DIR/linux"
cd "$SCRIPT_DIR"
paru -G linux
cd linux

echo "=== Patching PKGBUILD ==="
sed -i 's/^pkgbase=linux$/pkgbase=linux-custom/' PKGBUILD
sed -i '/^  # htmldocs$/,/^  texlive-latexextra$/d' PKGBUILD
sed -i '/make htmldocs/d' PKGBUILD
awk '/^_package-docs\(\) \{$/{skip=1} skip{if(/^\}$/){skip=0; next} next} 1' PKGBUILD > PKGBUILD.tmp && mv PKGBUILD.tmp PKGBUILD
sed -i '/"\$pkgbase-docs"/d' PKGBUILD

cat > /tmp/custom_block.txt << BLOCK

  echo "Trimming to used modules with localmodconfig..."
  make LSMOD=$MODPROBED_DB localmodconfig

  echo "Applying custom kernel config..."
  scripts/config --enable X86_NATIVE_CPU
  scripts/config --disable CPU_MITIGATIONS
  scripts/config --disable TRANSPARENT_HUGEPAGE_ALWAYS
  scripts/config --enable TRANSPARENT_HUGEPAGE_MADVISE
  scripts/config --enable TCP_CONG_BBR
  scripts/config --set-str DEFAULT_TCP_CONG bbr
  scripts/config --enable NET_SCH_FQ
  scripts/config --set-val NR_CPUS 64
  scripts/config --disable DEBUG_INFO_DWARF5
  scripts/config --enable DEBUG_INFO_NONE

  echo "Resolving config dependencies..."
  make olddefconfig
BLOCK

awk '/^  make olddefconfig$/ && !injected {print; while ((getline line < "/tmp/custom_block.txt") > 0) print line; close("/tmp/custom_block.txt"); injected=1; next} 1' PKGBUILD > PKGBUILD.tmp && mv PKGBUILD.tmp PKGBUILD
rm -f /tmp/custom_block.txt

echo "=== Verifying modifications ==="
check() { local desc="$1" cmd="$2" expected="$3"
  local got; got=$(eval "$cmd")
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL: $desc (expected $expected, got $got)"; exit 1
  fi
}
check "pkgbase rename"           "grep -c '^pkgbase=linux-custom$' PKGBUILD" "1"
check "htmldocs removed"         "grep -c 'make htmldocs' PKGBUILD" "0"
check "_package-docs removed"    "grep -c '_package-docs()' PKGBUILD" "0"
check "docs pkgname removed"     "grep -c '\"[$]pkgbase-docs\"' PKGBUILD" "0"
check "graphviz removed"         "grep -c 'graphviz' PKGBUILD" "0"
check "localmodconfig injected"  "grep -c 'localmodconfig' PKGBUILD" "2"
check "X86_NATIVE_CPU set"       "grep -c 'X86_NATIVE_CPU' PKGBUILD" "1"
check "CPU_MITIGATIONS set"      "grep -c 'CPU_MITIGATIONS' PKGBUILD" "1"
check "BBR configured"           "grep -c 'DEFAULT_TCP_CONG' PKGBUILD" "1"
check "NR_CPUS set"              "grep -c 'NR_CPUS' PKGBUILD" "1"
check "DEBUG_INFO_NONE set"      "grep -c 'DEBUG_INFO_NONE' PKGBUILD" "1"
check "THP madvise set"          "grep -c 'TRANSPARENT_HUGEPAGE_MADVISE' PKGBUILD" "1"
echo "All modifications verified."

echo "=== Starting kernel build ==="
makepkg -s
