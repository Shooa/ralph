---
name: prd
description: "Generate a Product Requirements Document (PRD) for a new feature. Use when planning a feature, starting a new project, or when asked to create a PRD. Triggers on: create a prd, write prd for, plan this feature, requirements for, spec out."
user-invocable: true
---

# PRD Generator

Create detailed Product Requirements Documents that are clear, actionable, and suitable for implementation by AI agents. Every story follows strict TDD and includes specific code references.

---

## The Job

1. Receive a feature description from the user
2. Ask 3-5 essential clarifying questions (with lettered options)
3. **Scan the codebase** to find relevant files, patterns, test locations
4. Generate a structured PRD with TDD-structured stories and code references
5. Save to `tasks/prd-[feature-name].md`

**Important:** Do NOT start implementing. Just create the PRD.

---

## Step 1: Clarifying Questions

Ask only critical questions where the initial prompt is ambiguous. Focus on:

- **Problem/Goal:** What problem does this solve?
- **Core Functionality:** What are the key actions?
- **Scope/Boundaries:** What should it NOT do?
- **Success Criteria:** How do we know it's done?

### Format Questions Like This:

```
1. What is the primary goal of this feature?
   A. Improve user onboarding experience
   B. Increase user retention
   C. Reduce support burden
   D. Other: [please specify]

2. Who is the target user?
   A. New users only
   B. Existing users only
   C. All users
   D. Admin users only

3. What is the scope?
   A. Minimal viable version
   B. Full-featured implementation
   C. Just the backend/API
   D. Just the UI
```

This lets users respond with "1A, 2C, 3B" for quick iteration. Remember to indent the options.

---

## Step 1.5: Codebase Scan

**Before writing the PRD, scan the codebase to gather code references.** This is critical — PRDs without code references force the implementation agent to waste its context window exploring.

For each planned story, find:
- **Files to modify** — where the implementation code goes
- **Files to study** — related code, interfaces, patterns to follow
- **Test files** — where tests should be added

Use `Glob` and `Grep` to:
1. Find existing implementations of similar features
2. Locate test directories and naming conventions
3. Identify interfaces/ports the new code must conform to
4. Find config files that may need updates

Include these references directly in each user story.

---

## Step 2: PRD Structure

Generate the PRD with these sections:

### 1. Introduction/Overview
Brief description of the feature and the problem it solves.

### 2. Goals
Specific, measurable objectives (bullet list).

### 3. User Stories (TDD-Structured)

Each story MUST follow the **Red-Green-Refactor** TDD cycle. Structure acceptance criteria in this exact order:

**Format:**
```markdown
### US-001: [Title]
**Description:** As a [user], I want [feature] so that [benefit].

**Code References:**
- Modify: `src/path/to/file.cpp` — [what to change]
- Modify: `include/path/to/header.h` — [what to add]
- Study: `src/path/to/similar.cpp` — [pattern to follow]
- Study: `include/ports/IPort.h` — [interface to implement]
- Test: `test/unit/path/test_file.cpp` — [add new test cases]

**Acceptance Criteria (TDD):**
- [ ] RED: Write failing test `TestName` in `test/path/test_file.cpp` that [verifies specific behavior]
- [ ] GREEN: Implement [what] in `src/path/file.cpp` to make test pass
- [ ] GREEN: [additional implementation step if needed]
- [ ] REFACTOR: [cleanup if needed, otherwise omit]
- [ ] All tests pass
- [ ] Build passes
- [ ] **[UI stories only]** Verify in browser using dev-browser skill
```

**Rules:**
- RED always comes before GREEN — tests are written FIRST
- Each RED criterion names a specific test file and test name
- Each GREEN criterion names a specific implementation file
- Acceptance criteria must be verifiable, not vague
- "Works correctly" is bad. "Function returns error diagnostic for negative values" is good.

### 4. Functional Requirements
Numbered list of specific functionalities:
- "FR-1: The system must allow users to..."
- "FR-2: When a user clicks X, the system must..."

Be explicit and unambiguous.

### 5. Non-Goals (Out of Scope)
What this feature will NOT include. Critical for managing scope.

### 6. Technical Considerations
- **Key files and architecture** — list the most important files the agent needs to know about
- Known constraints or dependencies
- Integration points with existing systems
- Existing patterns to follow (with file references)

### 7. Success Metrics
How will success be measured?
- "All N unit tests pass"
- "Integration tests match reference binaries"

