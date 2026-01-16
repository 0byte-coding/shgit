# shgit - Git-based Project Overlay Manager

**shgit** version-controls project config files (`.env`, etc.) separately from target repos via git overlays.

## Commands

- **`shgit clone <url>`** - Clone shgit repo + setup
- **`shgit worktree add -b feat/branch wt-branch`** - Create a worktree branch (also links stuff from `link/`)
- **`shgit link`** - Link files from `link/` to `repo/*` folders
- **`shgit worktree list`** - Show all worktrees
- **`shgit worktree remove <name>`** - Delete worktree
