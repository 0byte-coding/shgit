# shgit - Git-based Project Overlay Manager

**shgit** version-controls project config files (`.env`, etc.) separately from target repos via git overlays.

## Commands

- **`shgit clone <url>`** - Clone shgit repo + setup
- **`shgit worktree add <url>`** - Add target project as worktree
- **`shgit link`** - Link files from `link/` to `repo/*` folders
- **`shgit worktree list`** - Show all worktrees
- **`shgit worktree remove <name>`** - Delete worktree

## Workflow

1. `shgit clone <git-repo-url>`
2. Adjust files when needed in `link/`
3. `shgit worktree add <target-repo-url>`