### 8. Open Questions
Remaining questions or areas needing clarification.

---

## Writing for AI Agents

The PRD reader is an AI agent with a limited context window. Therefore:

- **Include specific file paths** — the agent should NOT have to search for files
- **Name test files and test functions** — the agent should know exactly where to add tests
- **Reference similar implementations** — "follow the pattern in `src/adapters/X.cpp`" saves exploration
- Be explicit and unambiguous
- Number requirements for easy reference
- Use concrete examples where helpful

---

## Output

- **Format:** Markdown (`.md`)
- **Location:** `tasks/`
- **Filename:** `prd-[feature-name].md` (kebab-case)

---

## Example PRD

```markdown
# PRD: Task Priority System

## Introduction

Add priority levels to tasks so users can focus on what matters most. Tasks can be marked as high, medium, or low priority, with visual indicators and filtering.

## Goals

- Allow assigning priority (high/medium/low) to any task
- Provide clear visual differentiation between priority levels
- Enable filtering and sorting by priority
- Default new tasks to medium priority

## User Stories

### US-001: Add priority field to database
**Description:** As a developer, I need to store task priority so it persists across sessions.

**Code References:**
- Modify: `src/models/task.py` — add `status` field with enum
- Modify: `src/migrations/` — new migration file
- Study: `src/models/project.py` — example of enum field pattern
- Test: `test/models/test_task.py` — add priority field tests

**Acceptance Criteria (TDD):**
- [ ] RED: Write test `test_task_has_priority_field` in `test/models/test_task.py` that checks Task has `priority` with default 'medium'
- [ ] RED: Write test `test_task_priority_values` that checks only 'high'|'medium'|'low' are accepted
- [ ] GREEN: Add `priority` column to tasks table in `src/models/task.py`
- [ ] GREEN: Generate migration in `src/migrations/`
- [ ] All tests pass
- [ ] Build passes

### US-002: Display priority indicator on task cards
**Description:** As a user, I want to see task priority at a glance so I know what needs attention first.

**Code References:**
- Modify: `src/components/task_card.py` — integrate badge
- Modify: `src/components/badge.py` — add priority color variants
- Study: `src/components/task_card.py` — existing card layout
- Test: `test/components/test_task_card.py` — add badge rendering tests

**Acceptance Criteria (TDD):**
- [ ] RED: Write test `test_card_shows_priority_badge` in `test/components/test_task_card.py` that checks badge renders with correct color
- [ ] GREEN: Add priority color mapping to `src/components/badge.py` (red=high, yellow=medium, gray=low)
- [ ] GREEN: Integrate badge into `src/components/task_card.py`
- [ ] All tests pass
- [ ] Build passes
- [ ] Verify in browser using dev-browser skill

## Functional Requirements

- FR-1: Add `priority` field to tasks table ('high' | 'medium' | 'low', default 'medium')
- FR-2: Display colored priority badge on each task card
- FR-3: Include priority selector in task edit modal
- FR-4: Add priority filter dropdown to task list header

## Non-Goals

- No priority-based notifications or reminders
- No automatic priority assignment based on due date
- No priority inheritance for subtasks

## Technical Considerations

- **Key files:** `src/models/task.py` (model), `src/components/task_card.py` (UI), `src/api/tasks.py` (API)
- Reuse existing badge component with color variants (`src/components/badge.py`)
- Follow existing enum pattern from `src/models/project.py`
- Filter state managed via URL search params

## Success Metrics

- All 8+ new unit tests pass
- Priority changes persist after page reload
- No regression in existing test suite

## Open Questions

- Should priority affect task ordering within a column?
- Should we add keyboard shortcuts for priority changes?
```

---

## Checklist

Before saving the PRD:

- [ ] Asked clarifying questions with lettered options
- [ ] Incorporated user's answers
- [ ] **Scanned codebase** for relevant files, tests, patterns
- [ ] Every user story has **Code References** section with Modify/Study/Test entries
- [ ] Every story's acceptance criteria follow **RED → GREEN → REFACTOR** order
- [ ] RED criteria name specific test files and test names
- [ ] GREEN criteria name specific implementation files
- [ ] User stories are small and specific (one iteration each)
- [ ] Functional requirements are numbered and unambiguous
- [ ] Non-goals section defines clear boundaries
- [ ] Saved to `tasks/prd-[feature-name].md`
