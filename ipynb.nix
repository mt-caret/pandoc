# below is based off of the ipynb package definited in
# pkgs/development/haskell-modules/hackage-packages.nix in NixOS/nixpkgs
# revision c0bd23b130d32b101d74d22e1a659f2de1ca7caf
{ lib
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
}
