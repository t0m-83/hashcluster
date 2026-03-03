{
  description = "HashCluster - Distributed file hashing with Phoenix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            elixir_1_16
            erlang_26
            inotify-tools   # pour le live-reload
            git
          ];

          shellHook = ''
            export MIX_HOME=$PWD/.mix
            export HEX_HOME=$PWD/.hex
            export PATH=$MIX_HOME/bin:$HEX_HOME/bin:$PATH
            export ERL_AFLAGS="-kernel shell_history enabled"
            echo "==> Environnement HashCluster prêt"
            echo "==> Elixir: $(elixir --version | head -1)"
          '';
        };
      }
    );
}
