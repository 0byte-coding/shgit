# shgit - Git-based Project Overlay Manager

**shgit** manages project-specific configuration files (like `.env`, `.env.local`) that can't be committed to a target repository but should be version-controlled separately.

## Core Concepts

- **shgit project**: A git repository containing overlays for multiple target projects
- **Overlay structure**: Each target project gets its own subdirectory in the shgit repo
- **`link/` directory**: Contains files that will be symlinked into the target project's working directory
- **Worktrees**: Target projects are added as git worktrees, enabling multi-project management from one shgit repo

## Commands

### Initialize a new shgit project
```bash
shgit init <repo-name>
```
Creates `.shgit/config.zon` with the main repo name and default sync patterns.

### Clone an existing shgit project
```bash
shgit clone <shgit-repo-url> [target-dir]
```
Clones the shgit repository and sets it up for managing project overlays.

### Add a target project as a worktree
```bash
shgit worktree add <project-repo-url> [branch]
```
- Adds the target project as a git submodule under `repos/<repo-name>/`
- Creates a worktree at `worktrees/<repo-name>/`
- Initializes overlay structure with `link/` directory
- Branch defaults to `main` if not specified

### Link overlay files to target project
```bash
shgit link <overlay-dir>
```
Creates relative symlinks from files in `<overlay-dir>/link/` to the corresponding worktree. Files are automatically added to the worktree's local git exclude list.

### Sync files from target to overlay
```bash
shgit sync <worktree-path>
```
Copies files matching sync patterns (from config) from the target worktree into the overlay's `link/` directory for version control.

### List worktrees
```bash
shgit worktree list
```
Shows all managed worktrees with their paths and branches.

### Remove a worktree
```bash
shgit worktree remove <worktree-name>
```
Removes the worktree (leaves the overlay files intact in the shgit repo).

## Typical Workflow

1. **Setup**: `shgit clone git@github.com:user/my-shgit-repo.git`
2. **Add project**: `shgit worktree add git@github.com:user/target-project.git`
3. **Edit configs**: Create/edit files in `overlays/<project>/link/.env`
4. **Link files**: `shgit link overlays/<project>`
5. **Commit overlays**: `git add . && git commit -m "Add project configs"`
6. **Sync changes**: `shgit sync worktrees/<project>` (when files change in target)

## Structure Example
```
my-shgit-project/
├── .shgit/
│   └── config.zon
├── repos/
│   └── target-project/        # Submodule
├── worktrees/
│   └── target-project/        # Working directory with .env symlinked
└── overlays/
    └── target-project/
        └── link/
            ├── .env           # Version-controlled config
            └── .env.local
```
