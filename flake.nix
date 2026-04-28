{
  description = "velk — Zig 0.16 terminal AI harness (Anthropic + OpenAI, MCP, vim mode)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # zig-overlay pins specific Zig versions; we need 0.16.0 which
    # isn't in nixpkgs yet.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        zig = zig-overlay.packages.${system}."0.16.0";

        velk = pkgs.stdenv.mkDerivation {
          pname = "velk";
          version = "0.0.1";
          src = ./.;

          nativeBuildInputs = [ zig pkgs.cmake ];

          # Zig manages its own cache; point it at a writable
          # build-local dir so the sandbox doesn't try to write to
          # $HOME (which is unset under nix builds).
          configurePhase = ''
            export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
            export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-cache-local"
            mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
          '';

          buildPhase = ''
            zig build -Doptimize=ReleaseFast --prefix "$out"
          '';

          # `zig build install` already drops the binary in $out/bin.
          installPhase = "true";

          # The unit tests + smoke harness require network (the mock
          # mock-server case spawns python3 from PATH) and write to
          # $XDG_*; skip in the nix sandbox. Run `nix develop` if you
          # want to invoke them against a checkout.
          doCheck = false;

          meta = with pkgs.lib; {
            description = "Zig 0.16 terminal AI harness (Anthropic + OpenAI, MCP, vim mode)";
            homepage = "https://github.com/vincentvella/velk";
            license = licenses.asl20;
            mainProgram = "velk";
            platforms = platforms.unix;
          };
        };
      in
      {
        packages.default = velk;
        packages.velk = velk;

        apps.default = {
          type = "app";
          program = "${velk}/bin/velk";
        };
        apps.velk = self.apps.${system}.default;

        devShells.default = pkgs.mkShell {
          packages = [
            zig
            pkgs.python3
            pkgs.git
          ];
          shellHook = ''
            echo "velk dev shell — zig $(zig version), python $(python3 --version)"
            echo "  zig build         — build"
            echo "  zig build test    — unit tests"
            echo "  zig build smoke   — CLI smoke tests"
            echo "  zig build tui-test — TUI pty harness"
          '';
        };
      });
}
