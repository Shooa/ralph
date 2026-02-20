#!/bin/bash
# Ralph Wiggum v2 - Implement → Review loop with gatekeeper commits
# Usage: ./ralph.sh [--tool amp|claude] [--reviewer codex|skip] [--max-rounds N] [max_iterations]
#
# Each iteration (one user story):
#   loop (up to max-rounds):
#     Agent: implement or fix review issues, stage files
#     Reviewer: review staged diff
#       PASS  → reviewer commits, marks story done, break
#       NEEDS_FIX → writes .ralph-review.json, agent retries
#
# Reviewer = gatekeeper: only the reviewer commits code.

set -e

# ─── Parse arguments ──────────────────────────────────────────────────

TOOL="amp"
REVIEWER="codex"
MAX_ITERATIONS=10
MAX_REVIEW_ROUNDS=3

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
    --max-rounds)
      MAX_REVIEW_ROUNDS="$2"
      shift 2
      ;;
    --max-rounds=*)
      MAX_REVIEW_ROUNDS="${1#*=}"
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

# ─── Helper: run the implementation agent ─────────────────────────────

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

# ─── Helper: run reviewer ────────────────────────────────────────────

run_review() {
  echo "  [Review] Running codex..."

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

echo "Starting Ralph v2 - Tool: $TOOL - Reviewer: $REVIEWER - Max iterations: $MAX_ITERATIONS - Max review rounds: $MAX_REVIEW_ROUNDS"
echo ""

for i in $(seq 1 $MAX_ITERATIONS); do
  echo "==============================================================="
  echo "  Ralph Story Iteration $i of $MAX_ITERATIONS"
  echo "==============================================================="

  # Clean up stale state from previous story
  rm -f "$REVIEW_FILE" "$STORY_FILE"

  # ─── Implement → Review loop ──────────────────────────────────────

  STORY_COMMITTED=false

  for round in $(seq 1 $MAX_REVIEW_ROUNDS); do
    echo ""
    echo "--- Round $round of $MAX_REVIEW_ROUNDS ---"

    # ─── Implement (or fix) ───────────────────────────────────────

    if [ "$round" -eq 1 ]; then
      echo ""
      echo ">>> Implement"
    else
      echo ""
      echo ">>> Fix review issues (round $round)"
    fi

    run_agent "$SCRIPT_DIR/CLAUDE.md" "Implement"

    # Check if there's anything staged
    if ! git diff --cached --quiet 2>/dev/null; then
      echo "  Staged changes detected."
    else
      echo "  WARNING: No staged changes."
      echo "  Skipping review."
      break
    fi

    # ─── Review ───────────────────────────────────────────────────

    echo ""
    echo ">>> Review"

    if [[ "$REVIEWER" == "codex" ]]; then
      run_review
    else
      echo "  Review skipped (--reviewer=skip)"
      # In skip mode, reviewer auto-passes and commits
      STORY_ID="unknown"
      [ -f "$STORY_FILE" ] && STORY_ID=$(cat "$STORY_FILE")
      # Just commit directly
      STORY_TITLE=$(jq -r --arg sid "$STORY_ID" '.userStories[] | select(.id == $sid) | .title // "unknown"' "$PRD_FILE" 2>/dev/null || echo "unknown")
      git commit -m "feat: [$STORY_ID] - $STORY_TITLE" || true
      # Mark story as passed
      jq --arg sid "$STORY_ID" '(.userStories[] | select(.id == $sid)).passes = true' "$PRD_FILE" > "$PRD_FILE.tmp" && mv "$PRD_FILE.tmp" "$PRD_FILE"
      rm -f "$REVIEW_FILE" "$STORY_FILE"
      STORY_COMMITTED=true
      break
    fi

    # ─── Check verdict ────────────────────────────────────────────

    VERDICT=$(jq -r '.verdict // "UNKNOWN"' "$REVIEW_FILE" 2>/dev/null || echo "UNKNOWN")

    if [[ "$VERDICT" == "PASS" ]]; then
      echo "  Story PASSED review."
      # Reviewer already committed on PASS (per review-prompt.md)
      rm -f "$REVIEW_FILE" "$STORY_FILE"
      STORY_COMMITTED=true
      break
    elif [[ "$VERDICT" == "NEEDS_FIX" ]]; then
      echo "  Story NEEDS_FIX — sending back to agent (round $((round + 1)))."
      # .ralph-review.json stays — agent will read it on next round
      if [ "$round" -eq "$MAX_REVIEW_ROUNDS" ]; then
        echo ""
        echo "  ERROR: Max review rounds ($MAX_REVIEW_ROUNDS) reached without PASS."
        echo "  Unstaging changes and moving to next story."
        git reset HEAD -- . 2>/dev/null || true
        rm -f "$REVIEW_FILE" "$STORY_FILE"
      fi
    else
      echo "  WARNING: Unknown verdict '$VERDICT'. Treating as NEEDS_FIX."
      if [ "$round" -eq "$MAX_REVIEW_ROUNDS" ]; then
        git reset HEAD -- . 2>/dev/null || true
        rm -f "$REVIEW_FILE" "$STORY_FILE"
      fi
    fi

    sleep 2
  done

  # ─── Check for completion ─────────────────────────────────────────

  if [ "$STORY_COMMITTED" = true ]; then
    # Check if COMPLETE signal was emitted by the reviewer
    if grep -q "<promise>COMPLETE</promise>" "$AGENT_OUTPUT_FILE" 2>/dev/null; then
      echo ""
      echo "==============================================================="
      echo "  Ralph completed all tasks!"
      echo "  Completed at iteration $i of $MAX_ITERATIONS"
      echo "==============================================================="
      exit 0
    fi

    # Also check prd.json directly
    REMAINING=$(jq '[.userStories[] | select(.passes != true)] | length' "$PRD_FILE" 2>/dev/null || echo "1")
    if [ "$REMAINING" -eq 0 ]; then
      echo ""
      echo "==============================================================="
      echo "  Ralph completed all tasks! (all stories pass)"
      echo "  Completed at iteration $i of $MAX_ITERATIONS"
      echo "==============================================================="
      exit 0
    fi
  fi

  echo ""
  echo "Story iteration $i complete. Continuing to next story..."
  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
