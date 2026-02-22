#!/bin/bash
# Ralph Wiggum v2 - Implement → Review loop with gatekeeper commits
# Usage: ./ralph.sh [--tool amp|claude] [--model MODEL] [--reviewer codex|skip] [--max-rounds N] [--enrich] [max_iterations]
#
# Phases:
#   0. Enrich (optional, --enrich): cheap sub-agent scans codebase, adds code refs to prd.json
#   1. Iterate stories (up to max_iterations):
#     loop (up to max-rounds):
#       Agent: implement or fix review issues, stage files (TDD: RED → GREEN → REFACTOR)
#       Reviewer: review staged diff
#         PASS  → reviewer commits, marks story done, break
#         NEEDS_FIX → writes .ralph-review.json, agent retries
#
# Reviewer = gatekeeper: only the reviewer commits code.
# If the reviewer crashes, ralph.sh commits as fallback.

set -e

# ─── Parse arguments ──────────────────────────────────────────────────

TOOL="amp"
MODEL=""
ENRICH_MODEL="claude-haiku-4-5-20251001"
REVIEWER="codex"
MAX_ITERATIONS=10
MAX_REVIEW_ROUNDS=3
DO_ENRICH=false

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
    --model)
      MODEL="$2"
      shift 2
      ;;
    --model=*)
      MODEL="${1#*=}"
      shift
      ;;
    --enrich)
      DO_ENRICH=true
      shift
      ;;
    --enrich-model)
      ENRICH_MODEL="$2"
      shift 2
      ;;
    --enrich-model=*)
      ENRICH_MODEL="${1#*=}"
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
LAST_REVIEWED_COMMIT_FILE=".ralph-last-reviewed-commit"

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

# ─── Trim progress.txt: keep Codebase Patterns, trim old story logs ──
# Keeps the file small so agents don't waste context reading stale logs.
# Story logs older than the last 5 are moved to progress-archive.txt.
if [ -f "$PROGRESS_FILE" ]; then
  STORY_COUNT=$(grep -c '^## .*- US-' "$PROGRESS_FILE" 2>/dev/null || echo "0")
  if [ "$STORY_COUNT" -gt 5 ]; then
    # Extract Codebase Patterns section (top of file, before first story log)
    FIRST_STORY_LINE=$(grep -n '^## .*- US-' "$PROGRESS_FILE" | head -1 | cut -d: -f1)
    if [ -n "$FIRST_STORY_LINE" ] && [ "$FIRST_STORY_LINE" -gt 1 ]; then
      head -n $((FIRST_STORY_LINE - 1)) "$PROGRESS_FILE" > "$PROGRESS_FILE.trimmed"
    else
      echo "# Ralph Progress Log" > "$PROGRESS_FILE.trimmed"
      echo "---" >> "$PROGRESS_FILE.trimmed"
    fi
    # Keep only last 5 story logs
    KEEP_FROM=$(grep -n '^## .*- US-' "$PROGRESS_FILE" | tail -5 | head -1 | cut -d: -f1)
    tail -n +"$KEEP_FROM" "$PROGRESS_FILE" >> "$PROGRESS_FILE.trimmed"
    # Archive the rest
    cat "$PROGRESS_FILE" >> "$SCRIPT_DIR/progress-archive.txt"
    mv "$PROGRESS_FILE.trimmed" "$PROGRESS_FILE"
    echo "  Trimmed progress.txt (kept patterns + last 5 stories, archived full log)"
  fi
fi

# Temp file for capturing agent output (to check for COMPLETE signal)
AGENT_OUTPUT_FILE=$(mktemp /tmp/ralph-output.XXXXXX)
trap "rm -f '$AGENT_OUTPUT_FILE'" EXIT

# ─── Rate limit detection and retry ──────────────────────────────────

RATE_LIMIT_WAIT=900        # 15 minutes between retries
RATE_LIMIT_MAX_WAIT=28800  # 8 hours total wait before giving up
RATE_LIMIT_TOTAL_WAITED=0

is_rate_limited() {
  local OUTPUT_FILE="$1"
  grep -qiE 'rate.limit|rate_limit_exceeded|429|overloaded|usage.limit|too many requests' "$OUTPUT_FILE" 2>/dev/null
}

