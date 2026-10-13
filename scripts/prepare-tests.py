#!/usr/bin/env python3
"""Prepare a standalone test runtime on Linux/macOS using Python, curl and tar."""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys


# Keep the minimum Obsidian and Plenary revisions in sync with flake.nix.
OBSIDIAN_MINIMUM = "1212014bb22a1f44a655e8e706659892b8e43e59"  # v3.16.8
PLENARY = "74b06c6c75e4eeb3108ec01852001636d85a932b"


def run(*args):
    subprocess.run(args, check=True)


def download(url, destination):
    run("curl", "-L", "--fail", "--silent", "--show-error", "--retry", "3",
        "--connect-timeout", "15", "--max-time", "120", url, "-o", str(destination))
    return hashlib.sha256(destination.read_bytes()).hexdigest()


def api(path, destination):
    download("https://api.github.com/repos/" + path, destination)
    return json.loads(destination.read_text())


def extract(archive, destination):
    destination.mkdir()
    run("tar", "-xzf", str(archive), "--strip-components=1", "-C", str(destination))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="new directory outside the checkout")
    parser.add_argument("--neovim", default="stable", help="stable or a release tag, e.g. v0.11.0")
    parser.add_argument("--obsidian", default="minimum", help="minimum, stable, or a commit/tag")
    args = parser.parse_args()
    dest = args.destination.resolve()
    system = {"Linux": "linux", "Darwin": "macos"}.get(platform.system())
    machine = {"x86_64": "x86_64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine())
    if not system or not machine:
        parser.error("only Linux/macOS on x86_64/arm64 are supported")

    # Cleanup belongs only to the directory this invocation successfully created.
    dest.mkdir(parents=True, exist_ok=False)
    try:
        manifest = {"sources": {}}
        release_path = "latest" if args.neovim == "stable" else "tags/" + args.neovim
        release = api("neovim/neovim/releases/" + release_path, dest / "neovim-release.json")
        asset_name = f"nvim-{system}-{machine}.tar.gz"
        asset = next(a for a in release["assets"] if a["name"] == asset_name)
        archive = dest / asset_name
        digest = download(asset["browser_download_url"], archive)
        expected = asset.get("digest")
        if expected:
            expected = expected.removeprefix("sha256:")
        else:
            sums = next(a for a in release["assets"] if a["name"] == "shasum.txt")
            download(sums["browser_download_url"], dest / "shasum.txt")
            expected = next(line.split()[0] for line in (dest / "shasum.txt").read_text().splitlines()
                            if line.split()[-1].lstrip("*./") == asset_name)
        if digest != expected:
            raise RuntimeError("Neovim archive SHA256 mismatch")
        extract(archive, dest / "neovim")
        manifest["neovim"] = {"tag": release["tag_name"], "asset": asset_name, "sha256": digest}

        obsidian_ref = OBSIDIAN_MINIMUM if args.obsidian == "minimum" else args.obsidian
        if obsidian_ref == "stable":
            obsidian_release = api("obsidian-nvim/obsidian.nvim/releases/latest", dest / "obsidian-release.json")
            obsidian_ref = obsidian_release["tag_name"]
        if obsidian_ref != OBSIDIAN_MINIMUM:
            obsidian_ref = api("obsidian-nvim/obsidian.nvim/commits/" + obsidian_ref,
                               dest / "obsidian-commit.json")["sha"]
        for name, repository, revision in (
            ("obsidian.nvim", "obsidian-nvim/obsidian.nvim", obsidian_ref),
            ("plenary.nvim", "nvim-lua/plenary.nvim", PLENARY),
        ):
            archive = dest / (name + ".tar.gz")
            digest = download(f"https://codeload.github.com/{repository}/tar.gz/{revision}", archive)
            extract(archive, dest / name)
            manifest["sources"][name] = {"repository": repository, "commit": revision, "sha256": digest}

        # Parsers and matching queries are bundled in the verified Neovim archive.
        env = {"NVIM_BIN": str(dest / "neovim/bin/nvim"),
               "OBSIDIAN_EMBEDS_RTP": ":".join(str(dest / p) for p in ("obsidian.nvim", "plenary.nvim"))}
        (dest / "env.sh").write_text("".join(f"export {key}={shlex.quote(value)}\n" for key, value in env.items()))
        (dest / "versions.json").write_text(json.dumps(manifest, indent=2) + "\n")
    except BaseException:
        try:
            shutil.rmtree(dest)
        except OSError as cleanup_error:
            print(f"Could not remove failed preparation directory {dest}: {cleanup_error}", file=sys.stderr)
        raise

    print(json.dumps(manifest, indent=2), flush=True)
    print(f"Run: . {shlex.quote(str(dest / 'env.sh'))} && ./scripts/test.sh", flush=True)


if __name__ == "__main__":
    main()
