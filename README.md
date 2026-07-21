# shgit

Git but a bit "shit" - personal overlay for git projects.

Store project-specific files (configs, env templates) that can't be committed to target repo but should be git-versioned in your private repo.

## Features

- `shgit clone <url>` - Clone repo as submodule into `<reponame>_shgit/repo/`
- `shgit link` - Symlink files from `link/` into repo, add to local gitignore
- `shgit unlink [path]` - Revert the overlay (all, or a single path)
- `shgit worktree add <name>` - Create worktree with proper symlinks
- Config-based env file syncing between main repo and worktrees
- `remove_patterns` - Delete unwanted files from the target repo, hidden from git

## Shadowing & removing existing files

`shgit link` overlays your `link/` files onto the target repo even when a file
of the same name already exists there. If the existing file is **tracked** by
the target repo, shgit marks it `git update-index --skip-worktree` before
swapping it, so the overlay never shows up in `git status`. Untracked files are
added to `.git/info/exclude` instead.

Use `remove_patterns` in the config to declare files that exist in the target
repo but you don't want. On `shgit link` they are deleted from the repo (and
every worktree); tracked matches are additionally `--skip-worktree`'d so the
deletion stays invisible to git.

Both `remove_patterns` and `sync_patterns` use the same gitignore-style glob
matcher (`*`, `**`, `?`, `[abc]`, a leading `/` to anchor to the repo root, and
a trailing `/` for directory patterns).

```json
{
  "main_repo": "foorepo",
  "sync_patterns": [{ "pattern": ".env", "mode": "symlink" }],
  "remove_patterns": ["**/*.log", ".vscode/", "docs/legacy.md"]
}
```

### Reverting: `shgit unlink`

`shgit unlink` undoes everything `shgit link` did, across the main repo and every
worktree:

- removes the symlinks that mirror `link/`,
- restores any **tracked** file that was shadowed (clears `--skip-worktree` and
  checks the original back out),
- undeletes files removed by `remove_patterns` (restores tracked files to their
  committed contents),
- cleans the entries shgit added to `.git/info/exclude`.

Pass a path (`shgit unlink path/to/file`) to revert just that one file instead of
the whole overlay. Note: untracked overlay files are simply removed (there is no
committed version to restore).

## Structure

```
foorepo_shgit/
  link/                 # Your tracked files (mirrors repo structure)
    .vscode/settings.json
    .opencode/opencode.json
  repo/                 # Git submodule (target repo)
  .shgit/config.json    # shgit configuration
  .gitignore
  .gitmodules
```

## Usage

```sh
shgit clone https://github.com/user/foorepo.git
cd foorepo_shgit
mkdir -p link/.vscode
echo '{}' > link/.vscode/settings.json
shgit link
```
## Installation

### Distributions

Currently available on the arch linux aur

```sh
yay -S shgit-bin
```

### Nix / NixOS

A flake is provided. Run it directly:

```sh
nix run github:0byte-coding/shgit -- --help
```

Or add it to your flake inputs:

```nix
inputs.shgit.url = "github:0byte-coding/shgit";
```

then reference `inputs.shgit.packages.${system}.default` in `environment.systemPackages`,
or use `inputs.shgit.overlays.default` and reference `pkgs.shgit`.

A `devShells.default` (zig + zls) is also available via `nix develop`.

### Manual user only install

Ensure `~/.local/bin` is in your `PATH` before proceeding

```bash
tmp=$(mktemp -d) && \
  curl -L https://github.com/0byte-coding/shgit/releases/latest/download/shgit-x86_64-linux-gnu.tar.gz | tar -xz -C "$tmp" --overwrite && \
  mkdir -p ~/.local/bin && \
  mv "$tmp/shgit" ~/.local/bin/ && \
  chmod +x ~/.local/bin/shgit && \
  rm -rf "$tmp"
```
