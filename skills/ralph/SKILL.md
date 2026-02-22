---
name: ralph
description: "Convert PRDs to prd.json format for the Ralph autonomous agent system. Use when you have an existing PRD and need to convert it to Ralph's JSON format. Triggers on: convert this prd, turn this into ralph format, create prd.json from this, ralph json."
user-invocable: true
---

# Ralph PRD Converter

Converts existing PRDs to the prd.json format that Ralph uses for autonomous execution.
Enriches each story with code references so the implementation agent doesn't waste context searching.

---

## The Job

1. Take a PRD (markdown file or text)
2. Convert it to `prd.json` in your ralph directory
3. **Enrich with code references** — scan the codebase to find files the agent will need to modify, study, and test (see Enrichment section)

---

## Output Format

```json
{
  "project": "[Project Name]",
  "branchName": "ralph/[feature-name-kebab-case]",
  "description": "[Feature description from PRD title/intro]",
  "userStories": [
    {
      "id": "US-001",
      "title": "[Story title]",
      "description": "As a [user], I want [feature] so that [benefit]",
      "acceptanceCriteria": [
        "RED: Write failing test in [test file] that [verifies behavior]",
        "GREEN: Implement [what] in [file] to make test pass",
        "REFACTOR: [cleanup step if needed]",
        "All tests pass",
        "Build passes"
      ],
      "filesToModify": [
        "src/adapters/SomeFile.cpp",
        "include/domain/SomeType.h"
      ],
      "filesToStudy": [
        "src/adapters/RelatedFile.cpp — how similar feature is implemented",
        "include/ports/IPort.h — interface to implement against"
      ],
      "testFiles": [
        "test/unit/adapters/test_some_file.cpp — add new test cases"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    }
  ]
}
```

---

## TDD Cycle: The Development Methodology

**Every story MUST follow strict Red-Green-Refactor cycle.**

The agent implementing the story will follow TDD. Your job is to structure acceptance criteria so TDD is natural and obvious.

### Acceptance Criteria Order (ALWAYS this order):

1. **RED** — Write failing test(s) first. Name the test file and describe what the test checks.
2. **GREEN** — Implement the minimum code to make tests pass. Name the file(s) to modify.
3. **REFACTOR** — Optional cleanup step (only if needed).
4. **"All tests pass"** — Always last.
5. **"Build passes"** — Always last.

### Good TDD criteria:
```json
[
  "RED: Write test `GscParserTest.ParseIfElse` in test/unit/adapters/parsing/gsc/test_gsc_parser.cpp that verifies if/else blocks parse into correct AST nodes",
  "GREEN: Implement if/else parsing in src/adapters/parsing/gsc/GscParser.cpp — handle `if (cond) { ... } else { ... }` syntax",
  "GREEN: Add IfElse node type to include/domain/ast/Program.h if not present",
  "All tests pass",
  "Build passes"
]
```

### Bad criteria (no TDD structure):
```json
[
  "Implement if/else parsing",
  "Add tests",
  "Build passes"
]
```

---

## Code References: Enrichment

**Each story MUST include `filesToModify`, `filesToStudy`, and `testFiles`.**

These fields save the implementation agent from wasting its context window on codebase exploration.

### `filesToModify` — Files the agent needs to change
- Implementation files (`.cpp`, `.ts`, etc.)
- Header/interface files if new types/methods are added
- Config files if new entries are needed

### `filesToStudy` — Files the agent should READ for context
- Similar features already implemented (patterns to follow)
- Interfaces the new code must conform to
- Domain types used in the implementation
- Add a brief comment after `—` explaining WHY to study this file

### `testFiles` — Test files to create or modify
- Existing test files where new cases should go
- New test files to create (if new test fixture needed)

### How to find code references

When converting a PRD, you MUST scan the codebase:
1. Use `Glob` to find relevant files by naming patterns
2. Use `Grep` to search for related types, functions, patterns
3. Read key files to understand the architecture
4. Look at existing tests to know where new tests should go

**If you cannot find specific files, still provide your best guesses with `(verify)` suffix:**
```json
"filesToModify": ["src/adapters/parsing/NewParser.cpp (verify)"]
```

---

## Story Size: The Number One Rule

**Each story must be completable in ONE Ralph iteration (one context window).**

