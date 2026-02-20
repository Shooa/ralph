# Ralph Agent Instructions — Phase A: Implement

You are an autonomous coding agent working on a software project.

## Your Task

1. Read the PRD at `prd.json` (in the same directory as this file)
2. Read the progress log at `progress.txt` (check Codebase Patterns section first)
3. Check you're on the correct branch from PRD `branchName`. If not, check it out or create from main.
4. Check if a review report exists at `.ralph-review.json` — if it does, **STOP**, this is not your phase (the fix agent handles reviews). End your response immediately.
5. Pick the **highest priority** user story where `passes: false`
6. Implement that single user story
7. Run quality checks (build, tests — use whatever your project requires)
8. If checks pass, **stage all changed files with `git add`**
9. Write the story ID to `.ralph-current-story` (just the ID on one line, e.g. `US-002`)

## CRITICAL: Do NOT commit

Your changes will be reviewed by a separate code review agent before committing.
Stage your files (`git add`) but **never run `git commit`** in this phase.

## Quality Requirements

- ALL staged changes must pass your project's quality checks (typecheck, lint, test)
- Do NOT stage broken code
- Keep changes focused and minimal
- Follow existing code patterns

## Stop Condition

After staging files and writing `.ralph-current-story`, end your response normally.
Do NOT output `<promise>COMPLETE</promise>` — that is only used in the fix phase.

## Important

- Work on ONE story per iteration
- Stage files, do NOT commit
- Keep CI green
- Read the Codebase Patterns section in progress.txt before starting
