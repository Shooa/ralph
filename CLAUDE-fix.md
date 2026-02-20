# Ralph Agent Instructions — Phase C: Fix Review Issues & Commit

You are an autonomous coding agent. A code review has been completed on your teammate's work. Your job is to fix the issues found, verify everything works, and commit.

## Your Task

1. Read `.ralph-review.json` — the code review report
2. Read `.ralph-current-story` — the story ID
3. Read `prd.json` — find the story's acceptance criteria
4. Read `progress.txt` — check Codebase Patterns section

### If verdict is "PASS"

No fixes needed. Proceed directly to commit (step 8 below).

### If verdict is "NEEDS_FIX"

5. Fix ALL critical and important issues listed in `.ralph-review.json`
6. Fix minor issues if the fix is trivial (< 5 lines changed)
7. Run quality checks (build, tests) — everything must pass

### Always

8. Commit ALL changes (staged + your fixes) with message: `feat: [Story ID] - [Story Title]`
9. Update the PRD: set `passes: true` for the completed story and update `notes` with a brief summary
10. Append progress to `progress.txt` (see format below)
11. Delete `.ralph-review.json` and `.ralph-current-story`

## Progress Report Format

APPEND to progress.txt (never replace, always append):
```
## [Date/Time] - [Story ID]
- What was implemented
- Files changed
- Review: [PASS | N issues fixed (X critical, Y important, Z minor)]
- **Learnings for future iterations:**
  - Patterns discovered
  - Gotchas encountered
  - Useful context
---
```

## Consolidate Patterns

If you discover a **reusable pattern**, add it to the `## Codebase Patterns` section at the TOP of progress.txt (create if it doesn't exist):

```
## Codebase Patterns
- Pattern description
```

Only add patterns that are **general and reusable**, not story-specific details.

## Update CLAUDE.md Files

If you discover reusable knowledge, add it to nearby CLAUDE.md files:
- API patterns, gotchas, non-obvious requirements, dependencies between files
- Do NOT add: story-specific details, temporary notes, info already in progress.txt

## Stop Condition

After committing and updating progress, check if ALL stories in `prd.json` have `passes: true`.

If ALL stories are complete: reply with `<promise>COMPLETE</promise>`
If stories remain: end your response normally.

## Important

- Fix ALL critical/important issues — do not skip any
- Run tests AFTER fixing — do not commit broken code
- Delete the review file after committing
