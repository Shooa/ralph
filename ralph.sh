#!/bin/bash
# Ralph v2.2 - Global CLI with branch-based sessions
# Usage: ralph [options] [max_iterations]
#
# Install: curl -sL https://raw.githubusercontent.com/Shooa/ralph/main/install.sh | bash
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

RALPH_VERSION="2.2.0"
RALPH_HOME="${RALPH_HOME:-$HOME/.ralph}"
RALPH_REPO="https://github.com/Shooa/ralph"

# ─── Parse arguments ──────────────────────────────────────────────────

TOOL="amp"
MODEL=""
ENRICH_MODEL="claude-haiku-4-5-20251001"
REVIEWER="codex"
MAX_ITERATIONS=10
MAX_REVIEW_ROUNDS=3
DO_ENRICH=false
RALPH_NO_UPDATE=false
RUN_NAME=""
CMD=""

show_help() {
  cat <<'HELPEOF'
Ralph v2.2 - Autonomous AI agent loop with code review

Usage: ralph [options] [max_iterations]

Options:
  --tool amp|claude          LLM agent to use (default: amp)
  --model MODEL              Model override for the agent
  --reviewer codex|claude|skip  Code reviewer (default: codex)
  --max-rounds N             Max review rounds per story (default: 3)
  --enrich                   Run enrichment phase (scan codebase for code refs)
  --enrich-model MODEL       Model for enrichment (default: claude-haiku-4-5-20251001)
  --run NAME                 Use tasks/NAME/ explicitly (instead of branch detection)
  --list                     List all runs with status
  --new NAME                 Create a new empty run
  --no-update                Skip auto-update check
  --version                  Show version
  --help                     Show this help

Run directory resolution:
  1. --run NAME         → tasks/NAME/
  2. git branch ralph/X → tasks/ralph-X/
  3. Single tasks/*/prd.json → that directory
  4. Otherwise → error with suggestions

Examples:
  ralph --tool claude --reviewer codex 15
  ralph --tool claude --enrich --reviewer skip 10
  ralph --run my-feature --tool claude 5
  ralph --list
  ralph --new my-feature
HELPEOF
}

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
    --run)
      RUN_NAME="$2"
      shift 2
      ;;
    --run=*)
      RUN_NAME="${1#*=}"
      shift
      ;;
    --list)
      CMD="list"
      shift
      ;;
    --new)
      CMD="new"
      RUN_NAME="$2"
      shift 2
      ;;
    --new=*)
      CMD="new"
      RUN_NAME="${1#*=}"
      shift
      ;;
    --no-update)
      RALPH_NO_UPDATE=true
      shift
      ;;
    --version)
      echo "ralph $RALPH_VERSION"
      exit 0
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

# Validate tool/reviewer
if [[ "$TOOL" != "amp" && "$TOOL" != "claude" ]]; then
  echo "Error: Invalid tool '$TOOL'. Must be 'amp' or 'claude'."
  exit 1
fi
if [[ "$REVIEWER" != "codex" && "$REVIEWER" != "claude" && "$REVIEWER" != "skip" ]]; then
  echo "Error: Invalid reviewer '$REVIEWER'. Must be 'codex', 'claude', or 'skip'."
  exit 1
fi

# ─── Project root detection ──────────────────────────────────────────

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ─── Auto-update ─────────────────────────────────────────────────────

setup_skill_symlinks() {
  local CLAUDE_SKILLS="$HOME/.claude/skills"
  mkdir -p "$CLAUDE_SKILLS"
  for skill_dir in "$RALPH_HOME"/skills/*/; do
    [ -d "$skill_dir" ] || continue
    local skill_name
    skill_name=$(basename "$skill_dir")
    local target="$CLAUDE_SKILLS/$skill_name"
    if [ -L "$target" ]; then
      rm "$target"
    elif [ -e "$target" ]; then
      # Don't overwrite non-symlink user skills
      continue
    fi
    ln -s "$skill_dir" "$target"
  done
}

