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
                export HOME="$TMPDIR/home"
                export XDG_CONFIG_HOME="$HOME/.config"
                export XDG_DATA_HOME="$TMPDIR/data"
                export XDG_STATE_HOME="$TMPDIR/state"
                mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME"

                if rg -n 'resolve_note_async|Note\.from_file|obsidian\.note"\)\.from_file|obsidian_embeds\.tracker|set_workspace_root|obsidian\.workspace"\)\.set' \
                  "${self}/lua/obsidian-embed" --glob '*.lua'; then
                  echo "forbidden synchronous resolver boundary found" >&2
                  exit 1
                fi

                if rg -n 'command\.type|command\(out' \
                  "${self}/lua/obsidian-embed/runtime.lua" \
                  "${self}/lua/obsidian-embed/machine.lua"; then
                  echo "removed command protocol regressed" >&2
                  exit 1
                fi

                if rg -n 'session\.[A-Za-z_][A-Za-z0-9_]*\s*=[^=]' \
                  "${self}/lua/obsidian-embed/runtime.lua"; then
                  echo "runtime mutated semantic state owned by the machine" >&2
                  exit 1
                fi

                export OBSIDIAN_EMBEDS_RTP="${obsidian-nvim}:${plenary-nvim}:${treesitter}"
                nvim --headless -l ${self}/tests/obsidian-embeds-machine-smoke.lua
                nvim --headless -l ${self}/tests/obsidian-embeds-resolver-smoke.lua
                nvim --headless -l ${self}/tests/obsidian-embeds-state-smoke.lua
                nvim --headless -l ${self}/tests/obsidian-embeds-context-smoke.lua
                nvim --headless -l ${self}/tests/obsidian-embeds-command-contract-smoke.lua
                nvim --headless -l ${self}/tests/obsidian-embeds-smoke.lua
                nvim --headless -l ${self}/tests/obsidian-embeds-dependencies-smoke.lua
                nvim --headless -l ${self}/tests/obsidian-embeds-workspace-smoke.lua
                nvim --headless -l ${self}/tests/obsidian-embeds-performance-smoke.lua

                touch "$out"
              '';
        }
      );
    };
}
