#!/bin/bash
# Ralph Wiggum v2 - Three-phase AI agent loop with code review
# Usage: ./ralph.sh [--tool amp|claude] [--reviewer codex|skip] [max_iterations]
#
# Phase A: Implement (claude/amp) — code the story, stage files, no commit
# Phase B: Review (codex exec)   — review staged diff, write .ralph-review.json
# Phase C: Fix & Commit (claude/amp) — fix review issues, test, commit

set -e

# ─── Parse arguments ──────────────────────────────────────────────────

TOOL="amp"
REVIEWER="codex"
MAX_ITERATIONS=10

while [[ $# -gt 0 ]]; do
  case $1 in
    --tool)
      TOOL="$2"
      shift 2
      ;;
    --tool=*)
      TOOL="${1#*=}"
      shift
      ;;
    --reviewer)
      REVIEWER="$2"
      shift 2
      ;;
    --reviewer=*)
      REVIEWER="${1#*=}"
      shift
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# Validate
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp' or 'claude'."
  exit 1
fi
if [[ "$REVIEWER" != "codex" && "$REVIEWER" != "skip" ]]; then
  echo "Error: Invalid reviewer '$REVIEWER'. Must be 'codex' or 'skip'."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"
LAST_BRANCH_FILE="$SCRIPT_DIR/.last-branch"

REVIEW_FILE=".ralph-review.json"
STORY_FILE=".ralph-current-story"

# ─── Archive previous run if branch changed ───────────────────────────

