# License and first-release decisions

Status: awaiting the author's decisions. This note does not assign a license
or authorize publication.

## Evidence

At documentation baseline `44987e1c9306ef5816110784b9e8d1c34c4433af`:

- The tracked tree has no `LICENSE` or `COPYING` file, and the README, help,
  Lua sources, and tests contain no license/copyright declaration.
- Local Git history contains no license-file commits or stated license policy.
- `git tag` returns no tags. No release workflow or release policy is tracked.

This inspection covers the checkout and locally available history/refs. It
does not establish whether un-fetched remote tags or GitHub Releases exist.
Dependency licenses do not establish a license for this plugin.

## Decisions to record before distribution

1. **License:** the author selects the intended license (or explicitly chooses
   to keep rights reserved), confirms ownership/contributor permissions, and
   approves the exact license text and copyright holder/year. If licensing
   the project, add the approved `LICENSE` file and matching README/help
   statements. Review any asset attribution requirements at the same time.
2. **First release:** decide whether the current behavior is ready for a
   tagged release, choose the version and versioning policy, and record the
   supported Neovim/obsidian.nvim versions and public provider contract. A
   release note should identify the supported embed forms, fixed recursion
   limit, attachment/URI exclusions, table behavior, and refresh limitations.
3. **Release validation:** run the standalone smoke checks and available CI
   on the exact intended release revision, check help tags and demo assets,
   and record any platform/version coverage gaps. Verify remote tags/releases
   before choosing the version. The documented minimum versions are not a
   substitute for testing the intended support matrix.
4. **Publication approval:** have the author review the resulting license and
   release notes, then authorize pushing/tagging/publishing separately. No
   tags, release, push, or merge are part of this documentation task.
