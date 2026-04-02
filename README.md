# linux-custom

Custom Arch Linux kernel build script for AMD Ryzen 9 9955HX (Zen 5). Fetches the stock Arch `linux` PKGBUILD, patches it inline, trims modules to only those in use, applies performance optimizations, and builds with `makepkg`.

## What it does

- Refreshes module database via `modprobed-db store`
- Fetches fresh Arch `linux` PKGBUILD via `paru -G linux`
- Patches the PKGBUILD inline with sed/awk (content-matching, no line numbers)
- Runs 31 grep assertions to verify all patches applied correctly
- Builds the `linux-custom` package with `makepkg -s`

## PKGBUILD modifications

| Modification | Details |
| :--- | :--- |
| Package rename | `pkgbase=linux` -> `pkgbase=linux-custom` |
| Remove htmldocs | Strips makedepends, `make htmldocs` call, `_package-docs()` function, and docs pkgname entry |
| Module trimming | `yes "" \| make localmodconfig` with `modprobed-db`. Builds only modules currently in use on this machine. Auto-accepts defaults for new config options |
| Native CPU | `CONFIG_X86_NATIVE_CPU`. `-march=native` at kernel level (mainline 6.16+) |
| Disable mitigations | `CONFIG_CPU_MITIGATIONS` off. Single toggle cascading to all 25 `MITIGATION_*` options |
| THP madvise | Switches Transparent HugePages from `always` to `madvise`. Better for gaming/desktop |
| TCP BBR | `CONFIG_TCP_CONG_BBR` built-in, `DEFAULT_TCP_CONG="bbr"`, `NET_SCH_FQ` enabled |
| Reduce NR_CPUS | 8192 -> 64 (Ryzen 9 9955HX has 16 cores / 32 threads) |
| Clang -O3 | `CC_OPTIMIZE_FOR_PERFORMANCE_O3` on (replaces default `-O2`). ~1-3% improvement in kernel-heavy workloads |
| LLVM/Clang toolchain | `export LLVM=1`, adds `clang`/`llvm`/`lld` makedepends. Required for ThinLTO |
| ThinLTO | `CONFIG_LTO_CLANG_THIN` on. Cross-translation-unit link-time optimization via Clang. ~3-5% improvement |
| BPF type info | `DEBUG_INFO_BTF` enabled. Keeps stock DWARF5 — required for bpftool `vmlinux.h` generation |
| Force initramfs modules | `CRYPTO_LZ4` and `DM_INTEGRITY` as modules. Missed by `localmodconfig` but required by mkinitcpio `systemd`/`sd-encrypt` hooks |
| Force Docker modules | `BRIDGE`, `VETH`, `OVERLAY_FS`, `NF_CONNTRACK`, `NF_NAT`, `VXLAN`, `MACVLAN`, `IPVLAN`, `XFRM_USER`, and iptables modules. Missed by `localmodconfig` but required for container networking |
| CachyOS base patch | `0001-cachyos-base-all.patch` from the pinned `cachyos-patches/` submodule. AMD ISP4 driver, misc fixes |
| BORE scheduler | `0001-bore-cachy.patch` from the pinned `cachyos-patches/` submodule. BORE (Burst-Oriented Response Enhancer) replaces stock EEVDF. `CONFIG_SCHED_BORE` enabled |

## Prerequisites (one-time setup)

Install `modprobed-db` and capture your currently loaded modules:

```bash
paru -S modprobed-db
modprobed-db store
```

Clone the repo with the CachyOS patches submodule:

```bash
git clone --recurse-submodules https://github.com/<user>/linux-custom.git
cd linux-custom
```

If you already have the repo without the submodule initialized:

```bash
git submodule update --init
```

## Building

```bash
./build.sh
```

The script does everything: refreshes your module database, fetches a fresh Arch `linux` PKGBUILD via `paru -G linux`, copies the CachyOS patches from the pinned submodule, patches the PKGBUILD inline, verifies all 31 assertions, and builds with `makepkg -s`. Build time is roughly 30–60 minutes.

Kernel source tarballs are cached in `./sources` (via `SRCDEST`) to avoid re-downloading on subsequent runs. Your `makepkg.conf` settings (CFLAGS, MAKEFLAGS, ccache, etc.) are applied automatically by makepkg.

## Installing

After a successful build, install the packages from `linux/`:

```bash
cd linux
sudo pacman -U linux-custom-*.pkg.tar.zst linux-custom-headers-*.pkg.tar.zst
```

Reboot and select `linux-custom` from your bootloader. Systemd-boot and GRUB generate the new entry automatically via install hooks.

## Rebuilding

Re-run `./build.sh`. Each run fetches a fresh PKGBUILD, so upstream Arch kernel updates are picked up automatically. The kernel tarball is cached, so re-runs skip the ~130 MB download.

## When Arch bumps to a new kernel version

The build will fail immediately with a clear error if the submodule does not have patches for the new kernel version (e.g. `6.20`):

```
FAIL: No CachyOS base patch found at .../cachyos-patches/6.20/all/0001-cachyos-base-all.patch
Hint: Run 'git submodule update --init' or update the submodule pin for kernel 6.20
```

Update the submodule pin to a commit in the CachyOS repo that contains a `6.20/` directory:

```bash
cd cachyos-patches
git fetch
git log --oneline origin/master | head -10
git checkout <new-commit-hash>
cd ..
git add cachyos-patches
git commit -m "chore: update cachyos-patches submodule for kernel 6.20"
```

## Keep modprobed-db fresh

The kernel is trimmed to only the modules your system currently uses (`localmodconfig`). If you add new hardware or load new modules between builds, run `modprobed-db store` first — otherwise `localmodconfig` will exclude them from the next build.

## Design decisions

- All PKGBUILD patches use content-matching sed/awk, not line numbers. This makes them resilient to upstream changes across kernel releases.
- `linux/` is `.gitignore`d and replaced fresh on every run.
- 31 post-patch grep assertions fail the script immediately if any modification didn't apply.
- ThinLTO via Clang/LLVM (`CONFIG_LTO_CLANG_THIN`). Cross-TU link-time optimization for ~3-5% improvement.
- CachyOS patches (BORE scheduler + base fixes) applied from a pinned git submodule (`cachyos-patches/`). Pinned to a specific commit for reproducibility; update manually when the kernel version bumps.
- `$HOME` used for all paths (tilde doesn't expand in double-quoted bash assignments).
- Source tarballs cached via `SRCDEST` set in the script itself (not in makepkg.conf). Stored in `./sources`, gitignored.

## Repository structure

```
.
├── build.sh          # Custom kernel build script
├── README.md         # This file
├── cachyos-patches/   # CachyOS kernel patches submodule (pinned commit)
├── sources/           # Cached kernel source tarballs via SRCDEST (gitignored)
├── linux/             # Fetched by build.sh via paru (gitignored, replaced each run)
│   ├── PKGBUILD
│   ├── config.x86_64
│   └── ...
└── AGENTS.md          # Agent instructions for AI-assisted development
```

## License

This build script is provided as-is. Kernel source and PKGBUILD files are subject to their respective upstream licenses (GPL-2.0).