ralph_self_update() {
  [ "$RALPH_NO_UPDATE" = true ] && return 0

  local REMOTE_SHA
  REMOTE_SHA=$(git ls-remote "$RALPH_REPO.git" HEAD 2>/dev/null | cut -f1)
  [ -z "$REMOTE_SHA" ] && return 0  # offline — skip silently

  local LOCAL_SHA=""
  [ -f "$RALPH_HOME/.git-sha" ] && LOCAL_SHA=$(cat "$RALPH_HOME/.git-sha")
  [ "$REMOTE_SHA" = "$LOCAL_SHA" ] && return 0  # up to date

  local SHORT_OLD="${LOCAL_SHA:0:7}"
  local SHORT_NEW="${REMOTE_SHA:0:7}"
  echo "Updating ralph (${SHORT_OLD:-none} → $SHORT_NEW)..."

  local TMP_DIR
  TMP_DIR=$(mktemp -d)
  if curl -sL "$RALPH_REPO/archive/refs/heads/main.tar.gz" | tar xz -C "$TMP_DIR" --strip-components=1 2>/dev/null; then
    # Preserve .git-sha during copy
    rsync -a --exclude='.git' "$TMP_DIR/" "$RALPH_HOME/"
    echo "$REMOTE_SHA" > "$RALPH_HOME/.git-sha"
    setup_skill_symlinks
    echo "Updated to $SHORT_NEW."
    rm -rf "$TMP_DIR"
    # Re-exec with the updated script
    exec "$RALPH_HOME/ralph.sh" "$@"
  else
    echo "Warning: Update failed (network error?). Continuing with current version."
    rm -rf "$TMP_DIR"
  fi
}

ralph_self_update "$@"

# ─── Resolve run directory ───────────────────────────────────────────

resolve_run_dir() {
  # 1. Explicit --run NAME
  if [ -n "$RUN_NAME" ]; then
    RUN_DIR="$PROJECT_ROOT/tasks/$RUN_NAME"
    return
  fi

  # 2. Git branch ralph/X → tasks/ralph-X/
  local BRANCH
  BRANCH=$(git branch --show-current 2>/dev/null || echo "")
  if [ -n "$BRANCH" ]; then
    local DIR_NAME
    DIR_NAME=$(echo "$BRANCH" | tr '/' '-')
    if [ -f "$PROJECT_ROOT/tasks/$DIR_NAME/prd.json" ]; then
      RUN_DIR="$PROJECT_ROOT/tasks/$DIR_NAME"
      return
    fi
  fi

  # 3. Fallback: single run directory
  local RUNS=()
  for d in "$PROJECT_ROOT"/tasks/*/prd.json; do
    [ -f "$d" ] && RUNS+=("$(dirname "$d")")
  done
  if [ ${#RUNS[@]} -eq 1 ]; then
    RUN_DIR="${RUNS[0]}"
    return
  fi

  # 4. Error: can't determine
  echo "Error: Cannot determine run directory."
  echo "  Project: $PROJECT_ROOT"
  echo "  Branch: ${BRANCH:-<detached>}"
  if [ ${#RUNS[@]} -gt 0 ]; then
    echo "  Available runs:"
    for run in "${RUNS[@]}"; do
      echo "    $(basename "$run")"
    done
  else
    echo "  No runs found in tasks/"
  fi
  echo ""
  echo "  Use: ralph --run <name>"
  echo "  Or:  ralph --new <name>"
  exit 1
}

# ─── Commands: --list, --new ─────────────────────────────────────────

cmd_list() {
  echo "Ralph runs in $(basename "$PROJECT_ROOT")/tasks/:"
  echo ""

  local FOUND=false
  for d in "$PROJECT_ROOT"/tasks/*/prd.json; do
    [ -f "$d" ] || continue
    FOUND=true
    local NAME
    NAME=$(basename "$(dirname "$d")")
    local TOTAL
    TOTAL=$(jq '.userStories | length' "$d" 2>/dev/null || echo "?")
    local DONE
    DONE=$(jq '[.userStories[] | select(.passes == true)] | length' "$d" 2>/dev/null || echo "?")
    local BRANCH
    BRANCH=$(jq -r '.branchName // "-"' "$d" 2>/dev/null || echo "-")
    local PROJECT
    PROJECT=$(jq -r '.project // "-"' "$d" 2>/dev/null || echo "-")
    printf "  %-30s %s/%s done  (branch: %s, project: %s)\n" "$NAME" "$DONE" "$TOTAL" "$BRANCH" "$PROJECT"
  done

  if [ "$FOUND" = false ]; then
    echo "  No runs found. Create one with: ralph --new <name>"
  fi
}

