{ sources ? import ./nix/sources.nix }:
let pkgs = import sources.nixpkgs {}; in
pkgs.stdenv.mkDerivation {
  name = "mkchoice";
  zig = pkgs.zig;
  buildInputs = [pkgs.zig];
}
