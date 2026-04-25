# Homebrew formula

`brew/velk.rb` is the source-of-truth template. Publishing to the tap is
automated by `.github/workflows/release.yml` — the `homebrew` job runs after
each tagged release, downloads the four `.sha256` files from the GitHub
release, regenerates the formula with the new version + hashes, and pushes to
the tap repo.

## One-time setup

1. Create the tap repo (the `homebrew-` prefix is required by `brew tap`):

   ```sh
   gh repo create vincentvella/homebrew-velk --public --description "Homebrew tap for velk"
   ```

2. Create a fine-grained Personal Access Token with `Contents: read & write`
   scoped to `vincentvella/homebrew-velk`. (Or a classic PAT with `repo`
   scope if you prefer.)

3. Add the token to this repo's secrets as `HOMEBREW_TAP_TOKEN`:

   ```sh
   gh secret set HOMEBREW_TAP_TOKEN --body "<token>"
   ```

   Optional: override the tap repo path with a repo variable:

   ```sh
   gh variable set HOMEBREW_TAP_REPO --body "youruser/homebrew-velk"
   ```

4. The workflow gates on the secret being present — if it isn't set, the job
   skips cleanly so the rest of the release still publishes.

## Releasing

Tag and push:

```sh
git tag v0.0.2
git push origin v0.0.2
```

The release workflow will:
1. Build the four target binaries (darwin/linux × arm64/x64)
2. Upload them + sha256s to the GitHub release
3. Regenerate `brew/velk.rb` from those sha256s and push it to
   `Formula/velk.rb` in the tap repo

## Installing

```sh
brew tap vincentvella/velk
brew install velk
```

## Manual override

If you need to publish a formula by hand (e.g. tap-only patch release, or the
PAT expired), the regenerated `brew/velk.rb` from a release run can be copied
straight into the tap.
