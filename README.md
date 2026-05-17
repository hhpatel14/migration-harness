# migration-harness

**AI-powered code migration tool** that orchestrates `goose` through a 5-step pipeline: **detect → plan → execute → verify → fix-loop**.

Supports Java EE → Quarkus, .NET upgrades, Python 2 → 3, and more.

---

## Quick Start

```bash
# Install
./install.sh

# Configure (one-time setup)
migration-harness init

# Run migration
migration-harness /path/to/your/app "Migrate this Java EE app to Quarkus 3"
```

---

## How It Works

```
┌─────────────┐
│ 1. Detect   │  Analyze project structure (AST graph, dependencies)
└─────────────┘
      ↓
┌─────────────┐
│ 2. Plan     │  Generate migration plan → PLAN.md (requires approval)
└─────────────┘
      ↓
┌─────────────┐
│ 3. Execute  │  Apply changes step-by-step
└─────────────┘
      ↓
┌─────────────┐
│ 4. Verify   │  Build + test (auto-fixes compilation errors)
└─────────────┘
      ↓
┌─────────────┐
│ 5. Fix-loop │  Additional fixes if needed (conditional)
└─────────────┘
```

**Key features:**
- **Zero-token detection** — Uses AST analysis (graphify), not LLM
- **Human approval gate** — Review and edit PLAN.md before execution
- **Auto-fix on verify** — Fixes compilation errors automatically (up to 3 attempts)
- **Interactive resumption** — Complex migrations can continue with more turns
- **Resume support** — Crash? Just run `migration-harness resume`

---

## Installation

### Prerequisites

- [goose](https://github.com/square/goose) (configured with API keys)
- `jq` (JSON processor)
- `git`
- Python 3.8+ with `graphifyy` (`pip install graphifyy`)

### Install

```bash
git clone <this-repo>
cd migration-harness
./install.sh
```

This will:
1. Install CLI to `~/.local/bin/migration-harness`
2. Install skill bundle to `~/.config/goose/skills/goose-migration/`
3. Verify dependencies

Make sure `~/.local/bin` is in your `PATH`.

### First-Time Configuration

```bash
migration-harness init
```

Detects your goose provider/model from `~/.config/goose/config.yaml` and saves config to `~/.migration-harness/config`.

---

## Usage

### Basic Migration

```bash
migration-harness /path/to/project "Migration request description"
```

**Examples:**
```bash
# Java EE to Quarkus
migration-harness ~/apps/legacy-javaee "Migrate to Quarkus 3"

# .NET upgrade
migration-harness ~/apps/dotnet-app "Upgrade from .NET Core 3.1 to .NET 8"

# Python 2 to 3
migration-harness ~/apps/legacy-python "Migrate from Python 2 to Python 3"
```

### Other Commands

```bash
# Show last migration status
migration-harness status

# Resume incomplete migration
migration-harness resume

# Run single step (advanced)
migration-harness step verify /path/to/project
migration-harness step execute /path/to/project
```

---

## Output Artifacts

After a migration run, you'll find:

**In your project directory:**
- `PLAN.md` — Human-readable migration plan
- `execution-log.md` — Step-by-step execution progress
- `verification-report.md` — Build/test results
- `fix-loop-report.md` — Fix iteration history (if applicable)

**In `~/.migration-harness/runs/<timestamp>/`:**
- `graph.json` — Code dependency graph
- `plan.json` — Structured plan
- `logs/*.json` — Detailed goose session logs

---

## Interactive Verification

For complex migrations, the verify step may need more turns:

```
ℹ   running goose session (turns: 50 / 140)...
⚠   session incomplete (used 50 turns so far)
Continue with more turns? [Y/n]: y

How many more turns to add? [default: 30, max: 90]: 40

ℹ   running goose session (turns: 90 / 140)...
✓   session completed successfully
```

This preserves all context and lets you control token spend.

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `verify produced no output` | Verification hit turn limit. Re-run — it will prompt to continue with more turns. |
| `Skill doesn't auto-load` | Verify `~/.config/goose/skills/goose-migration/SKILL.md` exists. Re-run `./install.sh`. |
| `Model not found` | Run `goose configure`, then `migration-harness init`. |
| Migration incomplete | Run `migration-harness resume` to continue from where it left off. |
| Graphify fails | Install: `pip install graphifyy`. Requires Python 3.8+. |

---

## Supported Migration Types

Currently bundled:
- **Java EE → Quarkus** (`javaee-quarkus`)
- **.NET upgrades** (`dotnet-upgrade`)
- **Python 2 → 3** (`python2-to-python3`)

### Adding New Migration Types

1. Create reference doc: `skill-bundle/goose-migration/references/your-migration.md`
2. Create execution skill: `skill-bundle/goose-migration/skills/your-migration/SKILL.md`
3. Update routing in `skill-bundle/goose-migration/SKILL.md`
4. Re-run `./install.sh`

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

---

## Architecture

For implementation details, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Quick overview:
- **Step 1 (Detect)**: Python-based AST analysis (zero LLM tokens)
- **Step 2 (Plan)**: Dynamically rendered goose recipe, loads migration references
- **Step 3 (Execute)**: Per-item execution, tracks lessons learned
- **Step 4 (Verify)**: Auto-fix compilation errors, interactive resumption
- **Step 5 (Fix-loop)**: Additional fixes if verify failed (conditional)

Each step is a separate goose invocation (except verify which supports session resumption).

---

## Development

**Running local changes:**

```bash
# Use local version (not installed)
bin/migration-harness <args>

# Or install local changes
./install.sh
```

**File structure:**
```
migration-harness/
├── bin/migration-harness          # Main CLI
├── lib/                            # Step implementations (bash)
│   ├── step-detect.sh
│   ├── step-plan.sh
│   ├── step-execute.sh
│   ├── step-verify.sh
│   ├── step-fix-loop.sh
│   └── common.sh                   # Shared goose_run() helpers
├── recipes/                        # Goose recipe files (YAML)
│   ├── execute.yaml
│   ├── verify.yaml
│   └── fix.yaml
├── skill-bundle/goose-migration/   # Migration expertise
│   ├── SKILL.md                    # Umbrella skill
│   ├── skills/                     # Execution skills
│   └── references/                 # Migration patterns
└── docs/
    └── ARCHITECTURE.md             # Implementation deep dive
```

---

## License

MIT
