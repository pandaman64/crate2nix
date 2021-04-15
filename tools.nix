#
# Some tools that might be useful in builds.
#
# Part of the "public" API of crate2nix in the sense that we will try to
# avoid breaking the API and/or mention breakages in the CHANGELOG.
#

{ pkgs ? import ./nix/nixpkgs.nix { config = { }; }
, lib ? pkgs.lib
, stdenv ? pkgs.stdenv
, strictDeprecation ? true
}:
let
  cargoNix = import ./crate2nix/Cargo.nix { inherit pkgs strictDeprecation; };
  crate2nix = cargoNix.rootCrate.build;
in
rec {

  /* Returns the whole top-level function generated by crate2nix (`Cargo.nix`)
     which is typically called with `pkgs.callPackage`.

     name: will be part of the derivation name
     src: the source that is needed to build the crate, usually the
          crate/workspace root directory
     cargoToml: Path to the Cargo.toml file relative to src, "Cargo.toml" by
     default.
  */
  generatedCargoNix =
    { name
    , src
    , cargoToml ? "Cargo.toml"
    , additionalCargoNixArgs ? [ ]
    }:
    let
      crateDir = dirOf (src + "/${cargoToml}");
      vendor = internal.vendorSupport { inherit crateDir; };
    in
    stdenv.mkDerivation {
      name = "${name}-crate2nix";

      buildInputs = [ pkgs.cargo pkgs.jq crate2nix ];
      preferLocalBuild = true;

      inherit src;
      phases = [ "unpackPhase" "buildPhase" ];

      buildPhase = ''
        set -e

        mkdir -p "$out/cargo"

        export CARGO_HOME="$out/cargo"
        export HOME="$out"

        cp ${vendor.cargoConfig} $out/cargo/config

        crate_hashes="$out/crate-hashes.json"
        if test -r "./crate-hashes.json" ; then
          printf "$(jq -s '.[0] * ${builtins.toJSON vendor.extraHashes}' "./crate-hashes.json")" > "$crate_hashes"
          chmod +w "$crate_hashes"
        else
          printf '${builtins.toJSON vendor.extraHashes}' > "$crate_hashes"
        fi

        crate2nix_options=""
        if [ -r ./${cargoToml} ]; then
          create2nix_options+=" -f ./${cargoToml}"
        fi

        if test -r "./crate2nix.json" ; then
          cp "./crate2nix.json" "$out/crate2nix.json"
          create2nix_options+=" -c $out/crate2nix.json"
        fi

        if test -r "${src}/crate2nix-sources" ; then
          ln -s "${src}/crate2nix-sources" "$out/crate2nix-sources"
        fi

        set -x

        crate2nix generate \
          $create2nix_options \
          -o "Cargo-generated.nix" \
          -h "$crate_hashes" \
          ${lib.escapeShellArgs additionalCargoNixArgs} || {
          { set +x; } 2>/dev/null
          echo "crate2nix failed." >&2
          echo "== cargo/config (BEGIN)" >&2
          sed 's/^/    /' $out/cargo/config >&2
          echo ""
          echo "== cargo/config (END)" >&2
            echo ""
            echo "== crate-hashes.json (BEGIN)" >&2
          if [ -r $crate_hashes ]; then
            sed 's/^/    /' $crate_hashes >&2
            echo ""
          else
            echo "$crate_hashes missing"
          fi
          echo "== crate-hashes.json (END)" >&2
          echo ""
          echo "== ls -la (BEGIN)" >&2
          ls -la
          echo "== ls -la (END)" >&2
          exit 3
        }
        { set +x; } 2>/dev/null

        if test -r "./crate-hashes.json" ; then
          set -x
          diff -u "./crate-hashes.json" $crate_hashes
         { set +x; } 2>/dev/null
        fi

        cp -r . $out/crate

        echo "import ./crate/Cargo-generated.nix" > $out/default.nix
      '';

    };

  # Applies the default arguments from pkgs to the generated `Cargo.nix` file.
  #
  # name: will be part of the derivation name
  # src: the source that is needed to build the crate, usually the crate/workspace root directory
  # cargoToml: Path to the Cargo.toml file relative to src, "Cargo.toml" by default.
  appliedCargoNix = { cargoToml ? "Cargo.toml", ... } @ args:
    import (generatedCargoNix args) { inherit pkgs; };

  generate =
    cargoNix.internal.deprecationWarning
      "crate2nix/tools.nix: generate deprecated since 0.7. Use generatedCargoNix instead."
      generatedCargoNix;
  generated =
    cargoNix.internal.deprecationWarning
      "crate2nix/tools.nix: generated deprecated since 0.7. Use appliedCargoNix in instead."
      appliedCargoNix;

  internal = rec {
    # Unpack sources and add a .cargo-checksum.json file to make cargo happy.
    unpacked = { sha256, src }:
      assert builtins.isString sha256;
      assert builtins.isAttrs src;

      pkgs.runCommand (lib.removeSuffix ".tar.gz" src.name) { }
        ''
          mkdir -p $out
          tar -xzf ${src} --strip-components=1 -C $out
          echo '{"package":"${sha256}","files":{}}' > $out/.cargo-checksum.json
        '';

    sourceType = { source ? null, ... } @ package:
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
      in
      {
        url = builtins.head splitQuestion;
        rev = lib.last splitQuestion;
      };

    vendorSupport = { crateDir ? ./., ... }:
      rec {
        toPackageId = { name, version, source, ... }:
          "${name} ${version} (${source})";

        lockFiles =
          let
            fromCrateDir =
              if builtins.pathExists (crateDir + "/Cargo.lock")
              then [ (crateDir + "/Cargo.lock") ]
              else [ ];
            fromSources =
              if builtins.pathExists (crateDir + "/crate2nix-sources")
              then
                let
                  subdirsTypes = builtins.readDir (crateDir + "/crate2nix-sources");
                  subdirs = builtins.attrNames subdirsTypes;
                  toLockFile = subdir: (crateDir + "/crate2nix-sources/${subdir}/Cargo.lock");
                in
                builtins.map toLockFile subdirs
              else [ ];
          in
          fromCrateDir ++ fromSources;

        locked =
          let
            parseFile = cargoLock: builtins.fromTOML (builtins.readFile cargoLock);
            allParsedFiles = builtins.map parseFile lockFiles;
            merge = merged: lock:
              {
                package = merged.package ++ lock.package or [ ];
                metadata = merged.metadata // lock.metadata or { };
              };
          in
          lib.foldl merge { package = [ ]; metadata = { }; } allParsedFiles;

        hashesFiles =
          builtins.map
            (cargoLock: "${dirOf cargoLock}/crate-hashes.json")
            lockFiles;
        hashes =
          let
            parseFile = hashesFile:
              if builtins.pathExists hashesFile
              then builtins.fromJSON (builtins.readFile hashesFile)
              else { };
            parsedFiles = builtins.map parseFile hashesFiles;
          in
          lib.foldl (a: b: a // b) { } parsedFiles;

        unhashedGitDeps = builtins.filter (p: ! hashes ? ${toPackageId p}) packagesByType.git or [ ];

        mkGitHash = { source, ... }@attrs:
          let
            parsed = parseGitSource source;
            src = builtins.fetchGit {
              submodules = true;
              inherit (parsed) url rev;
              ref = attrs.branch or "master";
            };
            hash = pkgs.runCommand "hash-of-${attrs.name}" { nativeBuildInputs = [ pkgs.nix ]; } ''
              echo -n "$(nix-hash --type sha256 ${src})" > $out
            '';
          in
          {
            name = toPackageId attrs;
            value = builtins.readFile hash;
          };

        # Fetching git submodules with builtins.fetchGit is only supported in nix > 2.3
        extraHashes = lib.optionalAttrs
          (builtins.compareVersions builtins.nixVersion "2.3" == 1)
          (builtins.listToAttrs (map mkGitHash unhashedGitDeps));

        packages =
          let
            packagesWithDuplicates = assert builtins.isList locked.package; locked.package;
            packagesWithoutLocal = builtins.filter (p: p ? source) packagesWithDuplicates;
            packageById = package: { name = toPackageId package; value = package; };
            packagesById = builtins.listToAttrs (builtins.map packageById packagesWithoutLocal);
          in
          builtins.attrValues packagesById;
        packagesWithType = builtins.filter (pkg: (sourceType pkg) != null) packages;
        packagesByType = lib.groupBy sourceType packagesWithType;

        # Returns a derivation with all the transitive dependencies in
        # sub directories suitable for cargo vendoring.
        vendoredSources =
          let
            crateSources =
              builtins.map
                (
                  package:
                  let
                    fetcher = fetchers.${sourceType package};
                    source = fetcher package;
                  in
                  {
                    name = builtins.baseNameOf source;
                    path = source;
                  }
                )
                packagesWithType;
          in
          pkgs.linkFarm "deps" crateSources;

        cargoConfig =
          let
            gitSourceConfig =
              { source, ... }@attrs:

                assert builtins.isString source;
                let
                  parsed = parseGitSource source;
                in
                ''

              [source."${parsed.url}"]
              git = "${parsed.url}"
              rev = "${parsed.rev}"
              ${lib.optionalString (isNull (builtins.match ".*\\?rev=[0-9a-z]{40}.*" source)) ''branch = "${attrs.branch or "master"}"''}
              replace-with = "vendored-sources"
              '';
            gitSources = packagesByType."git" or [ ];
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
          "crates-io" = { name, version, source, ... } @ package:
            assert (sourceType package) == "crates-io";
            let
              packageId = toPackageId package;
              sha256 =
                package.checksum
                  or locked.metadata."checksum ${packageId}"
                  or (builtins.throw "Checksum for ${packageId} not found in Cargo.lock");
            in
            unpacked {
              src = pkgs.fetchurl {
                name = "crates-io-${name}-${version}.tar.gz";
                # https://www.pietroalbini.org/blog/downloading-crates-io/
                # Not rate-limited, CDN URL.
                url = "https://static.crates.io/crates/${name}/${name}-${version}.crate";
                inherit sha256;
              };
              inherit sha256;
            };

          "git" = { name, version, source, ... } @ package:
            assert (sourceType package) == "git";
            let
              packageId = toPackageId package;
              sha256 =
                hashes.${packageId}
                  or extraHashes.${packageId}
                  or (builtins.throw "Checksum for ${packageId} not found in crate-hashes.json");
              parsed = parseGitSource source;
              src = pkgs.fetchgit {
                name = "${name}-${version}";
                inherit sha256;
                inherit (parsed) url rev;
              };
            in
            pkgs.runCommand (lib.removeSuffix ".tar.gz" src.name) { }
              ''
                mkdir -p $out
                cp -apR ${src}/* $out
                echo '{"package":null,"files":{}}' > $out/.cargo-checksum.json
              '';

        };
      };
  };
}
