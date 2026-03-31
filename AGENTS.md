# AGENTS.md

## Repository scope

- Workspace root: `/home/dzhi/linux-custom`
- This is not a conventional app repo.
- Relevant root-level items include:
  - `custom.patch` — currently empty
  - `linux/` — a nested Arch Linux kernel packaging repository
- Most meaningful changes will happen in `linux/`, especially:
  - `linux/PKGBUILD`
  - `linux/.SRCINFO`
  - `linux/config.x86_64`
  - `linux/.nvchecker.toml`
  - `linux/REUSE.toml`
- The outer `.gitignore` ignores `linux/`, so always confirm whether you are editing the outer repo or the nested `linux/` repo.

## Existing editor/agent rules

- No `.cursorrules` file is present in this workspace.
- No `.cursor/rules/` directory is present in this workspace.
- No `.github/copilot-instructions.md` file is present in this workspace.
- This file is the primary repository instruction file for coding agents.

## What this repo does

This repo has two layers:

### Outer repo (workspace root)
- Contains `build.sh` — an automated script that fetches the stock Arch `linux` PKGBUILD, patches it inline to create a customized `linux-custom` kernel, and builds it with `makepkg -s`.
- Contains `custom.patch` — currently empty and unused.
- The outer `.gitignore` ignores `linux/`.

### Inner repo (`linux/`)
- A nested Arch Linux kernel packaging repository (separate git history).
- `linux/PKGBUILD` packages the stock Arch `linux` kernel.
- Sources come from `kernel.org`; Arch's release patch is fetched from GitHub.
- `prepare()` sets local version markers, applies patch files, copies `config.$CARCH`, and runs `make olddefconfig`.
- `build()` runs:
  - `make all`
  - `make -C tools/bpf/bpftool vmlinux.h feature-clang-bpf-co-re=1`
  - `make htmldocs SPHINXOPTS=-QT`
- Packaging logic lives in `_package()`, `_package-headers()`, and `_package-docs()`.

## build.sh — custom kernel build script

### What it does
1. Runs `modprobed-db store` to refresh the module database
2. Fetches a fresh Arch `linux` PKGBUILD via `paru -G linux` into `./linux` (replacing any existing contents)
3. Patches the PKGBUILD inline with sed/awk (content-matching patterns only, no line numbers)
4. Runs 13 post-patch grep assertions to verify all modifications applied
5. Runs `makepkg -s` to build the customized kernel

### PKGBUILD modifications applied (in order)
1. Rename `pkgbase=linux` → `pkgbase=linux-custom`
2. Remove htmldocs makedepends block (`# htmldocs` comment through `texlive-latexextra`)
3. Remove `make htmldocs` from `build()`
4. Remove `_package-docs()` function entirely
5. Remove `"$pkgbase-docs"` from `pkgname` array
6. Inject into `prepare()` after the first `make olddefconfig`:
   - `make LSMOD=$HOME/.config/modprobed.db localmodconfig` (trim to used modules)
   - `scripts/config` calls for 12 kernel config options (see below)
   - A second `make olddefconfig` to resolve dependencies

### Kernel config optimizations
| Option | Action | Rationale |
|---|---|---|
| `CC_OPTIMIZE_FOR_PERFORMANCE` | disable | Replaced by `-O3` below |
| `CC_OPTIMIZE_FOR_PERFORMANCE_O3` | enable | GCC `-O3` optimization (default is `-O2`). ~1-3% improvement in kernel-heavy workloads |
| `X86_NATIVE_CPU` | enable | `-march=native` at kernel level (mainline 6.16+) |
| `CPU_MITIGATIONS` | disable | Single toggle cascades to all 25 `MITIGATION_*` options |
| `TRANSPARENT_HUGEPAGE_ALWAYS` | disable | Switch THP to madvise-only |
| `TRANSPARENT_HUGEPAGE_MADVISE` | enable | Better for gaming/desktop workloads |
| `TCP_CONG_BBR` | enable | Built-in (was module) |
| `DEFAULT_TCP_CONG` | set `"bbr"` | BBR as default congestion control |
| `NET_SCH_FQ` | enable | Fair queueing scheduler (BBR companion) |
| `NR_CPUS` | set `64` | Down from 8192 (Ryzen 9 9955HX = 16 cores) |
| `DEBUG_INFO_DWARF5` | disable | No debug info for smaller kernel image |
| `DEBUG_INFO_NONE` | enable | Explicit no-debug-info selection |

