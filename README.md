# migration-harness

A CLI tool that drives `goose` through a 5-step code migration pipeline:
**detect → plan → execute → verify → fix-loop**. Each step is a separate,
stateless `goose run` invocation. Migration expertise lives in the bundled
`goose-migration` skill; per-run state lives on disk.

## Architecture at a glance

```
migration-harness  (this CLI, bash)         ←  orchestration, gates, resume
    │
    ├── recipes/                            ←  typed entry points (one per step)
    │     plan.yaml, execute.yaml, verify.yaml, fix.yaml
    │
    └── ~/.config/goose/skills/goose-migration/   ←  expertise (auto-loaded)
          SKILL.md (umbrella)
          skills/migration-plan/
          skills/javaee-quarkus/
          skills/python2-to-python3/

State on disk:
  ~/.migration-harness/config            ←  model, provider, limits
  ~/.migration-harness/runs/<id>/        ←  per-run JSON artifacts + logs
  <repo>/.goosehints                     ←  in-repo guidance for each goose run
```

## Install

```bash
./install.sh
```

This:
1. Verifies `goose`, `jq`, `git` are present.
2. Copies payload to `~/.migration-harness/install/`.
3. Symlinks `~/.local/bin/migration-harness` → the command.
4. Installs the skill bundle to `~/.config/goose/skills/goose-migration/`.

Make sure `~/.local/bin` is in your `PATH`.

## First-time configuration

```bash
migration-harness init
```

Prompts for:
- Provider (anthropic / openai / google / ollama / other)
- Model name (defaults per provider)
- Max turns per goose invocation (default 200)
- Max fix-loop iterations (default 3)

Saved to `~/.migration-harness/config`.

## Run a migration

```bash
migration-harness /path/to/your/app "Migrate this Express.js app to FastAPI"
```

What happens:

| # | Step | Mechanism | Approval? |
|---|------|-----------|-----------|
| 1 | detect | pure bash (no model) | — |
| 2 | plan | `recipes/plan.yaml` + `migration-plan` sub-skill | **yes, here** |
| 3 | execute | per-item loop over `recipes/execute.yaml` | — |
| 4 | verify | `recipes/verify.yaml` | — |
| 5 | fix-loop | up to N iterations of verify + `recipes/fix.yaml` | — |

After the plan is displayed you'll be asked:
```
Approve and execute? [y/edit/N]:
```
`edit` opens the plan in `$EDITOR`. Approval cascades through the rest.

## Other commands

```bash
migration-harness status    # summarize the last run
migration-harness resume    # resume the last run (skips completed items)
migration-harness step plan /path/to/app "..."   # run one step manually
```

## Why per-step invocations

Each step is its own `goose run` process. This gives you:

- **Bounded token budget per step.** Step N doesn't inherit step 1's context.
- **Crash resilience.** If step 3 dies on item 47, only that item failed.
  Re-run with `resume`.
- **Cheaper detection.** Step 1 is pure bash — zero tokens spent on counting
  files. Only the reasoning steps invoke the model.
- **Inspectable artifacts.** Every step writes JSON to
  `~/.migration-harness/runs/<id>/`. You can diff, replay, audit.

## How skills and recipes combine

A recipe's *prompt* is short — usually a few lines. Goose loads the recipe,
fills in Jinja parameters, and starts the agent. The agent then scans
`~/.config/goose/skills/*/SKILL.md` frontmatter; when it sees one whose
`description` matches the prompt's wording (e.g. "migrate this app to Quarkus"
matches the umbrella skill's trigger list), it loads that skill's body into
context. The umbrella routes to the right execution sub-skill. That sub-skill
provides transformation rules. The recipe's `response.json_schema` constrains
the output so bash can parse it deterministically.

In short: **recipe = parameters in / JSON out. Skill = how to do the work.**

## Extending

**New migration type** (e.g. Rails 5 → 7):
1. Add `skill-bundle/goose-migration/skills/rails5-to-7/SKILL.md` with rules.
2. Add it to the umbrella skill's routing table.
3. Reinstall (`./install.sh`).
4. Recipes don't change — they're stack-agnostic.

**New step** (e.g. backup before execute):
1. Add `recipes/backup.yaml`.
2. Add `lib/step-backup.sh` and source it from `bin/migration-harness`.
3. Insert into `cmd_run` between phases.

**Slack approval gate**:
Replace the `read -rp` in `lib/step-plan.sh` with a `curl` to a Slack webhook
and a poll for an emoji reaction.

## Troubleshooting

- **Skill doesn't auto-load**: verify it's at `~/.config/goose/skills/goose-migration/SKILL.md` and that the prompt contains words matching the skill's `description` trigger phrases.
- **`Model not found`**: run `goose configure` first to set up provider credentials, then `migration-harness init` again.
- **Fix-loop hits max iterations**: read the latest `verify-N.json` and
  `fix-N.json` in `~/.migration-harness/runs/<id>/` — there's likely a
  systemic issue (missing dependency, wrong target version) that needs a
  human edit before resuming.