wait_for_rate_limit() {
  local WHO="$1"  # "agent" or "reviewer"
  echo ""
  echo "  ⏸  Rate limit detected ($WHO). Pausing..."

  while true; do
    if [ "$RATE_LIMIT_TOTAL_WAITED" -ge "$RATE_LIMIT_MAX_WAIT" ]; then
      echo "  ✗  Rate limit wait exceeded ${RATE_LIMIT_MAX_WAIT}s total. Giving up."
      echo "  ✗  Resume manually when limits reset."
      exit 2
    fi

    local REMAINING_MINS=$(( (RATE_LIMIT_MAX_WAIT - RATE_LIMIT_TOTAL_WAITED) / 60 ))
    echo "  ⏸  Waiting ${RATE_LIMIT_WAIT}s... (total waited: ${RATE_LIMIT_TOTAL_WAITED}s, give up in ~${REMAINING_MINS}m)"
    sleep "$RATE_LIMIT_WAIT"
    RATE_LIMIT_TOTAL_WAITED=$(( RATE_LIMIT_TOTAL_WAITED + RATE_LIMIT_WAIT ))

    # Probe: lightweight check if limits have reset
    echo "  ⏸  Probing API availability..."
    local PROBE_OUT
    if [[ "$WHO" == "reviewer" ]]; then
      PROBE_OUT=$(codex exec --full-auto -C "$(pwd)" <<< 'echo "probe ok"' 2>&1 || true)
    else
      PROBE_OUT=$(claude --print <<< 'Reply with exactly: probe ok' 2>&1 || true)
    fi

    if echo "$PROBE_OUT" | grep -qi "probe ok"; then
      echo "  ▶  API available. Resuming."
      RATE_LIMIT_TOTAL_WAITED=0  # reset for next potential limit
      return 0
    fi

    if is_rate_limited <(echo "$PROBE_OUT"); then
      echo "  ⏸  Still rate limited."
    else
      # Not rate limited but probe didn't return expected output — try anyway
      echo "  ▶  Probe inconclusive but no rate limit detected. Resuming."
      RATE_LIMIT_TOTAL_WAITED=0
      return 0
    fi
  done
}

# ─── Helper: commit story from ralph.sh (fallback / skip mode) ───────
# Used when the reviewer didn't commit (crash, skip, etc.)

commit_story() {
  local REASON="$1"  # "skip" | "reviewer-crash" | etc.

  local STORY_ID="unknown"
  [ -f "$STORY_FILE" ] && STORY_ID=$(cat "$STORY_FILE")

  local STORY_TITLE
  STORY_TITLE=$(jq -r --arg sid "$STORY_ID" \
    '.userStories[] | select(.id == $sid) | .title // "unknown"' \
    "$PRD_FILE" 2>/dev/null || echo "unknown")

  # Commit staged changes
  git commit -m "feat: [$STORY_ID] - $STORY_TITLE" || true

  # Save last reviewed commit hash
  git rev-parse HEAD > "$LAST_REVIEWED_COMMIT_FILE"

  # Mark story as passed in prd.json
  jq --arg sid "$STORY_ID" \
    '(.userStories[] | select(.id == $sid)).passes = true' \
    "$PRD_FILE" > "$PRD_FILE.tmp" && mv "$PRD_FILE.tmp" "$PRD_FILE"

  # Append to progress
  {
    echo ""
    echo "## $(date '+%Y-%m-%d %H:%M') - $STORY_ID"
    echo "- $STORY_TITLE"
    echo "- Review: $REASON"
    echo "---"
  } >> "$PROGRESS_FILE"

  echo "  Committed [$STORY_ID] ($REASON)"

  # Cleanup
  rm -f "$REVIEW_FILE" "$STORY_FILE" ".ralph-review-baseline"
}

# ─── Helper: run the implementation agent ─────────────────────────────

run_agent() {
  local PROMPT_FILE="$1"
  local PHASE_NAME="$2"

  echo "  [$PHASE_NAME] Running $TOOL${MODEL:+ (model: $MODEL)}..."
  echo ""

  if [[ "$TOOL" == "amp" ]]; then
    cat "$PROMPT_FILE" | amp --dangerously-allow-all 2>&1 | tee "$AGENT_OUTPUT_FILE" || true
  else
    claude ${MODEL:+--model "$MODEL"} --dangerously-skip-permissions --print < "$PROMPT_FILE" 2>&1 | tee "$AGENT_OUTPUT_FILE" || true
  fi

  echo ""
}

# ─── Helper: run reviewer ────────────────────────────────────────────
# Sets REVIEW_VERDICT: "PASS", "NEEDS_FIX", or "CRASH"

REVIEW_VERDICT="UNKNOWN"