### Key design decisions
- **sed/awk not unified diff**: Patches via content-matching sed/awk patterns, not a `.patch` file. This is resilient to upstream PKGBUILD line number changes across kernel releases.
- **Build in `./linux`**: Script fetches into `./linux` relative to `build.sh` location. The `linux/` directory is `.gitignore`d and replaced fresh on every run.
- **`$HOME` for paths**: Variables use `$HOME` (not `~` — tilde doesn't expand inside double-quoted assignments).
- **makepkg.conf BUILDDIR respected**: The user's `makepkg.conf` `BUILDDIR` (tmpfs) is used by `makepkg` for actual compilation.
- **No graysky2 patch needed**: `CONFIG_X86_NATIVE_CPU` is in mainline since 6.16.
- **BBRv1/v2 not v3**: BBRv3 is not in mainline as of 6.19.
- **localmodconfig ordering**: Must be after `make olddefconfig` (needs a valid `.config`), and `scripts/config` must be after `localmodconfig` (to override any module decisions).
- **No LTO**: Requires Clang; user has GCC setup.

### Modifying build.sh
- All sed/awk patterns match CONTENT, not line numbers — verify patterns still match if the upstream Arch PKGBUILD changes.
- The awk injection for `_package-docs()` removal matches the exact function signature `^_package-docs() {$` with closing `^}$` — if Arch changes the function formatting, the awk may need updating.
- The heredoc uses unquoted `<< BLOCK` — `$HOME` and `$MODPROBED_DB` expand at script runtime. This is intentional.
- After modifying, always run: `bash -n build.sh` and re-verify grep assertion expected counts.
- The 13 grep assertions in the script itself catch broken patches at runtime — keep them in sync with any sed/awk changes.

### Environment requirements
- `paru` (AUR helper) installed
- `modprobed-db` installed with database at `$HOME/.config/modprobed.db`
- `makepkg` and kernel build dependencies (bc, rust-bindgen, etc.)
- Interactive sudo available (for `makepkg -s` dependency installation)
- User's `makepkg.conf` already has `-march=native`, `-j$(nproc)`, ccache, mold — these apply automatically

## Command reference

Run these from `linux/` unless stated otherwise.

### Build/package

- Full package build with dependency install:
  - `makepkg -s`
- Full package build without dependency resolution:
  - `makepkg`
- Prepare only (download, extract, patch, config):
  - `makepkg -o`
- Reuse prepared sources and continue:
  - `makepkg -e`
- Force rebuild:
  - `makepkg -f`

### Metadata maintenance

- Regenerate `.SRCINFO` after changing `PKGBUILD` in any way that affects generated package metadata or sources:
  - `makepkg --printsrcinfo > .SRCINFO`
- Refresh checksums when any referenced source entry or local source file changes:
  - `updpkgsums`

### Lint/test reality

- There is **no repo-defined linter**.
- There is **no repo-defined unit test framework**.
- There is **no built-in single-test command**.
- The nearest valid verification steps are:
  - `makepkg -o` for patch/config preparation checks
  - `makepkg` for full build verification
  - `makepkg -e` only when reusing an already extracted/prepared source tree

### “Run a single test” guidance

- If asked to run a single test, explain that this repository does not define test cases or a test runner.
- Use the narrowest real validation available:
  - `makepkg -o` when validating patch application or config refresh
  - full `makepkg` when validating the actual package build
- If finer validation is needed for a kernel-specific change, use upstream kernel `make` targets inside the prepared source tree and document exactly what you ran. Those commands are not standardized by this repo.

## Files and ownership

- `build.sh`
  - custom kernel build script at repo root; fetches, patches, and builds the kernel
  - uses sed/awk content patterns — no line-number-based modifications
  - contains 13 grep assertions that self-verify all patches applied correctly
- `linux/PKGBUILD`
  - source of truth for package metadata, sources, and build/package phases
  - build.sh fetches a fresh copy via `paru -G linux` into `./linux`, replacing any existing contents
- `linux/.SRCINFO`
  - generated from `PKGBUILD`; keep in sync
- `linux/config.x86_64`
  - kernel configuration input; preserve format and treat its generated style as authoritative
- `custom.patch`
  - root-level patch file; currently empty, and not referenced by `linux/PKGBUILD` as checked today
- `linux/.nvchecker.toml`
  - version-tracking config for Arch kernel tags from GitHub
- `linux/REUSE.toml`
  - REUSE license annotation config for package files and configs

## Style guide

These conventions come from the actual files in this workspace, especially `linux/PKGBUILD`.

### Shell / PKGBUILD style

- Use 2-space indentation.
- Keep function braces on the same line:
  - `prepare() {`
- Prefer lowercase names for variables and functions.
- Helper/private names may use a leading underscore:
  - `_srcname`
  - `_package()`
- Reserve uppercase for environment variables and established build variables:
  - `KBUILD_BUILD_HOST`
  - `KBUILD_BUILD_USER`
  - `SOURCE_DATE_EPOCH`
  - `CARCH`

### Arrays and quoting

- Follow standard PKGBUILD multiline arrays:
  - `makedepends=( ... )`
  - `pkgname=( ... )`
- Keep one item per line for longer arrays.
- Preserve existing quoting style.
- Quote paths and parameter expansions unless the current shell pattern intentionally depends on word splitting.

### Shell idioms already used here

- Prefer `local` for function-scoped variables.
- Use `$(<file)` for concise file reads when matching existing style.
- Use `[[ ... ]]` for tests.
- Use `case` for architecture branching.
- Iterate arrays in the normal Bash style:
  - `for src in "${source[@]}"; do`
- Keep status output explicit with short `echo` messages before important phases.

### Error handling

- Let command exit status fail fast by default.
- Add explicit guards only when a clearer message is needed.
- Follow existing patterns such as:
  - `echo "Unknown CARCH $CARCH"; exit 1`
  - `diff -u ../config.$CARCH .config || :`
- Do not swallow real failures silently.

### Naming conventions

- Keep Arch PKGBUILD variable names exact:
  - `pkgbase`, `pkgver`, `pkgrel`, `pkgname`, `makedepends`, `optdepends`
- Keep helper names descriptive and aligned with package phases.
- Leave kernel config naming untouched:
  - `CONFIG_FOO=y`
  - `# CONFIG_BAR is not set`

### Config and generated files

- `config.x86_64` declares itself automatically generated; avoid cosmetic rewrites and keep manual deltas minimal.
- `.SRCINFO` should be regenerated instead of manually reformatted.
- `.nvchecker.toml` and `REUSE.toml` use simple TOML; keep changes minimal and consistent with existing layout.

## Change rules

- If you edit `PKGBUILD` in a way that affects generated metadata, sources, dependencies, or package relationships, regenerate `.SRCINFO`.
- If you change source declarations or any referenced local source file such as `config.x86_64`, update checksums as needed.
- If you change architecture behavior, re-check the `case $CARCH in` logic.
- If you change packaging paths, inspect all package functions, not only `_package()`.
- If you change kernel config, make the smallest necessary delta.

## What not to assume

- Do not invent Node, Python, Cargo, or Rust project commands for this repo.
- Do not claim lint/test commands exist when they do not.
- Do not apply generic app-repo guidelines here.
- Do not hand-edit generated files when regeneration is the right workflow.
- Do not assume `custom.patch` is active in the build unless `PKGBUILD` references it.

## Recommended verification checklist

- After `build.sh` edits:
  - run `bash -n build.sh` for syntax check
  - verify grep assertion expected counts still match (run the sed/awk on a copy of `linux/PKGBUILD` and count)
  - if adding new sed/awk patterns, add corresponding grep assertions
- After `PKGBUILD` edits:
  - reread the edited functions
  - regenerate `.SRCINFO` if required
  - run `makepkg -o` at minimum for patch/config logic changes
- After packaging/build changes:
  - run `makepkg` if feasible
- After config-only changes:
  - preserve `config.x86_64` syntax and formatting
  - prefer `makepkg -o` or a full build when feasible
- After metadata-only changes:
  - confirm `.SRCINFO` matches `PKGBUILD`

## Practical summary

- Start by deciding whether the change belongs at repo root or under `linux/`.
- Read `linux/PKGBUILD` before making build assumptions.
- Use Arch packaging conventions, not generic software-project conventions.
- Prefer minimal, surgical edits.
- Keep generated files synchronized.
- When asked for “tests”, explain the absence of a test framework and run the closest valid packaging/build verification instead.