cmd_new() {
  if [ -z "$RUN_NAME" ]; then
    echo "Error: --new requires a name."
    echo "Usage: ralph --new <name>"
    exit 1
  fi

  local DIR="$PROJECT_ROOT/tasks/$RUN_NAME"
  if [ -d "$DIR" ]; then
    echo "Error: Run '$RUN_NAME' already exists at $DIR"
    exit 1
  fi

  mkdir -p "$DIR"

  # Create empty prd.json
  cat > "$DIR/prd.json" <<PRDEOF
{
  "project": "$(basename "$PROJECT_ROOT")",
  "branchName": "ralph/$RUN_NAME",
  "description": "",
  "userStories": []
}
PRDEOF

  # Create progress.txt
  {
    echo "# Ralph Progress Log"
    echo "Started: $(date)"
    echo "---"
  } > "$DIR/progress.txt"

  echo "Created run: $DIR"
  echo "  prd.json: $DIR/prd.json (empty — add stories)"
  echo "  progress: $DIR/progress.txt"
  echo ""
  echo "Next: edit prd.json, then run: ralph --run $RUN_NAME --tool claude 10"
}

# Handle commands
if [ "$CMD" = "list" ]; then
  cmd_list
  exit 0
fi

if [ "$CMD" = "new" ]; then
  cmd_new
  exit 0
fi

# ─── Resolve run dir for main loop ───────────────────────────────────

RUN_DIR=""
resolve_run_dir

PRD_FILE="$RUN_DIR/prd.json"
PROGRESS_FILE="$RUN_DIR/progress.txt"
ARCHIVE_DIR="$RUN_DIR/archive"

# Validate
if [ ! -f "$PRD_FILE" ]; then
  echo "Error: No prd.json found at $PRD_FILE"
  echo "  Create one with: ralph --new $(basename "$RUN_DIR")"
  exit 1
fi

REVIEW_FILE=".ralph-review.json"
STORY_FILE=".ralph-current-story"
LAST_REVIEWED_COMMIT_FILE=".ralph-last-reviewed-commit"

# ─── Initialize progress file ────────────────────────────────────────

if [ ! -f "$PROGRESS_FILE" ]; then
  echo "# Ralph Progress Log" > "$PROGRESS_FILE"
  echo "Started: $(date)" >> "$PROGRESS_FILE"
  echo "---" >> "$PROGRESS_FILE"
fi

# ─── Trim progress.txt: keep Codebase Patterns, trim old story logs ──
# Keeps the file small so agents don't waste context reading stale logs.
# Story logs older than the last 5 are moved to progress-archive.txt.
if [ -f "$PROGRESS_FILE" ]; then
  STORY_COUNT=$(grep -c '^## .*- US-' "$PROGRESS_FILE" 2>/dev/null) || true
  STORY_COUNT=${STORY_COUNT:-0}
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
    cat "$PROGRESS_FILE" >> "$RUN_DIR/progress-archive.txt"
    mv "$PROGRESS_FILE.trimmed" "$PROGRESS_FILE"
    echo "  Trimmed progress.txt (kept patterns + last 5 stories, archived full log)"
  fi
fi

# Temp file for capturing agent output (to check for COMPLETE signal)
AGENT_OUTPUT_FILE=$(mktemp /tmp/ralph-output.XXXXXX)
trap "rm -f '$AGENT_OUTPUT_FILE'" EXIT

# ─── Rate limit detection and retry ──────────────────────────────────

RATE_LIMIT_DELAYS=(300 900 1800)  # 5min, 15min, 30min — then repeats 30min

is_rate_limited() {
  local OUTPUT_FILE="$1"
  grep -qiE 'rate limit exceeded|rate_limit_exceeded|error.*429|status.*429|too many requests|usage limit exceeded' "$OUTPUT_FILE" 2>/dev/null
}