run_review() {
  echo "  [Review] Running codex..."

  # Clean old review
  rm -f "$REVIEW_FILE"

  # Write review baseline context for the reviewer
  local BASELINE_COMMIT=""
  if [ -f "$LAST_REVIEWED_COMMIT_FILE" ]; then
    BASELINE_COMMIT=$(cat "$LAST_REVIEWED_COMMIT_FILE")
    # Verify the commit still exists (could be rebased)
    if ! git cat-file -e "$BASELINE_COMMIT" 2>/dev/null; then
      BASELINE_COMMIT=""
    fi
  fi
  if [ -z "$BASELINE_COMMIT" ]; then
    # Fallback: merge-base with main
    BASELINE_COMMIT=$(git merge-base HEAD main 2>/dev/null || git rev-parse HEAD~1 2>/dev/null || echo "")
  fi

  # Write context file for the reviewer
  {
    echo "LAST_REVIEWED_COMMIT=$BASELINE_COMMIT"
    echo "# Use: git diff $BASELINE_COMMIT..HEAD  — to see ALL changes since last approved review"
    echo "# Use: git diff --cached                — to see only currently staged changes"
    echo "# IMPORTANT: Review the FULL diff ($BASELINE_COMMIT..HEAD), not just staged!"
  } > ".ralph-review-baseline"

  echo "  Review baseline: $BASELINE_COMMIT"

  local REVIEW_OUTPUT_FILE
  REVIEW_OUTPUT_FILE=$(mktemp /tmp/ralph-review-output.XXXXXX)

  codex exec \
    --full-auto \
    -C "$(pwd)" \
    < "$SCRIPT_DIR/review-prompt.md" \
    > "$REVIEW_OUTPUT_FILE" 2>&1 || true

  # Retry on rate limit
  while is_rate_limited "$REVIEW_OUTPUT_FILE"; do
    wait_for_rate_limit "reviewer"
    rm -f "$REVIEW_FILE"
    codex exec \
      --full-auto \
      -C "$(pwd)" \
      < "$SCRIPT_DIR/review-prompt.md" \
      > "$REVIEW_OUTPUT_FILE" 2>&1 || true
  done

  # Check if codex produced the review file
  if [ ! -f "$REVIEW_FILE" ]; then
    echo "  WARNING: Codex crashed or did not produce $REVIEW_FILE."
    echo "  Last 20 lines of codex output:"
    tail -20 "$REVIEW_OUTPUT_FILE" 2>/dev/null | sed 's/^/    /'
    REVIEW_VERDICT="CRASH"
    rm -f "$REVIEW_OUTPUT_FILE"
    return
  fi

  rm -f "$REVIEW_OUTPUT_FILE"

  REVIEW_VERDICT=$(jq -r '.verdict // "UNKNOWN"' "$REVIEW_FILE" 2>/dev/null || echo "UNKNOWN")
  local ISSUE_COUNT
  ISSUE_COUNT=$(jq '.issues | length' "$REVIEW_FILE" 2>/dev/null || echo "0")

  echo ""
  echo "  Review verdict: $REVIEW_VERDICT ($ISSUE_COUNT issues)"

  # Print issue summary (conclusions only)
  if [ "$ISSUE_COUNT" -gt 0 ]; then
    echo ""
    jq -r '.issues[] | "  [\(.severity)] \(.category): \(.description)"' "$REVIEW_FILE" 2>/dev/null
  fi

  if jq -e '.summary' "$REVIEW_FILE" > /dev/null 2>&1; then
    echo ""
    echo "  Summary: $(jq -r '.summary' "$REVIEW_FILE")"
  fi

  echo ""
}

# ─── Enrichment phase (optional) ──────────────────────────────────────

if [ "$DO_ENRICH" = true ] && [ -f "$SCRIPT_DIR/enrich-prompt.md" ]; then
  # Check if prd.json already has filesToModify (skip if enriched)
  HAS_REFS=$(jq '[.userStories[] | select(.filesToModify != null and (.filesToModify | length) > 0)] | length' "$PRD_FILE" 2>/dev/null || echo "0")
  TOTAL=$(jq '.userStories | length' "$PRD_FILE" 2>/dev/null || echo "0")

  if [ "$HAS_REFS" -lt "$TOTAL" ]; then
    echo "==============================================================="
    echo "  Enrichment: Scanning codebase for code references..."
    echo "  Model: $ENRICH_MODEL"
    echo "  Stories needing enrichment: $((TOTAL - HAS_REFS)) of $TOTAL"
    echo "==============================================================="
    echo ""

    # Copy prd.json to working dir for the enrichment agent
    cp "$PRD_FILE" "$(pwd)/prd.json" 2>/dev/null || true

    claude --model "$ENRICH_MODEL" --dangerously-skip-permissions --print < "$SCRIPT_DIR/enrich-prompt.md" 2>&1 || true

    # Copy enriched prd.json back if it was modified in working dir
    if [ -f "$(pwd)/prd.json" ] && [ "$(pwd)/prd.json" != "$PRD_FILE" ]; then
      # Validate JSON before overwriting
      if jq . "$(pwd)/prd.json" > /dev/null 2>&1; then
        cp "$(pwd)/prd.json" "$PRD_FILE"
        echo ""
        echo "  Enrichment complete. prd.json updated with code references."
      else
        echo ""
        echo "  WARNING: Enrichment produced invalid JSON. Keeping original prd.json."
      fi
    fi

    echo ""
  else
    echo "  Enrichment: All stories already have code references. Skipping."
    echo ""
  fi
