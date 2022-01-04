# SPDX-FileCopyrightText: 2021 Serokell <https://serokell.io/>
#
# SPDX-License-Identifier: CC0-1.0

{
  description = "pandoc porting attempt";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        #haskellPackages = pkgs.haskellPackages;
        haskellPackages = pkgs.haskell.packages.${compiler};

        #jailbreakUnbreak = pkg:
        #  pkgs.haskell.lib.doJailbreak (pkg.overrideAttrs (_: { meta = { }; }));
        compiler = "ghc8107";

        packageName = "pandoc";
      in
      let inherit (pkgs.haskell.lib) dontHaddock; in
      {
        packages.${packageName} =
          dontHaddock (haskellPackages.callCabal2nix packageName self rec {
            # Dependency overrides go here
            doctemplates = haskellPackages."doctemplates_0_10_0_1";
            ipynb = haskellPackages.callPackage
              ({ lib
               , fetchFromGitHub
               , mkDerivation
               , aeson
               , base
               , base64-bytestring
               , bytestring
               , containers
               , directory
               , filepath
               , microlens
               , microlens-aeson
               , tasty
               , tasty-hunit
               , text
               , unordered-containers
               }:
                mkDerivation {
                  pname = "ipynb";
                  version = "0.2";
                  src = fetchFromGitHub {
                    owner = "jgm";
                    repo = "ipynb";
                    # 2022-01-04
                    rev = "00246af10885c2ad4413ace4f69a7e6c88297a08";
                    sha256 = "e7Z5DleDzUqkfVv7B39O3tP2Hd5Ty9WvdIPhKsUq6Lo=";
                  };
                  libraryHaskellDepends = [
                    aeson
                    base
                    base64-bytestring
                    bytestring
                    containers
                    text
                    unordered-containers
                  ];
                  testHaskellDepends = [
                    aeson
                    base
                    bytestring
                    directory
                    filepath
                    microlens
                    microlens-aeson
                    tasty
                    tasty-hunit
                    text
                  ];
                  description = "Data structure for working with Jupyter notebooks (ipynb)";
                  license = lib.licenses.bsd3;
                })
              { };
          });

        defaultPackage = self.packages.${system}.${packageName};

        devShell = pkgs.mkShell {
          buildInputs = with haskellPackages; [
            haskell-language-server
            ghcid
            cabal-install
          ];
          inputsFrom = builtins.attrValues self.packages.${system};
        };
      });
}
