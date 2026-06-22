{
  description = "cairn - a SQLite-backed task graph and observation store for kli";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/88d3861acdd3d2f0e361767018218e51810df8a1";
    cl-deps.url = "github:kleisli-io/cl-deps";
    cl-deps.inputs.nixpkgs.follows = "nixpkgs";
    kli-new.url = "git+ssh://git@github.com/kleisli-io/kli-new.git";
    kli-new.inputs.nixpkgs.follows = "nixpkgs";
    kli-new.inputs.cl-deps.follows = "cl-deps";
  };

  outputs = { self, nixpkgs, cl-deps, kli-new, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      buildFor = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (cl-deps.lib.${system}) buildLisp lisp;
          kli = kli-new.checks.${system}.library;
        in
        import ./build.nix {
          inherit pkgs buildLisp lisp kli;
        };
    in
    {
      packages = forAllSystems (system:
        let library = buildFor system; in {
          default = library;
          cairn = library;
        });

      checks = forAllSystems (system:
        let library = buildFor system; in {
          inherit library;
          tests = library.tests;
          drift = library.driftGate;
        });

      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system}; in {
          default = pkgs.mkShell {
            packages = [ pkgs.sbcl pkgs.sqlite ];
          };
        });
    };
}