if [ -f "$PRD_FILE" ] && [ -f "$LAST_BRANCH_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  LAST_BRANCH=$(cat "$LAST_BRANCH_FILE" 2>/dev/null || echo "")

  if [ -n "$CURRENT_BRANCH" ] && [ -n "$LAST_BRANCH" ] && [ "$CURRENT_BRANCH" != "$LAST_BRANCH" ]; then
    DATE=$(date +%Y-%m-%d)
    FOLDER_NAME=$(echo "$LAST_BRANCH" | sed 's|^ralph/||')
    ARCHIVE_FOLDER="$ARCHIVE_DIR/$DATE-$FOLDER_NAME"

    echo "Archiving previous run: $LAST_BRANCH"
    mkdir -p "$ARCHIVE_FOLDER"
    [ -f "$PRD_FILE" ] && cp "$PRD_FILE" "$ARCHIVE_FOLDER/"
    [ -f "$PROGRESS_FILE" ] && cp "$PROGRESS_FILE" "$ARCHIVE_FOLDER/"
    echo "   Archived to: $ARCHIVE_FOLDER"

    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
  fi
fi

# Track current branch
if [ -f "$PRD_FILE" ]; then
  CURRENT_BRANCH=$(jq -r '.branchName // empty' "$PRD_FILE" 2>/dev/null || echo "")
  if [ -n "$CURRENT_BRANCH" ]; then
    echo "$CURRENT_BRANCH" > "$LAST_BRANCH_FILE"
  fi
fi

# Initialize progress file
if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

# Temp file for capturing agent output (to check for COMPLETE signal)
AGENT_OUTPUT_FILE=$(mktemp /tmp/ralph-output.XXXXXX)
trap "rm -f '$AGENT_OUTPUT_FILE'" EXIT

# ─── Helper: run the implementation/fix agent ─────────────────────────
# Output streams directly to terminal. Also saved to AGENT_OUTPUT_FILE
# for post-hoc checks (e.g. COMPLETE signal).

run_agent() {
  local PROMPT_FILE="$1"
  local PHASE_NAME="$2"

  echo "  [$PHASE_NAME] Running $TOOL..."
  echo ""

  if [[ "$TOOL" == "amp" ]]; then
    cat "$PROMPT_FILE" | amp --dangerously-allow-all 2>&1 | tee "$AGENT_OUTPUT_FILE" || true
  else
    claude --dangerously-skip-permissions --print < "$PROMPT_FILE" 2>&1 | tee "$AGENT_OUTPUT_FILE" || true
  fi

  echo ""
}

# ─── Helper: run codex review ─────────────────────────────────────────

run_review() {
  echo "  [Phase B: Review] Running codex..."

  # Clean up old review file
  rm -f "$REVIEW_FILE"

  codex exec \
    --full-auto \
    -C "$(pwd)" \
    < "$SCRIPT_DIR/review-prompt.md" \
    2>&1 | tee /dev/stderr || true

  # Check that review file was created
  if [ ! -f "$REVIEW_FILE" ]; then
    echo "  WARNING: Codex did not produce $REVIEW_FILE. Creating PASS fallback."
    local STORY_ID="unknown"
    [ -f "$STORY_FILE" ] && STORY_ID=$(cat "$STORY_FILE")
    cat > "$REVIEW_FILE" <<EOF
{
  "story_id": "$STORY_ID",
  "verdict": "PASS",
  "summary": "Review skipped — codex did not produce a report",
  "issues": []
}
EOF
  fi

  local VERDICT
  VERDICT=$(jq -r '.verdict // "UNKNOWN"' "$REVIEW_FILE" 2>/dev/null || echo "UNKNOWN")
  local ISSUE_COUNT
  ISSUE_COUNT=$(jq '.issues | length' "$REVIEW_FILE" 2>/dev/null || echo "0")

  echo ""
  echo "  Review verdict: $VERDICT ($ISSUE_COUNT issues)"
  echo ""
}

# ─── Main loop ────────────────────────────────────────────────────────

echo "Starting Ralph v2 - Tool: $TOOL - Reviewer: $REVIEWER - Max iterations: $MAX_ITERATIONS"
echo ""

for i in $(seq 1 $MAX_ITERATIONS); do
  echo "==============================================================="
  echo "  Ralph Iteration $i of $MAX_ITERATIONS"
  echo "==============================================================="

  # Clean up stale state from previous iterations
  rm -f "$REVIEW_FILE" "$STORY_FILE"

  # ─── Phase A: Implement ───────────────────────────────────────────

  echo ""
  echo "--- Phase A: Implement ---"
  run_agent "$SCRIPT_DIR/CLAUDE.md" "Phase A: Implement"

  # Check if there's anything staged
  if ! git diff --cached --quiet 2>/dev/null; then
    echo "  Staged changes detected."
  else
    echo "  WARNING: No staged changes after Phase A."
    echo "  Skipping review, moving to next iteration."
    sleep 2
    continue
  fi

  # ─── Phase B: Review ──────────────────────────────────────────────

  echo ""
  echo "--- Phase B: Review ---"
  if [[ "$REVIEWER" == "codex" ]]; then
    run_review
  else
    echo "  Review skipped (--reviewer=skip)"
    STORY_ID="unknown"
    [ -f "$STORY_FILE" ] && STORY_ID=$(cat "$STORY_FILE")
    cat > "$REVIEW_FILE" <<EOF
{
  "story_id": "$STORY_ID",
  "verdict": "PASS",
  "summary": "Review skipped by user",
  "issues": []
}
EOF
  fi

  # ─── Phase C: Fix & Commit ────────────────────────────────────────

  echo ""
  echo "--- Phase C: Fix & Commit ---"
  run_agent "$SCRIPT_DIR/CLAUDE-fix.md" "Phase C: Fix & Commit"

  # Check for completion signal in captured output
  if grep -q "<promise>COMPLETE</promise>" "$AGENT_OUTPUT_FILE" 2>/dev/null; then
    echo ""
    echo "==============================================================="
    echo "  Ralph completed all tasks!"
    echo "  Completed at iteration $i of $MAX_ITERATIONS"
    echo "==============================================================="
    # Final cleanup
    rm -f "$REVIEW_FILE" "$STORY_FILE"
    exit 0
  fi

  echo ""
  echo "Iteration $i complete. Continuing..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
