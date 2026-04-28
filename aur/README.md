# AUR — Arch User Repository

`aur/velk-bin/` holds the source-of-truth `PKGBUILD` + `.SRCINFO` for the
[`velk-bin`](https://aur.archlinux.org/packages/velk-bin) AUR package.
Binary install: downloads the appropriate `velk-linux-{x64,arm64}.tar.gz`
from the GitHub release matching the version, drops `velk` at
`/usr/bin/velk` and the LICENSE under `/usr/share/licenses/`.

## Why `velk-bin` only (no source `velk`)?

Building from source on Arch needs Zig 0.16 from the AUR
(`zig-binary` or similar) and pulls in cmake + the cmark-gfm
deps. The binary tarball is statically linked enough on the linux
gnu builds (and entirely static for the `-musl` variants) that
this is the right default for most users.

If you want the source build, install Zig 0.16 yourself and run
`zig build install-local` from a checkout — same result.

## One-time setup (maintainer)

1. Create the AUR account at <https://aur.archlinux.org> and add an
   SSH public key to your account profile.
2. Clone the AUR repo (each AUR package is a separate git repo):
   ```sh
   git clone ssh://aur@aur.archlinux.org/velk-bin.git
   ```
3. Copy `aur/velk-bin/PKGBUILD` and `aur/velk-bin/.SRCINFO` into the
   clone, fill in the `sha256sums_*` from
   `https://github.com/vincentvella/velk/releases/download/v<ver>/velk-linux-<arch>.tar.gz.sha256`
   (replace the `SKIP` placeholders), commit, and push.

## Releasing on every tag (manual workflow)

For each new release tag `vX.Y.Z`:

```sh
cd aur/velk-bin
sed -i "s/^pkgver=.*/pkgver=$VER/" PKGBUILD
sed -i "s|pkgver = .*|pkgver = $VER|"   .SRCINFO
sed -i "s|/v[0-9.]*/|/v$VER/|g"           .SRCINFO PKGBUILD
sed -i "s|velk-[0-9.]*-|velk-$VER-|g"     .SRCINFO PKGBUILD

# Fetch the per-arch sha256 values from the release.
for arch in x64 arm64; do
  hash=$(curl -fsSL "https://github.com/vincentvella/velk/releases/download/v$VER/velk-linux-$arch.tar.gz.sha256" | awk '{print $1}')
  case "$arch" in
    x64)   sed -i "s|^sha256sums_x86_64=.*|sha256sums_x86_64=('$hash')|" PKGBUILD ;;
    arm64) sed -i "s|^sha256sums_aarch64=.*|sha256sums_aarch64=('$hash')|" PKGBUILD ;;
  esac
done

# Re-sync .SRCINFO (or run `makepkg --printsrcinfo > .SRCINFO` from
# an Arch container if you have one).
```

Then commit + push to the AUR git remote:

```sh
cd /path/to/your/aur/velk-bin/clone
cp /path/to/velk/aur/velk-bin/{PKGBUILD,.SRCINFO} .
git add PKGBUILD .SRCINFO
git commit -m "velk-bin $VER"
git push
```

## Future: automate via release.yml

Like the `homebrew` job, a future `aur` job can clone the AUR repo
via SSH (using an `AUR_SSH_KEY` secret), bump versions + sha256s,
and push. Skipped today because it requires a separate AUR account
+ key setup — file an issue if you want it prioritized.
