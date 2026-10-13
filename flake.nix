{
  description = "Obsidian embed checks";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-26.05";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          obsidian-nvim = pkgs.fetchFromGitHub {
            owner = "obsidian-nvim";
            repo = "obsidian.nvim";
            rev = "1212014bb22a1f44a655e8e706659892b8e43e59"; # v3.16.8
            hash = "sha256-VQBopv4Lwjie5KyGD/n16V5fKmfn/PPRNBhoQ9E8/vI=";
          };
          plenary-nvim = pkgs.fetchFromGitHub {
            owner = "nvim-lua";
            repo = "plenary.nvim";
            rev = "74b06c6c75e4eeb3108ec01852001636d85a932b";
            hash = "sha256-nkfETDkPiE+Kd2BWYZijgUp9bP8RgFwRmvqJz2BMuq4=";
          };
          treesitter = pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [
            p.markdown
            p.markdown_inline
          ]);
        in
        {
          obsidian-embeds =
            pkgs.runCommand "obsidian-embeds-smoke"
              {
                nativeBuildInputs = [
                  pkgs.neovim
                  pkgs.ripgrep
                ];
                OBSIDIAN_EMBEDS_RTP = nixpkgs.lib.concatStringsSep ":" [
                  "${obsidian-nvim}"
                  "${plenary-nvim}"
                  "${treesitter}"
                ];
              }
              ''
                ${pkgs.bash}/bin/bash ${self}/scripts/test.sh

                touch "$out"
              '';
        }
      );
    };
}
