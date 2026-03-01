# PATH Optimizer (Windows)

PowerShell CLI to audit, plan, and safely apply PATH optimizations across `User` and `Machine` scopes.

## Features

- Analyze current PATH usage, duplicates, stale entries, and command collisions.
- Build deterministic optimization plans with:
  - duplicate removal
  - missing-entry quarantine
  - shared-path consolidation to `Machine`
- Apply plans with pre-change snapshots and rollback support.
- Build manifest-driven shim launchers in `C:\\Tools\\bin`.

## Commands

```powershell
./pathopt.ps1 analyze [--json] [--out <file>]
./pathopt.ps1 plan [--json] [--out <file>] [--scope user|machine|both]
./pathopt.ps1 apply --plan <file> [--backup-dir <dir>] [--whatif]
./pathopt.ps1 rollback --snapshot <file> [--whatif]
./pathopt.ps1 add <path> [--scope user|machine] [--position prepend|append] [--force] [--whatif]
./pathopt.ps1 refresh [--scope path|all|<name>] [--whatif]
./pathopt.ps1 shim sync [--manifest <file> | --name <shim> --target <path> [--launcher-type cmd|cmd+ps1]] [--bin-dir <dir>] [--whatif]
./pathopt.ps1 doctor [--json] [--out <file>]
```

## Refresh Current Process Environment

Use `refresh` to update the current PowerShell process from the latest User and Machine environment values without restarting the terminal.

```powershell
# Refresh process PATH from Machine + User PATH values
./pathopt.ps1 refresh

# Refresh all process variables from User/Machine values
./pathopt.ps1 refresh --scope all

# Refresh one variable (User wins over Machine on conflicts)
./pathopt.ps1 refresh --scope JAVA_HOME

# Preview only
./pathopt.ps1 refresh --scope all --whatif
```

## Adding Paths

Add a new directory to PATH with automatic length validation:

```powershell
# Add to User PATH (default, appends to end)
./pathopt.ps1 add "C:\Tools\bin"

# Add to Machine PATH (requires elevation)
./pathopt.ps1 add "C:\Tools\bin" --scope machine

# Prepend to beginning of PATH (higher priority)
./pathopt.ps1 add "C:\MyApp\bin" --position prepend

# Dry-run to preview changes
./pathopt.ps1 add "C:\NewTool" --whatif
```

**Path Length Warnings:**

| Level    | Scope Limit | Combined Limit | Behavior |
|----------|-------------|----------------|----------|
| Warning  | 2048 chars  | 8192 chars     | Warns but proceeds |
| Critical | 4096 chars  | 32767 chars    | Blocks unless `--force` used |

The command also detects duplicate paths and skips them automatically.

## Workflow

1. Run analysis:

```powershell
./pathopt.ps1 analyze --out .pathopt/analyze.json --json
```

2. Generate plan:

```powershell
./pathopt.ps1 plan --scope both --out .pathopt/plans/plan.json --json
```

3. Review plan JSON. Then dry-run apply:

```powershell
./pathopt.ps1 apply --plan .pathopt/plans/plan.json --whatif
```

4. Apply for real (run elevated if machine PATH changes):

```powershell
./pathopt.ps1 apply --plan .pathopt/plans/plan.json
```

5. If needed, rollback:

```powershell
./pathopt.ps1 rollback --snapshot .pathopt/backups/path-snapshot-YYYYMMDD-HHMMSS.json
```

## Shim Manifest

See `examples/shim-manifest.sample.json`.

```powershell
./pathopt.ps1 shim sync --manifest examples/shim-manifest.sample.json --bin-dir C:\\Tools\\bin

# Or create a single shim without authoring a manifest first
./pathopt.ps1 shim sync --name gitdocgen --target C:\dev\docs-from-commits\tools\generate-change-summaries.ps1
```

When `--manifest` is omitted, the CLI auto-generates one at `.pathopt/manifests/`.
`--bin-dir` defaults to `C:\\Tools\\bin`.

## Tests

```powershell
Invoke-Pester -Path ./tests
```

## Notes

- Writes use .NET environment APIs, not `setx`.
- Machine PATH updates require elevation.
- Open new shells after apply or rollback.
- `refresh` updates the current process only; it does not write registry values.
