# Ralph

![Ralph](ralph.webp)

Ralph is an autonomous AI agent loop that runs AI coding tools ([Amp](https://ampcode.com) or [Claude Code](https://docs.anthropic.com/en/docs/claude-code)) repeatedly until all PRD items are complete. Each iteration is a fresh instance with clean context. Memory persists via git history, `progress.txt`, and `prd.json`.

Based on [Geoffrey Huntley's Ralph pattern](https://ghuntley.com/ralph/).

[Read my in-depth article on how I use Ralph](https://x.com/ryancarson/status/2008548371712135632)

## Installation

```bash
curl -sL https://raw.githubusercontent.com/Shooa/ralph/main/install.sh | bash
```

This installs to `~/.ralph/` and creates a symlink at `~/.local/bin/ralph`. Skills are symlinked to `~/.claude/skills/`.

Make sure `~/.local/bin` is in your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"  # add to .zshrc / .bashrc
```

### Auto-update

Ralph checks for updates on every run. If a new version is available on GitHub, it downloads and re-executes automatically. Skip with `--no-update`.

### Prerequisites

- One of the following AI coding tools installed and authenticated:
  - [Amp CLI](https://ampcode.com) (default)
  - [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`npm install -g @anthropic-ai/claude-code`)
- `jq` installed (`brew install jq` on macOS)
- A git repository for your project
- (Optional) [OpenAI Codex CLI](https://github.com/openai/codex) for the review phase (`--reviewer codex`)

## Review Mode (v2)

This fork adds an optional **implement → review loop** with a separate code reviewer as gatekeeper:

```
┌──────────────────────────────────────────┐
│  for each story:                         │
│    ┌─────────────┐     ┌──────────────┐  │
│    │  Implement   │────▶│   Review     │  │
│    │ (claude/amp) │     │   (codex)    │  │
│    │  stage only  │◀────│              │  │
│    └─────────────┘     │  NEEDS_FIX?  │  │
│      fix & retry       │  ──────────  │  │
│                        │  PASS?       │  │
│                        │  → commit    │  │
│                        │  → next story│  │
│                        └──────────────┘  │
└──────────────────────────────────────────┘
```

1. **Implement** — the agent codes the story and stages files (`git add`), but does NOT commit. If `.ralph-review.json` exists from a previous round, the agent reads it and fixes the issues first.
2. **Review** — a separate reviewer (OpenAI Codex by default) reviews `git diff --cached`, verifies all acceptance criteria are met, and either:
   - **PASS** → commits the code, marks the story done, moves on
   - **NEEDS_FIX** → writes `.ralph-review.json` with issues, agent retries

The loop repeats up to `--max-rounds` times (default: 3) per story. Only the reviewer commits — the implementation agent never touches git history.

## Branch-Based Sessions

Ralph supports multiple concurrent runs in a project via branch-based session detection:

```
tasks/
├── ralph-phase1/          # auto-detected on branch ralph/phase1
│   ├── prd.json
│   ├── progress.txt
│   └── archive/
└── ralph-phase2/          # auto-detected on branch ralph/phase2
    ├── prd.json
    └── progress.txt
```

**Resolution order:**
1. `--run NAME` → `tasks/NAME/` (explicit)
2. Git branch `ralph/X` → `tasks/ralph-X/` (auto, `tr '/' '-'`)
3. Single `tasks/*/prd.json` → uses that directory (fallback)
4. Multiple or none → error with suggestions

### Managing runs

```bash
# List all runs with progress
ralph --list

# Create a new empty run
ralph --new my-feature

# Explicitly select a run
ralph --run my-feature --tool claude 10
```

## Usage

```bash
# With codex review (default)
ralph --tool claude --reviewer codex 15

# With PRD enrichment (scans codebase, adds code refs to prd.json)
ralph --tool claude --enrich --reviewer codex 15

# Custom enrichment model (default: claude-haiku-4-5-20251001)
ralph --tool claude --enrich --enrich-model claude-sonnet-4-6 15

# Custom max review rounds per story
ralph --tool claude --reviewer codex --max-rounds 5 15

# Skip review (original single-phase behavior)
ralph --tool claude --reviewer skip 15

# Amp + codex review
ralph --tool amp --reviewer codex 10
```

### All options

```
ralph [options] [max_iterations]

  --tool amp|claude          LLM agent (default: amp)
  --model MODEL              Model override
  --reviewer codex|claude|skip  Code reviewer (default: codex)
  --max-rounds N             Max review rounds per story (default: 3)
  --enrich                   Run enrichment phase
  --enrich-model MODEL       Model for enrichment
  --run NAME                 Use tasks/NAME/ explicitly
  --list                     List all runs with status
  --new NAME                 Create new empty run
  --no-update                Skip auto-update
  --version                  Show version
  --help                     Show help
```

### Review output format (`.ralph-review.json`)

```json
{
  "story_id": "US-003",
  "verdict": "NEEDS_FIX",
  "summary": "Missing error handling in parser",
  "issues": [
    {
      "severity": "critical",
      "category": "task_completion",
      "file": "src/parser.cpp",
      "line": 42,
      "description": "Acceptance criterion #3 not met: empty input not handled",
      "suggestion": "Add early return if input.empty()"
    }
  ]
}
```

## Workflow

### 1. Create a PRD

Use the PRD skill to generate a detailed requirements document:

```
Load the prd skill and create a PRD for [your feature description]
```

Answer the clarifying questions. The skill saves output to `tasks/prd-[feature-name].md`.

### 2. Convert PRD to Ralph format

Use the Ralph skill to convert the markdown PRD to JSON:

```
Load the ralph skill and convert tasks/prd-[feature-name].md to prd.json
```

This creates `prd.json` with user stories structured for autonomous execution.

### 3. Run Ralph

```bash
# Create a run (if you haven't already)
ralph --new my-feature

# Copy/move prd.json to the run directory
cp tasks/prd.json tasks/my-feature/prd.json

# Run!
ralph --run my-feature --tool claude --reviewer codex 15
```

Or with branch-based detection:

```bash
git checkout -b ralph/my-feature
# prd.json is at tasks/ralph-my-feature/prd.json
ralph --tool claude --reviewer codex 15
```

## Key Files

| File | Purpose |
|------|---------|
| `ralph.sh` | The bash loop (supports `--tool`, `--model`, `--reviewer`, `--enrich`, `--run`, `--list`) |
| `prompt.md` | Prompt template for Amp (single-phase) |
| `CLAUDE.md` | Implementation agent prompt — implement & stage, or fix review issues & re-stage |
| `review-prompt.md` | Reviewer prompt — review, commit on PASS, or write `.ralph-review.json` on NEEDS_FIX |
| `enrich-prompt.md` | Enrichment agent prompt — scans codebase, adds code references to prd.json |
| `install.sh` | Installer script (`curl \| bash`) |
| `prd.json.example` | Example PRD format for reference |
| `skills/prd/` | Skill for generating PRDs (works with Amp and Claude Code) |
| `skills/ralph/` | Skill for converting PRDs to JSON (works with Amp and Claude Code) |
| `.claude-plugin/` | Plugin manifest for Claude Code marketplace discovery |
| `flowchart/` | Interactive visualization of how Ralph works |

## Flowchart

[![Ralph Flowchart](ralph-flowchart.png)](https://snarktank.github.io/ralph/)

**[View Interactive Flowchart](https://snarktank.github.io/ralph/)** - Click through to see each step with animations.

## Critical Concepts

### Each Iteration = Fresh Context

Each iteration spawns a **new AI instance** (Amp or Claude Code) with clean context. The only memory between iterations is:
- Git history (commits from previous iterations)
- `progress.txt` (learnings and context)
- `prd.json` (which stories are done)

### Small Tasks

Each PRD item should be small enough to complete in one context window. If a task is too big, the LLM runs out of context before finishing and produces poor code.

### TDD (Test-Driven Development)

All stories are structured for strict TDD:
1. **RED** — Write failing tests first (acceptance criteria start with `RED:`)
2. **GREEN** — Implement minimum code to pass (criteria labeled `GREEN:`)
3. **REFACTOR** — Clean up if needed

### PRD Enrichment (`--enrich`)

The `--enrich` flag runs a cheap sub-agent (Haiku by default) before the main loop to scan the codebase and populate code references in `prd.json`.

### Graceful Stop

```bash
touch .ralph-stop
```

Ralph will finish the current story and exit cleanly.

### Stop Condition

When all stories have `passes: true`, Ralph outputs `<promise>COMPLETE</promise>` and the loop exits.

## Debugging

```bash
# See which stories are done
jq '.userStories[] | {id, title, passes}' tasks/my-run/prd.json

# See learnings from previous iterations
cat tasks/my-run/progress.txt

# List all runs
ralph --list

# Check git history
git log --oneline -10
```

## References

- [Geoffrey Huntley's Ralph article](https://ghuntley.com/ralph/)
- [Amp documentation](https://ampcode.com/manual)
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
