#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODPROBED_DB="$HOME/.config/modprobed.db"
: "${MODPROBED_DB:?}"
export SRCDEST="$SCRIPT_DIR/sources"
mkdir -p "$SRCDEST"

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

echo "=== Fetching CachyOS patches ==="
KERNEL_VER=$(grep '^pkgver=' PKGBUILD | cut -d= -f2)
KERNEL_MAJOR_MINOR=$(echo "$KERNEL_VER" | cut -d. -f1,2)
echo "Kernel: $KERNEL_VER — fetching CachyOS patches for ${KERNEL_MAJOR_MINOR}"

rm -rf "$SCRIPT_DIR/cachy-tmp"
git clone --depth=1 --filter=blob:none --sparse \
  https://github.com/CachyOS/kernel-patches.git "$SCRIPT_DIR/cachy-tmp"
git -C "$SCRIPT_DIR/cachy-tmp" sparse-checkout set \
  "${KERNEL_MAJOR_MINOR}/all" \
  "${KERNEL_MAJOR_MINOR}/sched"

CACHY_BASE_PATCH=$(find "$SCRIPT_DIR/cachy-tmp/${KERNEL_MAJOR_MINOR}/all" \
  -name '0001-cachyos-base-all.patch' | head -1)
CACHY_BORE_PATCH=$(find "$SCRIPT_DIR/cachy-tmp/${KERNEL_MAJOR_MINOR}/sched" \
  -name '0001-bore-cachy.patch' | head -1)

if [[ -z "$CACHY_BASE_PATCH" ]]; then
  echo "FAIL: No CachyOS base patch found for kernel ${KERNEL_MAJOR_MINOR}"
  rm -rf "$SCRIPT_DIR/cachy-tmp"
  exit 1
fi
if [[ -z "$CACHY_BORE_PATCH" ]]; then
  echo "FAIL: No CachyOS BORE patch found for kernel ${KERNEL_MAJOR_MINOR}"
  rm -rf "$SCRIPT_DIR/cachy-tmp"
  exit 1
fi

cp "$CACHY_BASE_PATCH" cachyos-base.patch
cp "$CACHY_BORE_PATCH" cachyos-bore.patch
rm -rf "$SCRIPT_DIR/cachy-tmp"
echo "Fetched: cachyos-base.patch, cachyos-bore.patch"

CACHY_BASE_B2=$(b2sum cachyos-base.patch | cut -d' ' -f1)
CACHY_BORE_B2=$(b2sum cachyos-bore.patch | cut -d' ' -f1)

echo "=== Patching PKGBUILD ==="

# Pass 1: simple substitutions and deletions
sed -i \
  -e 's/^pkgbase=linux$/pkgbase=linux-custom/' \
  -e '/make htmldocs/d' \
  -e '/"\$pkgbase-docs"/d' \
  -e '/^export KBUILD_BUILD_HOST/i export LLVM=1' \
  -e '/^makedepends=(/a\  clang\n  llvm\n  lld' \
  -e 's/^source_x86_64=(config\.x86_64)$/source_x86_64=(config.x86_64\n  cachyos-base.patch\n  cachyos-bore.patch)/' \
  PKGBUILD

# Add both CachyOS patch b2sums to b2sums_x86_64
sed -i "/^b2sums_x86_64=('/ s/)$/ '$CACHY_BASE_B2' '$CACHY_BORE_B2')/" PKGBUILD

