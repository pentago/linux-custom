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

echo "=== Fetching BORE scheduler patch ==="
KERNEL_VER=$(grep '^pkgver=' PKGBUILD | cut -d= -f2)
KERNEL_MAJOR_MINOR=$(echo "$KERNEL_VER" | cut -d. -f1,2)
BORE_PATCH_DIR="patches/stable/linux-${KERNEL_MAJOR_MINOR}-bore"
echo "Kernel: $KERNEL_VER — fetching BORE for linux-${KERNEL_MAJOR_MINOR}"

rm -rf "$SCRIPT_DIR/bore-tmp"
git clone --depth=1 --filter=blob:none --sparse \
  https://github.com/firelzrd/bore-scheduler.git "$SCRIPT_DIR/bore-tmp"
git -C "$SCRIPT_DIR/bore-tmp" sparse-checkout set "$BORE_PATCH_DIR"

BORE_PATCH_FILE=$(find "$SCRIPT_DIR/bore-tmp/$BORE_PATCH_DIR" -name '0001-*.patch' | head -1)
if [[ -z "$BORE_PATCH_FILE" ]]; then
  echo "FAIL: No BORE patch found for kernel ${KERNEL_MAJOR_MINOR} in ${BORE_PATCH_DIR}"
  rm -rf "$SCRIPT_DIR/bore-tmp"
  exit 1
fi
echo "Using: $(basename "$BORE_PATCH_FILE")"
cp "$BORE_PATCH_FILE" bore.patch
rm -rf "$SCRIPT_DIR/bore-tmp"

BORE_B2=$(b2sum bore.patch | cut -d' ' -f1)

echo "=== Patching PKGBUILD ==="

# Pass 1: simple substitutions and deletions
sed -i \
  -e 's/^pkgbase=linux$/pkgbase=linux-custom/' \
  -e '/make htmldocs/d' \
  -e '/"\$pkgbase-docs"/d' \
  -e '/^export KBUILD_BUILD_HOST/i export LLVM=1' \
  -e '/^makedepends=(/a\  clang\n  llvm\n  lld' \
  -e 's/^source_x86_64=(config\.x86_64)$/source_x86_64=(config.x86_64\n  bore.patch)/' \
  PKGBUILD

# Add BORE b2sum to b2sums_x86_64 (append before closing paren)
sed -i "/^b2sums_x86_64=('/ s/)$/ '$BORE_B2')/" PKGBUILD

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
check "pkgbase rename"           '^pkgbase=linux-custom$'          1
check "htmldocs removed"         'make htmldocs'                   0
check "_package-docs removed"    '_package-docs()'                 0
check "docs pkgname removed"     '"[$]pkgbase-docs"'               0
check "graphviz removed"         'graphviz'                        0
check "localmodconfig injected"  'localmodconfig'                  2
check "X86_NATIVE_CPU set"       'X86_NATIVE_CPU'                  1
check "CPU_MITIGATIONS set"      'CPU_MITIGATIONS'                 1
check "BBR configured"           'DEFAULT_TCP_CONG'                1
check "NR_CPUS set"              'NR_CPUS'                         1
check "DEBUG_INFO_BTF set"       'enable DEBUG_INFO_BTF$'          1
check "THP madvise set"          'TRANSPARENT_HUGEPAGE_MADVISE'    1
check "O3 optimization set"      'CC_OPTIMIZE_FOR_PERFORMANCE_O3'  1
check "LLVM enabled"             '^export LLVM=1$'                 1
check "ThinLTO set"              'LTO_CLANG_THIN'                  1
check "CRYPTO_LZ4 forced"        'CRYPTO_LZ4'                      1
check "DM_INTEGRITY forced"      'DM_INTEGRITY'                    1
check "BORE patch in source"     'bore\.patch'                     2
check "SCHED_BORE enabled"       'SCHED_BORE'                      1
echo "All modifications verified."

echo "=== Starting kernel build ==="
makepkg -s
