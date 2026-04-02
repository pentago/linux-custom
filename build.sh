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

echo "=== Resolving CachyOS patches from submodule ==="
KERNEL_VER=$(grep '^pkgver=' PKGBUILD | cut -d= -f2)
KERNEL_MAJOR_MINOR=$(echo "$KERNEL_VER" | cut -d. -f1,2)
echo "Kernel: $KERNEL_VER — using CachyOS patches for ${KERNEL_MAJOR_MINOR}"

CACHY_SUBMODULE="$SCRIPT_DIR/cachyos-patches"
CACHY_BASE_PATCH="$CACHY_SUBMODULE/${KERNEL_MAJOR_MINOR}/all/0001-cachyos-base-all.patch"
CACHY_BORE_PATCH="$CACHY_SUBMODULE/${KERNEL_MAJOR_MINOR}/sched/0001-bore-cachy.patch"

if [[ ! -f "$CACHY_BASE_PATCH" ]]; then
  echo "FAIL: No CachyOS base patch found at $CACHY_BASE_PATCH"
  echo "Hint: Run 'git submodule update --init' or update the submodule pin for kernel ${KERNEL_MAJOR_MINOR}"
  exit 1
fi
if [[ ! -f "$CACHY_BORE_PATCH" ]]; then
  echo "FAIL: No CachyOS BORE patch found at $CACHY_BORE_PATCH"
  echo "Hint: Run 'git submodule update --init' or update the submodule pin for kernel ${KERNEL_MAJOR_MINOR}"
  exit 1
fi

python3 - "$CACHY_BASE_PATCH" cachyos-base.patch << 'PYEOF'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
content = open(src).read()
# Files already merged into mainline 6.19.10 — applying would cause duplicate definitions
skip_files = {
    # Already merged into mainline 6.19.10 — applying causes duplicate definitions/reverts
    "b/kernel/fork.c",
    "b/drivers/pci/quirks.c",
    "b/drivers/bluetooth/btusb.c",
    "b/drivers/acpi/processor_driver.c",
    "b/drivers/gpu/drm/amd/amdgpu/amdgpu_device.c",
    "b/drivers/usb/core/quirks.c",
    "b/sound/hda/codecs/realtek/alc269.c",
}
parts = re.split(r'(?=^diff --git )', content, flags=re.MULTILINE)
kept = [p for p in parts if not any(f' {sf}' in p.split('\n')[0] for sf in skip_files)]
open(dst, 'w').write(''.join(kept))
PYEOF
echo "Generated filtered cachyos-base.patch (stripped mainline-upstreamed hunks)"
cp "$CACHY_BORE_PATCH" cachyos-bore.patch
echo "Copied: cachyos-base.patch, cachyos-bore.patch"

CACHY_BASE_B2=$(b2sum cachyos-base.patch | cut -d' ' -f1)
CACHY_BORE_B2=$(b2sum cachyos-bore.patch | cut -d' ' -f1)

echo "=== Patching PKGBUILD ==="

# Pass 1: simple substitutions and deletions
sed -i \
  -e 's/^pkgbase=linux$/pkgbase=linux-custom/' \
  -e '/make htmldocs/d' \
  -e "/\"\\\$pkgbase-docs\"/d" \
  -e '/^export KBUILD_BUILD_HOST/i export LLVM=1' \
  -e '/^makedepends=(/a\  clang\n  llvm\n  lld' \
  PKGBUILD

# Add CachyOS patches to the main source array (after the arch1 patch line)
sed -i "/linux-\\\$_srctag\.patch\.zst/ a\\  cachyos-base.patch\\n  cachyos-bore.patch" PKGBUILD

# Append CachyOS patch b2sums to the main b2sums array (before its closing paren)
sed -i "/^b2sums=(/,/'SKIP')\$/ { /'SKIP')\$/ s/'SKIP')\$/'SKIP'\n  '$CACHY_BASE_B2'\n  '$CACHY_BORE_B2')/ }" PKGBUILD

# Append SKIP entries to sha256sums for the two new patch files
# (b2sums already verifies them; sha256sums must match source= count)
sed -i "/^sha256sums=(/,/'SKIP')\$/ { /'SKIP')\$/ s/'SKIP')\$/'SKIP'\n            'SKIP'\n            'SKIP')/ }" PKGBUILD

sed -i "s#patch -Np1 < \"\.\./\\\$src\"#if [[ \"\\\$src\" == \"cachyos-base.patch\" ]]; then\n      patch -Np1 -F3 < \"../\\\$src\"\n    else\n      patch -Np1 < \"../\\\$src\"\n    fi#" PKGBUILD

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
    print "  scripts/config --enable PCIEASPM_PERFORMANCE"
    print "  scripts/config --enable PCI_REALLOC_ENABLE_AUTO"
    print ""
    print "  echo \"Force-enabling initramfs-critical modules...\""
    print "  scripts/config --module CRYPTO_LZ4"
    print "  scripts/config --module DM_INTEGRITY"
    print ""
    print "  echo \"Force-enabling Docker/container modules...\""
    print "  scripts/config --module BRIDGE"
    print "  scripts/config --module VETH"
    print "  scripts/config --enable OVERLAY_FS"
    print "  scripts/config --module NF_CONNTRACK"
    print "  scripts/config --module NF_NAT"
    print "  scripts/config --module NETFILTER_XT_MATCH_ADDRTYPE"
    print "  scripts/config --module NETFILTER_XT_MATCH_CONNTRACK"
    print "  scripts/config --module NETFILTER_XT_MARK"
    print "  scripts/config --module IP_NF_NAT"
    print "  scripts/config --module IP_NF_TARGET_MASQUERADE"
    print "  scripts/config --module IP_NF_TARGET_REJECT"
    print "  scripts/config --module IP_NF_MANGLE"
    print "  scripts/config --module VXLAN"
    print "  scripts/config --module MACVLAN"
    print "  scripts/config --module IPVLAN"
    print "  scripts/config --module XFRM_USER"
    print "  scripts/config --module IP_NF_RAW"
    print "  scripts/config --module NETFILTER_XT_MATCH_MULTIPORT"
    print "  scripts/config --module NETFILTER_XT_MATCH_COMMENT"
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
check "BRIDGE forced"               'module BRIDGE$'                  1
check "VETH forced"                 'module VETH$'                    1
check "OVERLAY_FS forced"           'OVERLAY_FS'                      1
check "NF_CONNTRACK forced"         'module NF_CONNTRACK$'            1
check "NF_NAT forced"              'module NF_NAT$'                  1
check "MASQUERADE forced"          'IP_NF_TARGET_MASQUERADE'         1
check "VXLAN forced"               'module VXLAN$'                   1
check "base patch uses fuzz"        'if \[\[ "\$src" == "cachyos-base\.patch" \]\]; then' 1
check "base patch fuzz command"     'patch -Np1 -F3 < "\.\./\$src"'      1
check "CachyOS base patch in source" '^  cachyos-base\.patch$'        1
check "CachyOS BORE patch in source" '^  cachyos-bore\.patch$'        1
check "CachyOS b2sums added"        "^  '[0-9a-f]"                    2
check "sha256sums SKIP count"       "^            'SKIP'"             4
check "CACHY enabled"               'enable CACHY$'                   1
check "SCHED_BORE enabled"          'SCHED_BORE'                      1
check "PCIEASPM performance"        'PCIEASPM_PERFORMANCE'             1
check "ReBAR enabled"               'PCI_REALLOC_ENABLE_AUTO'          1
echo "All modifications verified."

echo "=== Starting kernel build ==="
makepkg -s
