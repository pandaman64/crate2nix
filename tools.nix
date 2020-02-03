#
# Some tools that might be useful in builds.
#
# Part of the "public" API of crate2nix in the sense that we will try to
# avoid breaking the API and/or mention breakages in the CHANGELOG.
#

{ pkgs? import ./nixpkgs.nix { config = {}; }, lib? pkgs.lib}:

let 
  cargo_nix = pkgs.callPackage ./crate2nix/Cargo.nix {};
  crate2nix = cargo_nix.rootCrate.build;

in rec {

  # Returns the whole top-level function generated by crate2nix which is typically
  # called with `pkgs.callPackage`.
  #
  # name: will be part of the derivation name
  # src: the source that is needed to build the crate, usually the crate/workspace root directory
  # cargoToml: Path to the Cargo.toml file relative to src, "Cargo.toml" by default.
  generate = {name, src, cargoToml? "Cargo.toml", additionalCargoNixArgs? []}: 
    let 
      cargoLock = (dirOf "${src}/${cargoToml}") + "/Cargo.lock";
      vendor = internal.vendorSupport { inherit cargoLock; };
    in
      pkgs.stdenv.mkDerivation {
        name = "${name}-crate2nix";

        buildInputs = [ pkgs.cargo crate2nix ];

        preferLocalBuild = true;
        buildCommand = ''
            set -e

            mkdir -p "$out/cargo"

            export CARGO_HOME="$out/cargo"
            export HOME="$out"

            cp ${vendor.cargoConfig} $out/cargo/config

            crate_hashes="${src}/crate-hashes.json"
            if ! test -r "$crate_hashes" ; then
              crate_hashes="$out/crate-hashes.json"
              echo -n No existing crate-hashes.json >&2
              echo ' => setting path to output dir' >&2
            fi

            set -x
            crate2nix generate \
              ${lib.escapeShellArgs additionalCargoNixArgs} \
              -f ${src}/${cargoToml} \
              -h "$crate_hashes" \
              -o $out/default.nix || {
              { set +x; } 2>/dev/null
              echo "crate2nix failed." >&2
              echo "== cargo/config (BEGIN)" >&2
              sed 's/^/    /' $out/cargo/config >&2
              echo ""
              echo "== cargo/config (END)" >&2
              echo ""
              echo "== crate-hashes.json (BEGIN)" >&2
              sed 's/^/    /' $crate_hashes >&2
              echo ""
              echo "== crate-hashes.json (END)" >&2
              exit 3
            }
            { set +x; } 2>/dev/null 
        '';
      };

  # Returns a derivation for a rust binary package.
  #
  # name: will be part of the derivation name
  # src: the source that is needed to build the crate, usually the crate/workspace root directory
  # cargoToml: Path to the Cargo.toml file relative to src, "Cargo.toml" by default.
  generated = {cargoToml? "Cargo.toml", ...} @ args:
    pkgs.callPackage (generate args) {};

  internal = rec {
    # Unpack sources and add a .cargo-checksum.json file to make cargo happy.
    unpacked = {sha256, src}:
      assert builtins.isString sha256;
      assert builtins.isAttrs src;

      pkgs.runCommand (lib.removeSuffix ".tar.gz" src.name) {}
      ''
        mkdir -p $out
        tar -xzf ${src} --strip-components=1 -C $out
        echo '{"package":"${sha256}","files":{}}' > $out/.cargo-checksum.json
      '';

    sourceType = {source ? null, ...} @ package:
      assert source == null || builtins.isString source;

      if source == null then
        null
      else if source == "registry+https://github.com/rust-lang/crates.io-index" then
        "crates-io"
      else if lib.hasPrefix "git+" source then
        "git"
      else 
        builtins.throw "unknown source type: ${source}";

    # Extracts URL and rev from a git source URL.
    #
    # Crude, should be more robust :(
    parseGitSource = source:
      assert builtins.isString source;

      let
        withoutGitPlus = lib.removePrefix "git+" source;
        splitHash = lib.splitString "#" withoutGitPlus;
        splitQuestion = lib.concatMap (lib.splitString "?") splitHash;
      in {
        url = builtins.head splitQuestion;
        rev = lib.last splitQuestion;
      };

    vendorSupport = { cargoLock? ./Cargo.lock, ...}: 
      rec {
        locked = builtins.fromTOML (builtins.readFile cargoLock);
        hashesFile = "${dirOf cargoLock}/crate-hashes.json";
        hashes = 
          if builtins.pathExists hashesFile
          then builtins.fromJSON (builtins.readFile hashesFile)
          else {};
        packages = assert builtins.isList locked.package; locked.package;
        packagesWithType = builtins.filter (pkg: (sourceType pkg) != null) packages;
        packagesByType = lib.groupBy sourceType packagesWithType;

        # Returns a derivation with all the transitive dependencies in
        # sub directories suitable for cargo vendoring.
        vendoredSources =
          let 
            support = vendorSupport { inherit cargoLock; };

            crateSources = 
              builtins.map 
                (package: 
                  let
                    fetcher = fetchers.${sourceType package};
                    source = fetcher package;
                  in 
                  {
                    name = builtins.baseNameOf source; 
                    path = source; 
                  })
                support.packagesWithType;
          in 
            pkgs.linkFarm "deps" crateSources;

        cargoConfig = 
          let
            gitSourceConfig = 
              source:

              assert builtins.isString source;

              let parsed = parseGitSource source;
              in ''

              [source."${parsed.url}"]
              git = "${parsed.url}"
              rev = "${parsed.rev}"
              replace-with = "vendored-sources"
              ''; 
            gitSources = builtins.map ({source, ...}: source) packagesByType."git" or [];
            gitSourcesUnique = lib.unique gitSources;
            gitSourceConfigs = builtins.map gitSourceConfig gitSourcesUnique;
            gitSourceConfigsString = lib.concatStrings gitSourceConfigs;
          in
            pkgs.writeText
              "vendor-config"
              ''
              [source.crates-io]
              replace-with = "vendored-sources"
              ${gitSourceConfigsString}

              [source.vendored-sources]
              directory = "${vendoredSources}"      
              '';

        # Fetchers by source type that can fetch the package source.
        fetchers = {
          "crates-io" = {name, version, source, ...} @ package:
            assert (sourceType package) == "crates-io";

            let sha256 = 
              package.checksum 
              or locked.metadata."checksum ${name} ${version} (${source})"
              or (builtins.throw "Checksum for ${name} ${version} (${source}) not found in Cargo.lock");
            in unpacked {
              src = pkgs.fetchurl {
                name = "crates-io-${name}-${version}.tar.gz";
                url = "https://crates.io/api/v1/crates/${name}/${version}/download";
                inherit sha256;
              };
              inherit sha256;
            };

          "git" = {name, version, source, ...} @ package:
            assert (sourceType package) == "git";

            let packageId = "${name} ${version} (${source})";
                sha256 = 
                  hashes.${packageId} 
                  or (builtins.throw "Checksum for ${packageId} not found in crate-hashes.json");
                parsed = parseGitSource source;
                src = pkgs.fetchgit {
                  name = "${name}-${version}";
                  inherit sha256;
                  inherit (parsed) url rev;
                };
            in pkgs.runCommand (lib.removeSuffix ".tar.gz" src.name) {}
              ''
                mkdir -p $out
                cp -apR ${src}/* $out
                echo '{"package":null,"files":{}}' > $out/.cargo-checksum.json
              '';

        };
      };
  };
}

