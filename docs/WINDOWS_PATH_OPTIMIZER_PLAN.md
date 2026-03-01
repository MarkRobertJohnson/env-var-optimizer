# Windows PATH Optimizer (PowerShell) Plan

## Summary
Build a PowerShell CLI that audits, optimizes, and safely rewrites Windows `PATH` for both `User` and `Machine` scopes, then keeps PATH short using a single shim directory (`C:\Tools\bin`).

This plan is grounded in current machine state:
1. `User PATH`: 3370 chars / 74 entries.
2. `Machine PATH`: 2919 chars / 67 entries.
3. Combined raw entries: 141, but only ~74 normalized distinct entries.
4. Estimated immediate savings from canonical dedupe: ~3019 chars.
5. Cross-scope overlap is very high (64 distinct entries shared).
6. Current shell account differs from many PATH-owned paths (`fleetcor\majohnson` runtime with many `TEMP.NVOICEPAY` paths), so stale-account detection is required.

Chosen defaults (locked):
1. Stack: PowerShell CLI.
2. Apply mode: dry-run first, explicit apply.
3. Long-term strategy: shim bin directory.
4. Scope policy: shared paths -> `Machine`, user-only -> `User`.
5. Missing paths: remove from PATH with quarantine log.
6. Shim type: wrapper scripts + `.cmd` launchers.

## Public Interfaces and Types

### CLI commands
1. `pathopt analyze [--json] [--out <file>]`
2. `pathopt plan [--json] [--out <file>] [--scope user|machine|both]`
3. `pathopt apply --plan <file> [--backup-dir <dir>] [--whatif]`
4. `pathopt rollback --snapshot <file>`
5. `pathopt shim sync [--manifest <file>] [--bin-dir <dir>]`
6. `pathopt shim install [--manifest <file>] [--state <file>] [--bin-dir <dir>] [--whatif]`
7. `pathopt doctor` (checks PATH health + stale account + command collisions)

### Plan/manifest schema (JSON)
1. `version`
2. `generatedAt`
3. `source`: user/machine/process metadata
4. `entries`: array of objects with:
- `original`
- `normalized`
- `scope`
- `exists`
- `kind` (`directory|file|unknown`)
- `status` (`keep|remove_duplicate|remove_missing|move_scope|replace_with_shim`)
- `reason`
5. `proposedUserPath`
6. `proposedMachinePath`
7. `quarantine`: removed entries + reason + timestamp
8. `snapshots`: registry export/reference used for rollback
9. `shims`: requested shim specs (`name`, `target`, `launcherType`)

### Internal module boundaries
1. `PathSource.psm1`: read/write user+machine PATH and process PATH.
2. `PathNormalize.psm1`: trim, slash normalization, case-insensitive canonicalization, env-var expansion handling.
3. `PathClassify.psm1`: exists/missing, account mismatch hints, scope classification.
4. `PathPlan.psm1`: dedupe, ordering, scope consolidation, quarantine decisions.
5. `ShimBuilder.psm1`: generate `.cmd` + optional `.ps1` wrappers in `C:\Tools\bin`.
6. `PathApply.psm1`: transactional apply, backups, rollback.
7. `Cli.ps1`: command routing and output.

## Implementation Plan

### Phase 1: Bootstrap
1. Initialize project layout for script modules, tests, sample manifests, and docs.
2. Add strict PowerShell settings (`Set-StrictMode`, `$ErrorActionPreference='Stop'`).
3. Add a single entry script (`pathopt.ps1`) with subcommand parsing.

### Phase 2: Read + normalize + diagnostics
1. Read PATH from `HKCU\Environment` and `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment`.
2. Parse entries preserving original order and source scope.
3. Normalize entries for comparison:
- trim whitespace
- normalize slash direction and trailing slash
- case-insensitive canonical key
- optional full path resolution when safe
4. Compute diagnostics:
- duplicates (intra-scope and cross-scope)
- missing/nonexistent directories
- empty entries
- likely stale-account entries
- command collision risk (same executable name from multiple entries)

### Phase 3: Planning engine
1. Build deterministic rule pipeline:
- remove exact/normalized duplicates
- remove missing entries to quarantine set
- apply scope policy (`shared -> machine`, `user-only -> user`)
- preserve precedence for known toolchains (Git, Node, Python, Java, dotnet, package managers)
2. Produce immutable plan artifact (`plan.json`) with before/after lengths and delta.
3. Add confidence checks:
- no empty PATH
- required system paths remain present
- no accidental removal of current shell executable path

### Phase 4: Safe apply + rollback
1. On apply:
- create timestamped snapshot of user/machine PATH values
- write updated values with .NET APIs (avoid `setx` truncation behavior)
- emit “new sessions required” notice
2. On rollback:
- restore both scopes from snapshot artifact
3. Keep quarantine entries separately recoverable.

### Phase 5: Shim-bin system (`C:\Tools\bin`)
1. Create manifest-driven wrappers:
- `.cmd` launchers for discovered executables
- optional paired `.ps1` wrappers when needed
2. Keep global PATH addition to one short stable entry (`C:\Tools\bin`).
3. Add `shim sync` to refresh wrappers when tools move/version.
4. Collision policy:
- detect duplicate command names
- prefer explicit priority list
- emit conflict report and require explicit mapping in manifest for ties.

### Phase 6: Reporting + UX
1. Human-readable summary table:
- current length vs proposed length per scope
- duplicates removed
- missing entries quarantined
- entries moved between scopes
2. JSON output for automation.
3. `doctor` command to validate final state and check that target commands resolve correctly.

## Hard Links vs Symlinks vs Wrappers (explicit recommendation)
1. Hard links are not suitable as primary strategy:
- file-only
- same-volume only
- not usable for directory PATH entries
2. Symlinks/junctions are secondary options:
- useful in specific cases
- can require privileges and add fragility
3. Wrapper shims are primary:
- widest compatibility
- no symlink privilege requirement
- stable indirection layer for long paths.

## Test Cases and Scenarios

### Unit-level tests (Pester)
1. Normalize path equivalence:
- case differences
- trailing slash differences
- mixed slash styles
2. Dedupe behavior:
- same scope duplicates
- cross-scope duplicates
3. Scope allocation:
- shared entries to machine
- user-only preserved in user
4. Missing entry handling:
- moved to quarantine list
- not in proposed PATH
5. Plan determinism:
- same input produces identical plan output hash/order.

### Integration tests
1. Analyze on real registry values without mutation.
2. Apply with `--whatif` emits write intent only.
3. Apply then verify registry values changed as planned.
4. Rollback restores exact prior values.
5. Shim sync creates launchers and resolves target executables.
6. Collision detection emits actionable conflict list.

### Acceptance criteria
1. Combined normalized PATH length reduced by at least 40% on current machine baseline.
2. No required system/toolchain commands regress (`where git`, `where node`, `where python`, `where pwsh`).
3. Rollback works in one command.
4. Plan file fully explains every removed/moved entry.

## Assumptions and Defaults
1. Target OS is Windows only.
2. Writes to machine PATH may require elevated shell; command should fail fast with clear message if not elevated.
3. Existing sessions do not auto-refresh environment; users must open new shell/process after apply.
4. `setx` is not used for writes to avoid truncation/encoding pitfalls.
5. Empty workspace means the implementation starts greenfield in this repo.