fi

# ─── Main loop ────────────────────────────────────────────────────────

echo "Starting Ralph v2.1-shooa - Tool: $TOOL${MODEL:+ ($MODEL)} - Reviewer: $REVIEWER - Max iterations: $MAX_ITERATIONS - Max review rounds: $MAX_REVIEW_ROUNDS"
echo "  Optimizations: jq-extract, no-lock-diff, progress-trim, graceful-stop"
echo ""

for i in $(seq 1 $MAX_ITERATIONS); do
  # ─── Early exit: check if all stories are already done ────────────
  REMAINING=$(jq '[.userStories[] | select(.passes != true)] | length' "$PRD_FILE" 2>/dev/null || echo "1")
  if [ "$REMAINING" -eq 0 ]; then
    echo ""
    echo "==============================================================="
    echo "  Ralph completed all tasks! (all stories pass)"
    echo "  Completed at iteration $i of $MAX_ITERATIONS"
    echo "==============================================================="
    exit 0
  fi

  echo "==============================================================="
  echo "  Ralph Story Iteration $i of $MAX_ITERATIONS ($REMAINING stories remaining)"
  echo "==============================================================="

  # Clean up stale state from previous story
  rm -f "$REVIEW_FILE" "$STORY_FILE" ".ralph-review-baseline"

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

    # Retry on rate limit
    while is_rate_limited "$AGENT_OUTPUT_FILE"; do
      wait_for_rate_limit "agent"
      run_agent "$SCRIPT_DIR/CLAUDE.md" "Implement"
    done

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

    if [[ "$REVIEWER" == "skip" ]]; then
      echo "  Review skipped (--reviewer=skip)"
      commit_story "review skipped"
      STORY_COMMITTED=true
      break
    fi

    # Run codex review
    run_review

    # ─── Handle verdict ───────────────────────────────────────────

    if [[ "$REVIEW_VERDICT" == "CRASH" ]]; then
      echo "  Reviewer crashed — committing from ralph.sh as fallback."
      commit_story "reviewer crashed, auto-committed"
      STORY_COMMITTED=true
      break

    elif [[ "$REVIEW_VERDICT" == "PASS" ]]; then
      # Check if the reviewer already committed (it should per review-prompt.md)
      if git diff --cached --quiet 2>/dev/null; then
        # Nothing staged = reviewer committed successfully
        echo "  Story PASSED review (reviewer committed)."
        # Save last reviewed commit hash
        git rev-parse HEAD > "$LAST_REVIEWED_COMMIT_FILE"
      else
        # Reviewer wrote PASS but didn't commit — do it ourselves
        echo "  Story PASSED review but reviewer did not commit — committing from ralph.sh."
        commit_story "PASS (committed by ralph.sh)"
      fi
      rm -f "$REVIEW_FILE" "$STORY_FILE" ".ralph-review-baseline"
      STORY_COMMITTED=true
      break

    elif [[ "$REVIEW_VERDICT" == "NEEDS_FIX" ]]; then
      echo "  Story NEEDS_FIX — sending back to agent (round $((round + 1)))."
      # .ralph-review.json stays — agent will read it on next round
      if [ "$round" -eq "$MAX_REVIEW_ROUNDS" ]; then
        echo ""
        echo "  ERROR: Max review rounds ($MAX_REVIEW_ROUNDS) reached without PASS."
        echo "  Leaving changes in working tree for next iteration."
        rm -f "$REVIEW_FILE" "$STORY_FILE" ".ralph-review-baseline"
      fi

    else
      echo "  WARNING: Unknown verdict '$REVIEW_VERDICT'. Treating as NEEDS_FIX."
      if [ "$round" -eq "$MAX_REVIEW_ROUNDS" ]; then
        rm -f "$REVIEW_FILE" "$STORY_FILE" ".ralph-review-baseline"
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

  # ─── Stop claim: touch .ralph-stop to gracefully stop before next story ──
  if [ -f ".ralph-stop" ]; then
    rm -f ".ralph-stop"
    echo ""
    echo "==============================================================="
    echo "  Ralph stopped by user (.ralph-stop file detected)"
    echo "  Stopped after iteration $i ($REMAINING stories remaining)"
    echo "==============================================================="
    exit 0
  fi

  sleep 2
done

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Check $PROGRESS_FILE for status."
exit 1
