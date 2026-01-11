# shgit

Git but a bit "shit" - personal overlay for git projects.

Store project-specific files (configs, env templates) that can't be committed to target repo but should be git-versioned in your private repo.

## Features

- `shgit clone <url>` - Clone repo as submodule into `<reponame>_shgit/repo/`
- `shgit link` - Symlink files from `link/` into repo, add to local gitignore
- `shgit worktree add <name>` - Create worktree with proper symlinks
- Config-based env file syncing between main repo and worktrees

## Structure

```
foorepo_shgit/
  link/                 # Your tracked files (mirrors repo structure)
    .vscode/settings.json
    .opencode/opencode.json
  repo/                 # Git submodule (target repo)
  .shgit/config.zon     # shgit configuration
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
