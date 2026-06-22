{ pkgs, buildLisp, lisp, kli, ... }:

import ./build.nix {
  inherit pkgs buildLisp lisp kli;
}