Ralph spawns a fresh agent instance per iteration with no memory of previous work. If a story is too big, the LLM runs out of context before finishing and produces broken code.

### Right-sized stories:
- Add a database column and migration
- Add a UI component to an existing page
- Update a server action with new logic
- Add a filter dropdown to a list

### Too big (split these):
- "Build the entire dashboard" - Split into: schema, queries, UI components, filters
- "Add authentication" - Split into: schema, middleware, login UI, session handling
- "Refactor the API" - Split into one story per endpoint or pattern

**Rule of thumb:** If you cannot describe the change in 2-3 sentences, it is too big.

---

## Story Ordering: Dependencies First

Stories execute in priority order. Earlier stories must not depend on later ones.

**Correct order:**
1. Domain types / interfaces (headers, contracts)
2. Tests for the new behavior (RED phase can come first)
3. Implementation that passes the tests (GREEN)
4. Integration / cross-cutting concerns
5. Wiring, CLI flags, config updates

**Wrong order:**
1. UI component (depends on schema that does not exist yet)
2. Schema change

---

## Acceptance Criteria: Must Be Verifiable

Each criterion must be something Ralph can CHECK, not something vague.

### Good criteria (verifiable + TDD):
- "RED: Write test `DelayBlock.NegativeDuration` that asserts error diagnostic"
- "GREEN: Add validation in `TypeCheckPass::visitDelay()` to reject negative durations"
- "All tests pass"
- "Build passes"

### Bad criteria (vague):
- "Works correctly"
- "User can do X easily"
- "Good UX"
- "Handles edge cases"

### Always include as final criteria:
```
"All tests pass"
"Build passes"
```

### For stories that change UI, also include:
```
"Verify in browser using dev-browser skill"
```

Frontend stories are NOT complete until visually verified.

---

## Conversion Rules

1. **Each user story becomes one JSON entry**
2. **IDs**: Sequential (US-001, US-002, etc.)
3. **Priority**: Based on dependency order, then document order
4. **All stories**: `passes: false` and empty `notes`
5. **branchName**: Derive from feature name, kebab-case, prefixed with `ralph/`
6. **Always add**: "All tests pass" and "Build passes" to every story's acceptance criteria
7. **Always include**: `filesToModify`, `filesToStudy`, `testFiles` arrays (never omit)
8. **TDD order**: Acceptance criteria follow RED → GREEN → REFACTOR → verify

---

## Splitting Large PRDs

If a PRD has big features, split them:

**Original:**
> "Add user notification system"

**Split into:**
1. US-001: Add notifications table to database
2. US-002: Create notification service for sending notifications
3. US-003: Add notification bell icon to header
4. US-004: Create notification dropdown panel
5. US-005: Add mark-as-read functionality
6. US-006: Add notification preferences page

Each is one focused change that can be completed and verified independently.

---

## Example

**Input PRD:**
```markdown
# Task Status Feature

Add ability to mark tasks with different statuses.

## Requirements
- Toggle between pending/in-progress/done on task list
- Filter list by status
- Show status badge on each task
- Persist status in database
```

