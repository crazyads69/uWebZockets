{
  description = "µWebZockets Zig WebSocket and HTTP server library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zon2nix.url = "github:jcollie/zon2nix";
  };

  outputs = inputs @ {
    self,
    flake-parts,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        inherit (pkgs) lib;
        isLinux = pkgs.stdenv.hostPlatform.isLinux;
        releaseVersion = "1.8.5";
        pkgsMusl =
          if isLinux
          then pkgs.pkgsMusl
          else null;
        nativeTarget =
          if isLinux
          then "${lib.removeSuffix "-linux" system}-linux-gnu"
          else lib.replaceStrings ["-darwin"] ["-macos"] system;
        muslTarget =
          if isLinux
          then "${lib.removeSuffix "-linux" system}-linux-musl"
          else null;

        zig = inputs.zig-overlay.packages.${system}."0.16.0" or pkgs.zig;
        # zon2nix does not publish packages for every supported Darwin system.
        zon2nixPackage = (inputs.zon2nix.packages.${system} or {}).zon2nix or null;
        zigPackages = pkgs.callPackage ./build.zig.zon.nix {
          zig_0_16 = zig;
        };

        source = lib.cleanSourceWith {
          src = self;
          filter = path: type: let
            name = baseNameOf path;
          in
            !lib.elem name [
              ".git"
              ".zig-cache"
              "result"
              "zig-out"
              "zig-pkg"
            ];
        };

        # Zig's C/C++ toolchain builds BoringSSL, lsquic, libdeflate, and zlib
        # directly, so the shell only provides Zig itself.
        nativeBuildInputs = [zig];

        seedZigCache = ''
          export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
          mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p"

          for package in ${zigPackages}/*; do
            package_name="$(basename "$package")"
            if [ -d "$package" ]; then
              fetched_hash="$(zig fetch \
                --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
                "$package")"
              test "$fetched_hash" = "$package_name"
              continue
            fi

            cp -L "$package" \
              "$ZIG_GLOBAL_CACHE_DIR/p/$package_name.tar.gz"
          done

          chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
        '';

        mkPackage = packagePkgs: targetTriple:
          packagePkgs.stdenv.mkDerivation {
            pname = "uwebzockets";
            version = releaseVersion;
            src = source;
            strictDeps = true;
            inherit nativeBuildInputs;
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              ${seedZigCache}
              zig build lib \
                -Doptimize=ReleaseFast \
                -Dtarget=${targetTriple} \
                --prefix "$out"
              runHook postBuild
            '';
            dontInstall = true;
          };

        mkCompileCheck = packagePkgs: targetTriple:
          packagePkgs.stdenv.mkDerivation {
            pname = "uwebzockets-compile-tests";
            version = releaseVersion;
            src = source;
            strictDeps = true;
            inherit nativeBuildInputs;
            dontConfigure = true;
            buildPhase = ''
              runHook preBuild
              ${seedZigCache}
              zig build test-compile \
                -Doptimize=ReleaseSafe \
                -Dtarget=${targetTriple} \
                --prefix "$out"
              runHook postBuild
            '';
            installPhase = ''
              touch "$out"
            '';
          };

        mkDevShell = packagePkgs: targetTriple: let
          llvmCompilerRt = packagePkgs.llvmPackages_21.compiler-rt;
          supportsSanitizers =
            isLinux && packagePkgs.stdenv.hostPlatform.isGnu;
        in
          packagePkgs.mkShell (
            {
              packages =
                [
                  zig
                  pkgs.zls
                  pkgs.ripgrep
                  pkgs.wrk
                ]
                ++ lib.optional
                (zon2nixPackage != null && isLinux && packagePkgs.stdenv.hostPlatform.isGnu)
                zon2nixPackage
                ++ lib.optional supportsSanitizers llvmCompilerRt;
              UWEBZOCKETS_DEFAULT_TARGET = targetTriple;
            }
            // lib.optionalAttrs isLinux {
              UWEBZOCKETS_RUNTIME_DYNAMIC_LINKER =
                packagePkgs.stdenv.cc.bintools.dynamicLinker;
              UWEBZOCKETS_RUNTIME_LIBRARY_PATH = "${lib.getLib packagePkgs.stdenv.cc.libc}/lib";
            }
            // lib.optionalAttrs supportsSanitizers {
              UWEBZOCKETS_SANITIZER_DYNAMIC_LINKER =
                packagePkgs.stdenv.cc.bintools.dynamicLinker;
              UWEBZOCKETS_SANITIZER_LIB_DIR = "${lib.getLib llvmCompilerRt}/lib/linux";
              UWEBZOCKETS_SANITIZER_LIBC_DIR = "${lib.getLib packagePkgs.stdenv.cc.libc}/lib";
            }
          );
      in {
        formatter = pkgs.alejandra;

        # Source-only distribution: `nix build` produces a local native build,
        # but no per-platform binary packages are published. Consumers fetch
        # the tagged source with `zig fetch` and let the package manager build
        # the pinned dependencies.
        packages.default = mkPackage pkgs nativeTarget;

        checks =
          {
            compile-tests = mkCompileCheck pkgs nativeTarget;
          }
          // lib.optionalAttrs isLinux {
            compile-tests-musl = mkCompileCheck pkgsMusl muslTarget;
          };

        devShells =
          {
            default = mkDevShell pkgs nativeTarget;
          }
          // lib.optionalAttrs isLinux {
            musl = mkDevShell pkgsMusl muslTarget;
          };
      };
    };
}
