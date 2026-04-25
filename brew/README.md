# Homebrew formula

To publish on Homebrew, push `velk.rb` into a tap repo named
`vincentvella/homebrew-velk` (the `homebrew-` prefix is required by the
`brew tap` resolver). Steps:

```sh
gh repo create vincentvella/homebrew-velk --public --description "Homebrew tap for velk"
git clone git@github.com:vincentvella/homebrew-velk.git
cp brew/velk.rb homebrew-velk/Formula/velk.rb
cd homebrew-velk && git add Formula/velk.rb && git commit -m "velk 0.0.1" && git push
```

Then anyone can install with:

```sh
brew tap vincentvella/velk
brew install velk
```

## Bumping the version

After a new GitHub release is published:

1. Update the `version` line at the top of `velk.rb`.
2. Replace each `sha256` with the matching value from
   `https://github.com/vincentvella/velk/releases/download/vX.Y.Z/velk-<os>-<arch>.tar.gz.sha256`.
3. Commit + push the tap repo.

The CI workflow at `.github/workflows/release.yml` already publishes
the four `.tar.gz` artifacts plus matching `.sha256` files for every
tagged release.