**Output prd.json:**
```json
{
  "project": "TaskApp",
  "branchName": "ralph/task-status",
  "description": "Task Status Feature - Track task progress with status indicators",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add status field to tasks schema",
      "description": "As a developer, I need to store task status in the database.",
      "acceptanceCriteria": [
        "RED: Write test in test/models/test_task.py that checks Task has `status` field with default 'pending' and allowed values ['pending', 'in_progress', 'done']",
        "GREEN: Add `status` column to tasks table in src/models/task.py with default 'pending'",
        "GREEN: Generate and run migration in src/migrations/",
        "All tests pass",
        "Build passes"
      ],
      "filesToModify": [
        "src/models/task.py",
        "src/migrations/"
      ],
      "filesToStudy": [
        "src/models/task.py — existing Task model structure",
        "src/models/project.py — example of enum field pattern"
      ],
      "testFiles": [
        "test/models/test_task.py — add status field tests"
      ],
      "priority": 1,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-002",
      "title": "Display status badge on task cards",
      "description": "As a user, I want to see task status at a glance.",
      "acceptanceCriteria": [
        "RED: Write test in test/components/test_task_card.py that checks TaskCard renders status badge with correct color mapping",
        "GREEN: Add StatusBadge component to src/components/status_badge.py with color map: gray=pending, blue=in_progress, green=done",
        "GREEN: Integrate StatusBadge into TaskCard in src/components/task_card.py",
        "All tests pass",
        "Build passes",
        "Verify in browser using dev-browser skill"
      ],
      "filesToModify": [
        "src/components/status_badge.py",
        "src/components/task_card.py"
      ],
      "filesToStudy": [
        "src/components/task_card.py — existing card layout",
        "src/components/badge.py — existing badge component to reuse"
      ],
      "testFiles": [
        "test/components/test_task_card.py — add badge rendering tests"
      ],
      "priority": 2,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-003",
      "title": "Add status toggle to task list rows",
      "description": "As a user, I want to change task status directly from the list.",
      "acceptanceCriteria": [
        "RED: Write test in test/components/test_task_row.py that verifies status dropdown triggers update callback with new status",
        "RED: Write test in test/api/test_tasks.py that verifies PATCH /tasks/:id updates status and returns updated task",
        "GREEN: Add status dropdown to TaskRow in src/components/task_row.py",
        "GREEN: Add PATCH handler in src/api/tasks.py",
        "All tests pass",
        "Build passes",
        "Verify in browser using dev-browser skill"
      ],
      "filesToModify": [
        "src/components/task_row.py",
        "src/api/tasks.py"
      ],
      "filesToStudy": [
        "src/components/task_row.py — existing row structure",
        "src/api/tasks.py — existing API patterns"
      ],
      "testFiles": [
        "test/components/test_task_row.py — add dropdown tests",
        "test/api/test_tasks.py — add PATCH endpoint tests"
      ],
      "priority": 3,
      "passes": false,
      "notes": ""
    },
    {
      "id": "US-004",
      "title": "Filter tasks by status",
      "description": "As a user, I want to filter the list to see only certain statuses.",
      "acceptanceCriteria": [
        "RED: Write test in test/api/test_tasks.py that verifies GET /tasks?status=pending returns only pending tasks",
        "RED: Write test in test/components/test_task_list.py that verifies filter dropdown updates displayed tasks",
        "GREEN: Add `status` query param filtering to GET /tasks in src/api/tasks.py",
        "GREEN: Add filter dropdown to TaskList in src/components/task_list.py",
        "All tests pass",
        "Build passes",
        "Verify in browser using dev-browser skill"
      ],
      "filesToModify": [
        "src/api/tasks.py",
        "src/components/task_list.py"
      ],
      "filesToStudy": [
        "src/api/tasks.py — existing query param patterns",
        "src/components/task_list.py — existing list layout"
      ],
      "testFiles": [
        "test/api/test_tasks.py — add filter tests",
        "test/components/test_task_list.py — add filter dropdown tests"
      ],
      "priority": 4,
      "passes": false,
      "notes": ""
    }
  ]
}
```

---

## Archiving Previous Runs

**Before writing a new prd.json, check if there is an existing one from a different feature:**

1. Read the current `prd.json` if it exists
2. Check if `branchName` differs from the new feature's branch name
3. If different AND `progress.txt` has content beyond the header:
   - Create archive folder: `archive/YYYY-MM-DD-feature-name/`
   - Copy current `prd.json` and `progress.txt` to archive
   - Reset `progress.txt` with fresh header

**The ralph.sh script handles this automatically** when you run it, but if you are manually updating prd.json between runs, archive first.

---

## Checklist Before Saving

Before writing prd.json, verify:

- [ ] **Previous run archived** (if prd.json exists with different branchName, archive it first)
- [ ] Each story is completable in one iteration (small enough)
- [ ] Stories are ordered by dependency (domain types → tests → impl → integration)
- [ ] Every story has "All tests pass" and "Build passes" as criteria
- [ ] Every story has `filesToModify`, `filesToStudy`, `testFiles` populated
- [ ] Acceptance criteria follow RED → GREEN → REFACTOR → verify order
- [ ] RED criteria name specific test files and describe what the test checks
- [ ] GREEN criteria name specific implementation files
- [ ] `filesToStudy` entries have `—` comments explaining WHY
- [ ] UI stories have "Verify in browser using dev-browser skill" as criterion
- [ ] Acceptance criteria are verifiable (not vague)
- [ ] No story depends on a later story
