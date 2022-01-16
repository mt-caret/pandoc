# Below flake is based off of Serokell's template as introduced in the
# following blog post:
# https://serokell.io/blog/practical-nix-flakes#packaging-existing-applications
{
  description = "pandoc porting attempt";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        #compiler = "ghc8107";
        compiler = "ghcjs";

        overlay =
          self: super:
          let inherit (super.haskell.lib) dontCheck dontHaddock overrideCabal; in
          {
            haskell = super.haskell // {
              packages = super.haskell.packages // {
                ghcjs = super.haskell.packages.ghcjs.override {
                  overrides = newpkgs: oldpkgs: {
                    # tests break
                    tasty-golden = dontCheck oldpkgs.tasty-golden;
                    unliftio = dontCheck oldpkgs.unliftio;
                    conduit = dontCheck oldpkgs.conduit;

                    # TODO: takes too long to run test, maybe retry afterwards?
                    vector = dontCheck oldpkgs.vector;
                    mono-traversable = dontCheck oldpkgs.mono-traversable;
                    zlib = dontCheck oldpkgs.zlib;

                    # linking test binary overflows stack
                    doclayout = dontCheck oldpkgs.doclayout;
                    commonmark = dontCheck oldpkgs.commonmark;
                    texmath = dontCheck oldpkgs.texmath;

                    # test depends on doctest, which doesn't work on ghcjs
                    foldl = dontCheck oldpkgs.foldl;
                  };
                };
              };
            };
          };

        pkgs = import nixpkgs { inherit system; overlays = [ overlay ]; };

        haskellPackages = pkgs.haskell.packages.${compiler};

        packageName = "pandoc";
      in
      let
        inherit (pkgs.haskell.lib) dontHaddock dontCheck;
        inherit (pkgs.haskell.lib.compose) overrideCabal;
      in
      let
        # hit this issue when linking TH stuff for pandoc:
        # https://github.com/reflex-frp/reflex-platform/issues/422
        enbiggenStack =
          overrideCabal (drv:
            {
              configureFlags =
                ((drv.configureFlags or [ ]) ++
                  [
                    "--ghcjs-option=+RTS"
                    "--ghcjs-option=-K0"
                    "--ghcjs-option=-RTS"
                    "--ghcjs-options=-dedupe"
                  ]);
            });
      in
      {
        packages.${packageName} =
          dontHaddock (enbiggenStack (haskellPackages.callCabal2nix packageName self rec {
            # Dependency overrides go here
            doctemplates = haskellPackages."doctemplates_0_10_0_1";
            ipynb = haskellPackages.callPackage ./ipynb.nix { };
          }));

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