get_rate_limit_delay() {
  local RETRY="$1"
  local MAX_IDX=$(( ${#RATE_LIMIT_DELAYS[@]} - 1 ))
  local IDX=$(( RETRY < MAX_IDX ? RETRY : MAX_IDX ))
  echo "${RATE_LIMIT_DELAYS[$IDX]}"
}

wait_for_rate_limit() {
  local WHO="$1"   # "agent" or "reviewer"
  local RETRY="$2" # retry number (0-based)
  local DELAY
  DELAY=$(get_rate_limit_delay "$RETRY")
  local DELAY_MIN=$(( DELAY / 60 ))
  echo ""
  echo "  ⏸  Rate limit detected ($WHO). Retry $((RETRY + 1)), waiting ${DELAY_MIN}m..."
  sleep "$DELAY"
}

# ─── Helper: build prompt with Run Context header ────────────────────

build_prompt() {
  local PROMPT_FILE="$1"
  local REL_RUN
  REL_RUN=$(python3 -c "import os.path; print(os.path.relpath('$RUN_DIR', '$(pwd)'))" 2>/dev/null || echo "$RUN_DIR")

  {
    echo "# Run Context"
    echo "- PRD: $REL_RUN/prd.json"
    echo "- Progress: $REL_RUN/progress.txt"
    echo "- All file paths in prd.json are relative to project root: $(pwd)"
    echo "---"
    echo ""
    cat "$PROMPT_FILE"
  }
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
    build_prompt "$PROMPT_FILE" | amp --dangerously-allow-all 2>&1 | tee "$AGENT_OUTPUT_FILE" || true
  else
    build_prompt "$PROMPT_FILE" | claude ${MODEL:+--model "$MODEL"} --dangerously-skip-permissions --print 2>&1 | tee "$AGENT_OUTPUT_FILE" || true
  fi

  echo ""
}

# ─── Helper: run reviewer ────────────────────────────────────────────
# Sets REVIEW_VERDICT: "PASS", "NEEDS_FIX", or "CRASH"

REVIEW_VERDICT="UNKNOWN"

run_review() {
  echo "  [Review] Running $REVIEWER..."

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

  local RETRY=0
  while true; do
    if [[ "$REVIEWER" == "codex" ]]; then
      build_prompt "$RALPH_HOME/review-prompt.md" | codex exec \
        --full-auto \
        -C "$(pwd)" \
        > "$REVIEW_OUTPUT_FILE" 2>&1 || true
    else
      build_prompt "$RALPH_HOME/review-prompt.md" | claude --dangerously-skip-permissions --print \
        > "$REVIEW_OUTPUT_FILE" 2>&1 || true
    fi

    if ! is_rate_limited "$REVIEW_OUTPUT_FILE"; then
      break
    fi

    wait_for_rate_limit "reviewer" "$RETRY"
    RETRY=$((RETRY + 1))
    rm -f "$REVIEW_FILE"
  done

  # Check if reviewer produced the review file
  if [ ! -f "$REVIEW_FILE" ]; then
    echo "  WARNING: Reviewer crashed or did not produce $REVIEW_FILE."
    echo "  Last 20 lines of reviewer output:"
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

if [ "$DO_ENRICH" = true ] && [ -f "$RALPH_HOME/enrich-prompt.md" ]; then
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

    build_prompt "$RALPH_HOME/enrich-prompt.md" | \
      claude --model "$ENRICH_MODEL" --dangerously-skip-permissions --print 2>&1 || true

    echo ""
    echo "  Enrichment complete."
    echo ""
  else
    echo "  Enrichment: All stories already have code references. Skipping."
    echo ""
  fi
fi

# ─── Main loop ────────────────────────────────────────────────────────

REL_RUN=$(python3 -c "import os.path; print(os.path.relpath('$RUN_DIR', '$(pwd)'))" 2>/dev/null || basename "$RUN_DIR")

echo "Starting Ralph v$RALPH_VERSION"
echo "  Run: $REL_RUN"
echo "  Tool: $TOOL${MODEL:+ ($MODEL)} | Reviewer: $REVIEWER"
echo "  Max iterations: $MAX_ITERATIONS | Max review rounds: $MAX_REVIEW_ROUNDS"
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
  echo "  Story Iteration $i of $MAX_ITERATIONS ($REMAINING stories remaining)"
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

    run_agent "$RALPH_HOME/CLAUDE.md" "Implement"

    # Retry on rate limit (progressive delays: 5m, 15m, 30m, 30m...)
    AGENT_RETRY=0
    while is_rate_limited "$AGENT_OUTPUT_FILE"; do
      wait_for_rate_limit "agent" "$AGENT_RETRY"
      AGENT_RETRY=$((AGENT_RETRY + 1))
      run_agent "$RALPH_HOME/CLAUDE.md" "Implement"
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

    # Run reviewer
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
