{ sources ? import ./nix/sources.nix }:
let pkgs = import sources.nixpkgs {}; in
pkgs.stdenv.mkDerivation rec {
  pname = "mkchoice";
  version = "0.0";

  zig = pkgs.zig;
  buildInputs = [zig];

  src = ./.;
  builder = ./builder.sh;
}
