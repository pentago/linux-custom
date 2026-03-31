# linux-custom

Custom Arch Linux kernel build script for AMD Ryzen 9 9955HX (Zen 5). Fetches the stock Arch `linux` PKGBUILD, patches it inline, trims modules to only those in use, applies performance optimizations, and builds with `makepkg`.

## What it does

- Refreshes module database via `modprobed-db store`
- Fetches fresh Arch `linux` PKGBUILD via `paru -G linux`
- Patches the PKGBUILD inline with sed/awk (content-matching, no line numbers)
- Runs 13 grep assertions to verify all patches applied correctly
- Builds the `linux-custom` package with `makepkg -s`

## PKGBUILD modifications

| Modification | Details |
| :--- | :--- |
| Package rename | `pkgbase=linux` -> `pkgbase=linux-custom` |
| Remove htmldocs | Strips makedepends, `make htmldocs` call, `_package-docs()` function, and docs pkgname entry |
| Module trimming | `make localmodconfig` with `modprobed-db`. Builds only modules currently in use on this machine |
| Native CPU | `CONFIG_X86_NATIVE_CPU`. `-march=native` at kernel level (mainline 6.16+) |
| Disable mitigations | `CONFIG_CPU_MITIGATIONS` off. Single toggle cascading to all 25 `MITIGATION_*` options |
| THP madvise | Switches Transparent HugePages from `always` to `madvise`. Better for gaming/desktop |
| TCP BBR | `CONFIG_TCP_CONG_BBR` built-in, `DEFAULT_TCP_CONG="bbr"`, `NET_SCH_FQ` enabled |
| Reduce NR_CPUS | 8192 -> 64 (Ryzen 9 9955HX has 16 cores / 32 threads) |
| GCC -O3 | `CC_OPTIMIZE_FOR_PERFORMANCE_O3` on (replaces default `-O2`). ~1-3% improvement in kernel-heavy workloads |
| No debug info | `DEBUG_INFO_DWARF5` off, `DEBUG_INFO_NONE` on. Smaller kernel image |

## Prerequisites

- Arch Linux
- `paru` (AUR helper)
- `modprobed-db` with database at `$HOME/.config/modprobed.db`
- `makepkg` and kernel build dependencies (`base-devel`, `bc`, `cpio`, `gettext`, `libelf`, `pahole`, `perl`, `python`, `tar`, `xz`, `rust-bindgen`)
- Interactive sudo (for `makepkg -s` dependency installation)

## Usage

```bash
git clone https://github.com/<user>/linux-custom.git
cd linux-custom
./build.sh
```

The script fetches a fresh PKGBUILD into `./linux` (replacing any existing contents) and builds there. Your `makepkg.conf` settings (CFLAGS, MAKEFLAGS, ccache, etc.) are applied automatically by makepkg.

## Installing

After a successful build, install the packages from `linux/`:

```bash
cd linux
sudo pacman -U linux-custom-*.pkg.tar.zst linux-custom-headers-*.pkg.tar.zst
```

## Design decisions

- All PKGBUILD patches use content-matching sed/awk, not line numbers. This makes them resilient to upstream changes across kernel releases.
- `linux/` is `.gitignore`d and replaced fresh on every run.
- 13 post-patch grep assertions fail the script immediately if any modification didn't apply.
- No LTO (requires Clang; this setup uses GCC).
- No out-of-tree scheduler patches (BORE, BMQ, etc.). Stock EEVDF scheduler only.
- `$HOME` used for all paths (tilde doesn't expand in double-quoted bash assignments).

## Repository structure

```
.
├── build.sh          # Custom kernel build script
├── custom.patch       # Reserved for future patches (currently empty)
├── linux/             # Fetched by build.sh via paru (gitignored, replaced each run)
│   ├── PKGBUILD
│   ├── config.x86_64
│   └── ...
└── AGENTS.md          # Agent instructions for AI-assisted development
```

## License

This build script is provided as-is. Kernel source and PKGBUILD files are subject to their respective upstream licenses (GPL-2.0).