# Pass 2: block removal + config injection (single awk pass)
awk '
  # Remove htmldocs makedepends block
  /^  # htmldocs$/ { skip_html=1; next }
  skip_html && /^  texlive-latexextra$/ { skip_html=0; next }
  skip_html { next }

  # Remove _package-docs() function
  /^_package-docs\(\) \{$/ { skip_docs=1; next }
  skip_docs && /^\}$/ { skip_docs=0; next }
  skip_docs { next }

  # Inject custom block after first make olddefconfig
  /^  make olddefconfig$/ && !injected {
    print
    print ""
    print "  echo \"Trimming to used modules with localmodconfig...\""
    print "  yes \"\" | make LSMOD='"$MODPROBED_DB"' localmodconfig"
    print ""
    print "  echo \"Applying custom kernel config...\""
    print "  scripts/config --disable CC_OPTIMIZE_FOR_PERFORMANCE"
    print "  scripts/config --enable CC_OPTIMIZE_FOR_PERFORMANCE_O3"
    print "  scripts/config --enable X86_NATIVE_CPU"
    print "  scripts/config --disable CPU_MITIGATIONS"
    print "  scripts/config --disable TRANSPARENT_HUGEPAGE_ALWAYS"
    print "  scripts/config --enable TRANSPARENT_HUGEPAGE_MADVISE"
    print "  scripts/config --enable TCP_CONG_BBR"
    print "  scripts/config --set-str DEFAULT_TCP_CONG bbr"
    print "  scripts/config --enable NET_SCH_FQ"
    print "  scripts/config --set-val NR_CPUS 64"
    print "  scripts/config --enable DEBUG_INFO_BTF"
    print "  scripts/config --enable LTO_CLANG_THIN"
    print "  scripts/config --enable CACHY"
    print "  scripts/config --enable SCHED_BORE"
    print ""
    print "  echo \"Force-enabling initramfs-critical modules...\""
    print "  scripts/config --module CRYPTO_LZ4"
    print "  scripts/config --module DM_INTEGRITY"
    print ""
    print "  echo \"Resolving config dependencies...\""
    print "  make olddefconfig"
    injected=1
    next
  }

  { print }
' PKGBUILD > PKGBUILD.tmp && mv PKGBUILD.tmp PKGBUILD

echo "=== Verifying modifications ==="
check() { local desc="$1" pattern="$2" expected="$3"
  local got; got=$(grep -c "$pattern" PKGBUILD || true)
  if [[ "$got" != "$expected" ]]; then
    echo "FAIL: $desc (expected $expected, got $got)"; exit 1
  fi
}
check "pkgbase rename"              '^pkgbase=linux-custom$'          1
check "htmldocs removed"            'make htmldocs'                   0
check "_package-docs removed"       '_package-docs()'                 0
check "docs pkgname removed"        '"[$]pkgbase-docs"'               0
check "graphviz removed"            'graphviz'                        0
check "localmodconfig injected"     'localmodconfig'                  2
check "X86_NATIVE_CPU set"          'X86_NATIVE_CPU'                  1
check "CPU_MITIGATIONS set"         'CPU_MITIGATIONS'                 1
check "BBR configured"              'DEFAULT_TCP_CONG'                1
check "NR_CPUS set"                 'NR_CPUS'                         1
check "DEBUG_INFO_BTF set"          'enable DEBUG_INFO_BTF$'          1
check "THP madvise set"             'TRANSPARENT_HUGEPAGE_MADVISE'    1
check "O3 optimization set"         'CC_OPTIMIZE_FOR_PERFORMANCE_O3'  1
check "LLVM enabled"                '^export LLVM=1$'                 1
check "ThinLTO set"                 'LTO_CLANG_THIN'                  1
check "CRYPTO_LZ4 forced"           'CRYPTO_LZ4'                      1
check "DM_INTEGRITY forced"         'DM_INTEGRITY'                    1
check "CachyOS base patch in source" 'cachyos-base\.patch'            1
check "CachyOS BORE patch in source" 'cachyos-bore\.patch'            1
check "CachyOS b2sums added"        "b2sums_x86_64=.*' '.*' '"        1
check "CACHY enabled"               'enable CACHY$'                   1
check "SCHED_BORE enabled"          'SCHED_BORE'                      1
echo "All modifications verified."

echo "=== Starting kernel build ==="
makepkg -s
