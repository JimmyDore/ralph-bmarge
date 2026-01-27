#!/bin/bash
# ralph-bmarge - "Ralph, be Marge!"
# Fork of Ralph adapted for BMAD Method workflows
# Original: https://github.com/snarktank/ralph
#
# Features:
# - File-based status detection (watches sprint-status.yaml)
# - Session management with --session-id / --resume
# - Auto-responds "1" (Yes) to permission prompts via expect

set -e

# Cleanup temp files on exit
trap 'rm -f /tmp/ralph-prompt.* /tmp/ralph-stats.* /tmp/ralph-output.* /tmp/ralph-fixer.* 2>/dev/null' EXIT

# Configuration
DRY_RUN=false
VALIDATE_MODE=false
DEBUG_MODE=false
INFINITE_MODE=true
MAX_ITERATIONS=0
MAX_CONTINUES=0
MAX_STALE_CONTINUES=10  # Safety: abort if status unchanged after N continues
RATE_LIMIT_WAIT=600     # Wait time in seconds when rate limited (default: 10 min)
MAX_RATE_LIMIT_RETRIES=5  # Max retries on rate limit before giving up
WEBHOOK_URL=""
NOTIFY_SOUND=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load .env file if it exists (PROJECT_ROOT/.env or SCRIPT_DIR/.env)
load_env() {
    local env_file=""
    if [ -f "$PROJECT_ROOT/.env" ]; then
        env_file="$PROJECT_ROOT/.env"
    elif [ -f "$SCRIPT_DIR/.env" ]; then
        env_file="$SCRIPT_DIR/.env"
    fi

    if [ -n "$env_file" ]; then
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^#.*$ ]] && continue
            [[ -z "$key" ]] && continue
            value=$(echo "$value" | sed 's/^["'"'"']//;s/["'"'"']$//')
            export "$key=$value"
        done < "$env_file"
    fi
}
load_env

# Set webhook from env if not already set via CLI
[ -z "$WEBHOOK_URL" ] && WEBHOOK_URL="${SLACK_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}"

# Stats tracking
TOTAL_COST=0
TOTAL_TIME=0
STORIES_COMPLETED=0
SPRINT_START_TIME=$(date +%s)
declare -a STORY_STATS=()  # Array to store per-story stats

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --validate|-v)
            VALIDATE_MODE=true
            shift
            ;;
        --debug|-d)
            DEBUG_MODE=true
            shift
            ;;
        --max-iterations)
            INFINITE_MODE=false
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --max-continues)
            MAX_CONTINUES="$2"
            shift 2
            ;;
        --max-stale)
            MAX_STALE_CONTINUES="$2"
            shift 2
            ;;
        --rate-limit-wait)
            RATE_LIMIT_WAIT="$2"
            shift 2
            ;;
        --webhook)
            WEBHOOK_URL="$2"
            shift 2
            ;;
        --notify-sound)
            NOTIFY_SOUND=true
            shift
            ;;
        --test-claude)
            # Quick test to see if Claude runs correctly with streaming
            echo "╔═══════════════════════════════════════════════════════════════╗"
            echo "║           Ralph-BMAD - Claude Streaming Test                  ║"
            echo "╚═══════════════════════════════════════════════════════════════╝"
            echo ""
            echo "Testing Claude with --output-format stream-json --verbose..."
            echo ""

            echo "[TEST] Command: echo 'Say hello' | claude --print --output-format stream-json --verbose"
            echo ""
            echo "═══════════════════════════════════════════════════════════════"

            echo "Say hello" | IS_SANDBOX=1 claude --dangerously-skip-permissions --print --output-format stream-json --verbose 2>&1 | while IFS= read -r line; do
                msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)
                case "$msg_type" in
                    "system")
                        echo -e "\033[0;36m[STREAM] System initialized\033[0m"
                        ;;
                    "assistant")
                        text=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text // empty' 2>/dev/null)
                        [ -n "$text" ] && echo -e "\033[0;32m[ASSISTANT] $text\033[0m"
                        ;;
                    "result")
                        duration=$(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null)
                        echo -e "\033[0;36m[RESULT] Finished in ${duration}ms\033[0m"
                        ;;
                esac
            done

            echo ""
            echo "═══════════════════════════════════════════════════════════════"
            echo "[TEST] Test complete - streaming works!"
            exit 0
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [MAX_ITERATIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run, -n          Simulation mode (no Claude calls)"
            echo "  --validate, -v         Validate story detection and exit"
            echo "  --debug, -d            Debug mode: full visibility (prompts, output, timing)"
            echo "  --max-iterations N     Limit to N story iterations (default: infinite)"
            echo "  --max-continues N      Limit resume attempts per workflow (default: infinite)"
            echo "  --max-stale N          Abort if status unchanged after N continues (default: 10)"
            echo "  --rate-limit-wait N    Seconds to wait on rate limit (default: 600 = 10 min)"
            echo "  --webhook URL          Send notifications to Slack/Discord webhook"
            echo "  --notify-sound         Play sound when sprint completes (macOS)"
            echo "  --test-claude          Test Claude execution (diagnose prompt handling)"
            echo "  --help, -h             Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                              Run until all stories complete (default)"
            echo "  $0 --max-iterations 5          Run max 5 stories then stop"
            echo "  $0 --webhook https://hooks...  Send notifications to Slack/Discord"
            echo "  $0 --debug --notify-sound      Debug mode with sound notification"
            echo "  $0 --validate                  Check story detection"
            exit 0
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                INFINITE_MODE=false
                MAX_ITERATIONS="$1"
            fi
            shift
            ;;
    esac
done

# BMAD paths (customizable - default matches bmad/bmm/config.yaml)
# Override with: BMAD_ARTIFACTS_DIR=/custom/path ./ralph-bmarge.sh
ARTIFACTS_DIR="${BMAD_ARTIFACTS_DIR:-$PROJECT_ROOT/docs/implementation-artifacts}"
SPRINT_STATUS="$ARTIFACTS_DIR/sprint-status.yaml"
STORIES_DIR="$ARTIFACTS_DIR"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
ARCHIVE_DIR="$SCRIPT_DIR/archive"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ═══════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════

check_dependencies() {
    if ! command -v claude &> /dev/null; then
        echo -e "${RED}Error: Claude Code CLI not found.${NC}"
        exit 1
    fi
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}Error: jq not found. Install with: brew install jq${NC}"
        exit 1
    fi
    if [ ! -f "$SPRINT_STATUS" ]; then
        echo -e "${RED}Error: sprint-status.yaml not found${NC}"
        exit 1
    fi
}

# Extract status from a line, handling comments and quotes
# Input: "  1-1-story: ready-for-dev  # comment"
# Output: "ready-for-dev"
extract_status() {
    echo "$1" | sed 's/.*: *//' | sed 's/ *#.*//' | sed 's/^["'"'"']//' | sed 's/["'"'"']$//' | tr -d ' '
}

# Extract story key from a line
# Input: "  1-1-story: ready-for-dev"
# Output: "1-1-story"
extract_story_key() {
    echo "$1" | sed 's/:.*//' | tr -d ' '
}

get_story_status() {
    local story_key=$1
    local line=$(grep -E "^[[:space:]]+${story_key}:" "$SPRINT_STATUS" 2>/dev/null | head -1)
    [ -z "$line" ] && return
    extract_status "$line"
}

get_next_story() {
    local line
    local story

    # Priority 1: in-progress (FINISH what was started first!)
    line=$(grep -E "^[[:space:]]+[0-9]+-[0-9]+-[^:]+:[[:space:]]*(in-progress|\"in-progress\")" "$SPRINT_STATUS" 2>/dev/null | head -1)

    # Priority 2: review (complete the review phase)
    [ -z "$line" ] && line=$(grep -E "^[[:space:]]+[0-9]+-[0-9]+-[^:]+:[[:space:]]*(review|\"review\")" "$SPRINT_STATUS" 2>/dev/null | head -1)

    # Priority 3: ready-for-dev (start new work only if nothing pending)
    [ -z "$line" ] && line=$(grep -E "^[[:space:]]+[0-9]+-[0-9]+-[^:]+:[[:space:]]*(ready-for-dev|\"ready-for-dev\")" "$SPRINT_STATUS" 2>/dev/null | head -1)

    [ -z "$line" ] && return
    extract_story_key "$line"
}

count_remaining() {
    grep -E "^[[:space:]]+[0-9]+-[0-9]+-[^:]+:[[:space:]]*(ready-for-dev|in-progress|review)" "$SPRINT_STATUS" 2>/dev/null | wc -l | tr -d ' '
}

# Get next story in backlog (for auto-creation)
get_next_backlog_story() {
    local line
    line=$(grep -E "^[[:space:]]+[0-9]+-[0-9]+-[^:]+:[[:space:]]*(backlog|\"backlog\")" "$SPRINT_STATUS" 2>/dev/null | head -1)
    [ -z "$line" ] && return
    extract_story_key "$line"
}

# Count stories in backlog
count_backlog() {
    grep -E "^[[:space:]]+[0-9]+-[0-9]+-[^:]+:[[:space:]]*(backlog|\"backlog\")" "$SPRINT_STATUS" 2>/dev/null | wc -l | tr -d ' '
}

# Extract epic number from story key (e.g., "3-2-feature" -> "3")
get_epic_from_story() {
    echo "$1" | cut -d'-' -f1
}

# Find similar story key (handles renamed keys)
# Input: "17-1-crewai-setup-on-modal"
# Looks for keys starting with same epic-story prefix (e.g., "17-1-")
find_similar_story_key() {
    local story_key=$1
    local prefix=$(echo "$story_key" | grep -oE '^[0-9]+-[0-9]+-')
    [ -z "$prefix" ] && return

    # Find any key with same prefix that has status done/review
    local similar=$(grep -E "^[[:space:]]+${prefix}[^:]+:[[:space:]]*(done|review)" "$SPRINT_STATUS" 2>/dev/null | head -1)
    [ -z "$similar" ] && return

    extract_story_key "$similar"
}

# Check if a story key was renamed (original missing, similar exists with done status)
detect_renamed_key() {
    local original_key=$1
    local expected_status=$2

    # If original key exists, no rename detected
    local current=$(get_story_status "$original_key")
    [ -n "$current" ] && return 1

    # Look for similar key with expected status
    local similar_key=$(find_similar_story_key "$original_key")
    [ -z "$similar_key" ] && return 1

    local similar_status=$(get_story_status "$similar_key")
    if [ "$similar_status" = "$expected_status" ] || [ "$similar_status" = "done" ]; then
        echo "$similar_key"
        return 0
    fi
    return 1
}

# Check if all stories in an epic are done
is_epic_complete() {
    local epic_num=$1
    local pending=$(grep -E "^[[:space:]]+${epic_num}-[0-9]+-[^:]+:[[:space:]]*(ready-for-dev|in-progress|review)" "$SPRINT_STATUS" 2>/dev/null | wc -l | tr -d ' ')
    [ "$pending" -eq 0 ]
}

# Get epic status
get_epic_status() {
    local epic_num=$1
    local line=$(grep -E "^[[:space:]]+epic-${epic_num}:" "$SPRINT_STATUS" 2>/dev/null | head -1)
    [ -z "$line" ] && return
    extract_status "$line"
}

archive_previous() {
    if [ -f "$PROGRESS_FILE" ] && [ -s "$PROGRESS_FILE" ]; then
        mkdir -p "$ARCHIVE_DIR"
        cp "$PROGRESS_FILE" "$ARCHIVE_DIR/progress-$(date +%Y-%m-%d-%H%M).txt"
    fi
}

init_progress() {
    cat > "$PROGRESS_FILE" << 'EOF'
# Ralph-BMAD Progress Log
## Iteration Log
EOF
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
}

# Generate UUID for session
new_session_id() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

# ═══════════════════════════════════════════════════════════════
# NOTIFICATIONS & REPORTING
# ═══════════════════════════════════════════════════════════════

# Send webhook notification (Slack/Discord compatible)
send_webhook() {
    local message="$1"
    local title="${2:-Ralph-BMAD}"

    [ -z "$WEBHOOK_URL" ] && return 0

    # Format for both Slack and Discord
    local payload=$(cat <<EOF
{
    "content": "$message",
    "text": "$message",
    "username": "Ralph-BMAD",
    "embeds": [{"title": "$title", "description": "$message", "color": 5814783}]
}
EOF
)

    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL" > /dev/null 2>&1 || true
}

# Play notification sound (macOS)
play_notification_sound() {
    [ "$NOTIFY_SOUND" != true ] && return 0

    # Try macOS sounds
    if command -v afplay &> /dev/null; then
        afplay /System/Library/Sounds/Glass.aiff 2>/dev/null &
    # Try Linux sounds
    elif command -v paplay &> /dev/null; then
        paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null &
    fi
}

# Format duration in human readable format
format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))

    if [ $hours -gt 0 ]; then
        echo "${hours}h ${minutes}m ${secs}s"
    elif [ $minutes -gt 0 ]; then
        echo "${minutes}m ${secs}s"
    else
        echo "${secs}s"
    fi
}

# Add story stats to tracking array
track_story_stats() {
    local story_key="$1"
    local duration="$2"
    local cost="$3"
    local status="$4"

    STORY_STATS+=("$story_key|$duration|$cost|$status")
    TOTAL_TIME=$((TOTAL_TIME + duration))
    TOTAL_COST=$(echo "$TOTAL_COST + $cost" | bc 2>/dev/null || echo "$TOTAL_COST")
    if [ "$status" = "done" ]; then
        STORIES_COMPLETED=$((STORIES_COMPLETED + 1))
    fi
}

# Generate sprint report markdown
generate_sprint_report() {
    local report_file="$SCRIPT_DIR/sprint-report-$(date +%Y-%m-%d-%H%M).md"
    local sprint_end_time=$(date +%s)
    local sprint_duration=$((sprint_end_time - SPRINT_START_TIME))

    cat > "$report_file" << EOF
# Ralph-BMAD Sprint Report

**Generated:** $(date)
**Duration:** $(format_duration $sprint_duration)

## Summary

| Metric | Value |
|--------|-------|
| Stories Completed | $STORIES_COMPLETED |
| Total Time | $(format_duration $TOTAL_TIME) |
| Total Cost | \$$(printf "%.2f" $TOTAL_COST) |
| Average per Story | $([ $STORIES_COMPLETED -gt 0 ] && echo "\$$(printf "%.2f" $(echo "$TOTAL_COST / $STORIES_COMPLETED" | bc -l 2>/dev/null || echo "0"))" || echo "N/A") |

## Stories Processed

| Story | Duration | Cost | Status |
|-------|----------|------|--------|
EOF

    # Add each story to the report
    for stat in "${STORY_STATS[@]}"; do
        IFS='|' read -r story duration cost status <<< "$stat"
        echo "| $story | $(format_duration $duration) | \$$(printf "%.2f" $cost) | $status |" >> "$report_file"
    done

    cat >> "$report_file" << EOF

## Configuration

- Mode: $([ "$INFINITE_MODE" = true ] && echo "Infinite" || echo "Limited ($MAX_ITERATIONS iterations)")
- Webhook: $([ -n "$WEBHOOK_URL" ] && echo "Enabled" || echo "Disabled")
- Sound: $([ "$NOTIFY_SOUND" = true ] && echo "Enabled" || echo "Disabled")

---
*Generated by [Ralph-BMAD](https://github.com/YOUR_USERNAME/ralph-bmad)*
EOF

    echo "$report_file"
}

# Print final stats summary
print_stats_summary() {
    local sprint_end_time=$(date +%s)
    local sprint_duration=$((sprint_end_time - SPRINT_START_TIME))

    echo ""
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                      SPRINT STATISTICS                        ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  Stories Completed:  ${GREEN}$STORIES_COMPLETED${NC}"
    echo -e "${CYAN}║${NC}  Total Duration:     ${GREEN}$(format_duration $sprint_duration)${NC}"
    echo -e "${CYAN}║${NC}  Claude Time:        ${GREEN}$(format_duration $TOTAL_TIME)${NC}"
    echo -e "${CYAN}║${NC}  Total Cost:         ${GREEN}\$$(printf "%.2f" $TOTAL_COST)${NC}"
    if [ $STORIES_COMPLETED -gt 0 ]; then
        local avg_cost=$(echo "$TOTAL_COST / $STORIES_COMPLETED" | bc -l 2>/dev/null || echo "0")
        local avg_time=$((TOTAL_TIME / STORIES_COMPLETED))
        echo -e "${CYAN}║${NC}  Avg Cost/Story:     ${GREEN}\$$(printf "%.2f" $avg_cost)${NC}"
        echo -e "${CYAN}║${NC}  Avg Time/Story:     ${GREEN}$(format_duration $avg_time)${NC}"
    fi
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
}

# ═══════════════════════════════════════════════════════════════
# CORE: Run Claude with --print mode (pipe-based, like original Ralph)
# ═══════════════════════════════════════════════════════════════

# Global vars for capturing stats from subshell
LAST_RUN_COST=0
LAST_RUN_DURATION=0
LAST_RUN_RATE_LIMITED=false

# Check if output indicates rate limiting
is_rate_limited() {
    local output="$1"
    local exit_code="$2"

    # If exit code is 0 and we see success in output, NOT rate limited
    if [ "$exit_code" -eq 0 ] && echo "$output" | grep -q '"subtype":"success"'; then
        return 1
    fi

    # Check for specific rate limit error patterns (more strict matching)
    # - "rate limit" as phrase (not just "rate" anywhere)
    # - "429" with error context
    # - "overloaded" as API error
    if echo "$output" | grep -qiE "rate[ _-]?limit|error.*429|429.*error|too many requests|quota exceeded|overloaded_error|capacity"; then
        return 0
    fi

    # Exit code non-zero with API error indicators
    if [ "$exit_code" -ne 0 ] && echo "$output" | grep -qiE "api.*(error|failed)|error.*api|request failed"; then
        return 0
    fi

    return 1
}

# Format seconds into human-readable wait time
format_wait_time() {
    local seconds=$1
    local mins=$((seconds / 60))
    local secs=$((seconds % 60))
    if [ $mins -gt 0 ]; then
        echo "${mins}m ${secs}s"
    else
        echo "${secs}s"
    fi
}

run_claude_expect() {
    local prompt="$1"
    local session_id="$2"
    local is_resume="$3"

    echo -e "${YELLOW}[TRACE] >>> Entering run_claude_expect${NC}"
    echo -e "${YELLOW}[TRACE] Creating temp file...${NC}"

    # Create temp file for prompt (like original Ralph uses CLAUDE.md)
    local prompt_file=$(mktemp /tmp/ralph-prompt.XXXXXX)
    local stats_file=$(mktemp /tmp/ralph-stats.XXXXXX)
    local output_file=$(mktemp /tmp/ralph-output.XXXXXX)
    echo "$prompt" > "$prompt_file"
    echo "0|0" > "$stats_file"
    LAST_RUN_RATE_LIMITED=false

    echo -e "${YELLOW}[TRACE] Temp file created: $prompt_file${NC}"
    echo -e "${YELLOW}[TRACE] File size: $(wc -c < "$prompt_file") bytes${NC}"

    local start_time=$(date +%s)

    if [ "$DEBUG_MODE" = true ]; then
        echo ""
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║                    DEBUG MODE - Full Visibility               ║${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo -e "${YELLOW}[DEBUG] Session ID: $session_id${NC}"
        echo -e "${YELLOW}[DEBUG] Is Resume: $is_resume${NC}"
        echo -e "${YELLOW}[DEBUG] Prompt file: $prompt_file${NC}"
        echo -e "${YELLOW}[DEBUG] Timestamp: $(date)${NC}"
        echo ""
        echo -e "${CYAN}[DEBUG] ═══ FULL PROMPT ═══${NC}"
        echo -e "${GREEN}$prompt${NC}"
        echo -e "${CYAN}[DEBUG] ═══ END PROMPT ═══${NC}"
        echo ""
    fi

    # Build session argument
    local session_arg=""
    if [ "$is_resume" = "true" ]; then
        session_arg="--resume $session_id"
    else
        session_arg="--session-id $session_id"
    fi

    echo -e "${YELLOW}[TRACE] Session arg: $session_arg${NC}"

    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${CYAN}[DEBUG] Command: IS_SANDBOX=1 claude --dangerously-skip-permissions --print $session_arg < $prompt_file${NC}"
        echo -e "${CYAN}[DEBUG] ═══ CLAUDE OUTPUT START ═══${NC}"
    fi

    echo -e "${YELLOW}[TRACE] >>> About to run Claude...${NC}"
    echo -e "${YELLOW}[TRACE] >>> $(date)${NC}"

    # Build the full command for logging
    local full_cmd="IS_SANDBOX=1 claude --dangerously-skip-permissions --print $session_arg"
    echo -e "${YELLOW}[TRACE] Full command: $full_cmd < $prompt_file${NC}"
    echo -e "${YELLOW}[TRACE] Prompt content preview: ${prompt:0:100}...${NC}"

    local exit_code=0

    # Use stream-json for real-time output visibility
    echo -e "${YELLOW}[TRACE] Running Claude with stream-json...${NC}"

    # Run Claude with streaming JSON output, parse and display in real-time
    # --output-format stream-json --verbose gives us line-by-line JSON we can parse
    # Also capture raw output for rate limit detection
    IS_SANDBOX=1 claude --dangerously-skip-permissions --print --output-format stream-json --verbose $session_arg < "$prompt_file" 2>&1 | tee "$output_file" | while IFS= read -r line; do
        # Try to extract and display assistant messages
        local msg_type=$(echo "$line" | jq -r '.type // empty' 2>/dev/null)

        case "$msg_type" in
            "system")
                if [ "$DEBUG_MODE" = true ]; then
                    echo -e "${CYAN}[STREAM] System init${NC}"
                fi
                ;;
            "assistant")
                # Extract text content from assistant message
                local text=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text // empty' 2>/dev/null)
                if [ -n "$text" ]; then
                    echo -e "${GREEN}$text${NC}"
                fi
                # Check for tool use
                local tool=$(echo "$line" | jq -r '.message.content[]? | select(.type=="tool_use") | .name // empty' 2>/dev/null)
                if [ -n "$tool" ]; then
                    echo -e "${YELLOW}[TOOL] $tool${NC}"
                fi
                ;;
            "user")
                if [ "$DEBUG_MODE" = true ]; then
                    echo -e "${BLUE}[USER] Tool result${NC}"
                fi
                ;;
            "result")
                local success=$(echo "$line" | jq -r '.subtype // empty' 2>/dev/null)
                local duration_ms=$(echo "$line" | jq -r '.duration_ms // 0' 2>/dev/null)
                local cost=$(echo "$line" | jq -r '.total_cost_usd // 0' 2>/dev/null)
                echo -e "${CYAN}[DONE] Status: $success, Duration: ${duration_ms}ms, Cost: \$${cost}${NC}"
                # Save stats to temp file (accessible outside subshell)
                echo "${duration_ms}|${cost}" > "$stats_file"
                ;;
        esac
    done || true
    exit_code=${PIPESTATUS[0]}

    echo -e "${YELLOW}[TRACE] Stream finished (exit: $exit_code)${NC}"

    echo -e "${YELLOW}[TRACE] <<< Claude finished${NC}"
    echo -e "${YELLOW}[TRACE] <<< $(date)${NC}"

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Read stats from temp file
    if [ -f "$stats_file" ]; then
        IFS='|' read -r captured_duration captured_cost < "$stats_file"
        LAST_RUN_DURATION=$((captured_duration / 1000))  # Convert ms to seconds
        LAST_RUN_COST=${captured_cost:-0}
    fi

    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${CYAN}[DEBUG] ═══ CLAUDE OUTPUT END ═══${NC}"
        echo ""
        echo -e "${YELLOW}[DEBUG] Exit code: $exit_code${NC}"
        echo -e "${YELLOW}[DEBUG] Duration: ${duration}s${NC}"
        echo -e "${YELLOW}[DEBUG] Captured cost: \$${LAST_RUN_COST}${NC}"
        echo -e "${YELLOW}[DEBUG] Timestamp: $(date)${NC}"
        echo ""
    fi

    echo -e "${GREEN}>>> Claude terminé (exit: $exit_code, ${duration}s, \$${LAST_RUN_COST})${NC}"

    # Check for rate limiting in output
    if [ -f "$output_file" ]; then
        local output_content=$(cat "$output_file")
        if is_rate_limited "$output_content" "$exit_code"; then
            LAST_RUN_RATE_LIMITED=true
            echo -e "${RED}>>> Rate limit detected in Claude response${NC}"
        fi
    fi

    # Cleanup
    rm -f "$prompt_file" "$stats_file" "$output_file"

    return $exit_code
}

# Wrapper that handles rate limit retries
run_claude_with_retry() {
    local prompt="$1"
    local session_id="$2"
    local is_resume="$3"
    local retry_count=0

    while [ $retry_count -lt $MAX_RATE_LIMIT_RETRIES ]; do
        run_claude_expect "$prompt" "$session_id" "$is_resume"
        local result=$?

        if [ "$LAST_RUN_RATE_LIMITED" = true ]; then
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $MAX_RATE_LIMIT_RETRIES ]; then
                echo ""
                echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${YELLOW}║  ⏳ RATE LIMITED - Waiting before retry                       ║${NC}"
                echo -e "${YELLOW}╠═══════════════════════════════════════════════════════════════╣${NC}"
                echo -e "${YELLOW}║  Retry: $retry_count / $MAX_RATE_LIMIT_RETRIES${NC}"
                echo -e "${YELLOW}║  Wait time: $(format_wait_time $RATE_LIMIT_WAIT)${NC}"
                echo -e "${YELLOW}║  Will resume at: $(date -d "+${RATE_LIMIT_WAIT} seconds" 2>/dev/null || date -v+${RATE_LIMIT_WAIT}S 2>/dev/null || echo "in ${RATE_LIMIT_WAIT}s")${NC}"
                echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
                echo ""

                # Send webhook notification
                send_webhook "⏳ Rate limited on session $session_id. Waiting $(format_wait_time $RATE_LIMIT_WAIT) before retry ($retry_count/$MAX_RATE_LIMIT_RETRIES)" "Rate Limit"

                # Wait with countdown (show progress every minute for long waits)
                local remaining=$RATE_LIMIT_WAIT
                while [ $remaining -gt 0 ]; do
                    if [ $remaining -gt 60 ] && [ $((remaining % 60)) -eq 0 ]; then
                        echo -e "${YELLOW}>>> $(format_wait_time $remaining) remaining...${NC}"
                    fi
                    sleep 1
                    remaining=$((remaining - 1))
                done

                echo -e "${GREEN}>>> Resuming after rate limit wait...${NC}"
            else
                echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${RED}║  ❌ MAX RATE LIMIT RETRIES EXCEEDED                           ║${NC}"
                echo -e "${RED}╠═══════════════════════════════════════════════════════════════╣${NC}"
                echo -e "${RED}║  Tried $MAX_RATE_LIMIT_RETRIES times, still rate limited.${NC}"
                echo -e "${RED}║  Manual intervention required.                                ║${NC}"
                echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
                send_webhook "🚨 Max rate limit retries ($MAX_RATE_LIMIT_RETRIES) exceeded on session $session_id. Manual intervention needed." "Rate Limit Alert"
                return 1
            fi
        else
            # No rate limit, return result
            return $result
        fi
    done

    return 1
}

# ═══════════════════════════════════════════════════════════════
# WORKFLOW: Auto-create story from backlog
# ═══════════════════════════════════════════════════════════════

create_next_story() {
    local backlog_story=$1
    local session_id=$(new_session_id)

    echo ""
    echo -e "${MAGENTA}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  📝 AUTO-CREATE STORY                                         ║${NC}"
    echo -e "${MAGENTA}╠═══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${MAGENTA}║  Next backlog story: $backlog_story${NC}"
    echo -e "${MAGENTA}║  Running /bmad_bmm_create-story...                            ║${NC}"
    echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would run /bmad_bmm_create-story for $backlog_story${NC}"
        return 0
    fi

    local prompt="Execute /bmad_bmm_create-story to create the next story from backlog. The next story should be: $backlog_story. IMPORTANT: Work 100% autonomously - do NOT ask questions, do NOT wait for confirmation, make all decisions yourself. Create the story file and update sprint-status.yaml to mark it as ready-for-dev."

    run_claude_with_retry "$prompt" "$session_id" ""
    local result=$?

    # Verify story was created
    local new_status=$(get_story_status "$backlog_story")
    if [ "$new_status" = "ready-for-dev" ]; then
        echo -e "${GREEN}>>> Story $backlog_story created and ready for dev${NC}"
        send_webhook "📝 Story created: $backlog_story (ready-for-dev)" "Story Created"
        return 0
    else
        echo -e "${YELLOW}>>> Story creation may have renamed the key, checking...${NC}"
        # The create-story workflow might have renamed the story key
        # Check if any new ready-for-dev story appeared
        local new_ready=$(get_next_story)
        if [ -n "$new_ready" ]; then
            echo -e "${GREEN}>>> Found ready story: $new_ready${NC}"
            return 0
        fi
        echo -e "${RED}>>> Story creation failed or status not updated${NC}"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# WORKFLOW: Run dev-story or code-review with watchdog
# ═══════════════════════════════════════════════════════════════

run_workflow() {
    local story_key=$1
    local workflow=$2  # "dev-story" or "code-review"
    local expected_status=$3  # "review" or "done"
    local continue_count=0

    local story_file="$STORIES_DIR/${story_key}.md"
    local session_id=$(new_session_id)

    echo -e "${CYAN}┌─────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  $workflow: $story_key${NC}"
    echo -e "${CYAN}│  Session: $session_id${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────┘${NC}"

    if [ ! -f "$story_file" ]; then
        echo -e "${YELLOW}Warning: Story file not found: $story_file${NC}"
    fi

    local last_status=""
    local stale_count=0

    while [ $MAX_CONTINUES -eq 0 ] || [ $continue_count -lt $MAX_CONTINUES ]; do
        local current_status=$(get_story_status "$story_key")

        # Check if done
        if [ "$current_status" = "$expected_status" ] || [ "$current_status" = "done" ]; then
            echo -e "${GREEN}Story reached status: $current_status${NC}"
            return 0
        fi

        # Build prompt
        local prompt
        local is_resume=""
        if [ $continue_count -eq 0 ]; then
            prompt="Execute /bmad:bmm:workflows:$workflow for story: $story_key. Story file: $story_file. IMPORTANT: Work 100% autonomously - do NOT ask questions, do NOT wait for confirmation, make all decisions yourself. Continue until story status is $expected_status."
        else
            prompt="continue"
            is_resume="true"
        fi

        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY-RUN] Would run:${NC}"
            echo "  Session: $session_id (resume: $is_resume)"
            echo "  Prompt: ${prompt:0:60}..."
            echo "  Expected status: $expected_status"
            return 0
        fi

        echo -e "${BLUE}>>> ${is_resume:+RESUME }Launching Claude...${NC}"
        run_claude_with_retry "$prompt" "$session_id" "$is_resume"

        # Check status after Claude stops
        local new_status=$(get_story_status "$story_key")
        echo -e "${BLUE}>>> Status: $new_status (expected: $expected_status)${NC}"

        if [ "$new_status" = "$expected_status" ] || [ "$new_status" = "done" ]; then
            echo -e "${GREEN}Story reached status: $new_status${NC}"
            return 0
        fi

        # SAFETY: Detect stuck loop (status not changing)
        if [ "$new_status" = "$last_status" ]; then
            stale_count=$((stale_count + 1))
            if [ $stale_count -ge $MAX_STALE_CONTINUES ]; then
                echo ""
                echo -e "${MAGENTA}╔═══════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${MAGENTA}║  🔧 STUCK LOOP DETECTED - Launching FIXER Agent               ║${NC}"
                echo -e "${MAGENTA}╠═══════════════════════════════════════════════════════════════╣${NC}"
                echo -e "${MAGENTA}║  Story: $story_key${NC}"
                echo -e "${MAGENTA}║  Current: $new_status | Expected: $expected_status${NC}"
                echo -e "${MAGENTA}║  Attempts: $stale_count - Invoking AI-in-the-loop repair...   ║${NC}"
                echo -e "${MAGENTA}╚═══════════════════════════════════════════════════════════════╝${NC}"
                echo ""

                # Check for renamed key BEFORE calling FIXER
                local renamed_key=$(detect_renamed_key "$story_key" "$expected_status")
                if [ -n "$renamed_key" ]; then
                    echo -e "${YELLOW}[AUTO-FIX] Detected renamed key: $story_key → $renamed_key${NC}"
                    echo -e "${YELLOW}[AUTO-FIX] Adding alias to YAML...${NC}"

                    # Add the original key as an alias pointing to done
                    # Find the renamed key line and add alias after it
                    local renamed_line_num=$(grep -n "^[[:space:]]*${renamed_key}:" "$SPRINT_STATUS" | head -1 | cut -d: -f1)
                    if [ -n "$renamed_line_num" ]; then
                        sed -i '' "${renamed_line_num}a\\
  ${story_key}: ${expected_status}  # auto-alias for renamed key
" "$SPRINT_STATUS"
                        echo -e "${GREEN}[AUTO-FIX] Added alias: ${story_key}: ${expected_status}${NC}"

                        # Verify fix worked
                        local auto_fixed_status=$(get_story_status "$story_key")
                        if [ "$auto_fixed_status" = "$expected_status" ]; then
                            echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
                            echo -e "${GREEN}║  ✅ AUTO-FIX SUCCEEDED - Key rename detected and fixed!       ║${NC}"
                            echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
                            send_webhook "🔧 AUTO-FIXED: $story_key - Renamed key detected ($renamed_key), alias added" "Ralph-BMAD"
                            stale_count=0
                            last_status="$auto_fixed_status"
                            continue
                        fi
                    fi
                fi

                # Build fixer prompt with full context
                local fixer_prompt="URGENT: Story '$story_key' is STUCK in an infinite loop.

SITUATION:
- Sprint status file: $SPRINT_STATUS
- Story file: $story_file
- Current YAML status: '$new_status' (empty means key not found!)
- Expected status: $expected_status
- The previous Claude session reported the work as complete, but the YAML file was NOT updated correctly.

CRITICAL: If '$new_status' is EMPTY, the key '$story_key' may have been RENAMED during the workflow!
Check if a similar key exists (same epic-story prefix like '$(echo $story_key | grep -oE "^[0-9]+-[0-9]+-")') with status 'done'.

YOUR MISSION (Fixer Agent):
1. Read sprint-status.yaml and look for the EXACT key '$story_key'
2. If key is MISSING: search for similar keys with same prefix, then ADD the missing key: '$story_key: $expected_status'
3. If key EXISTS but wrong status: UPDATE it to '$expected_status'
4. Use the Edit tool to modify the YAML file

IMPORTANT: The script checks for EXACTLY '$story_key' - you MUST ensure this exact key exists with status '$expected_status'.
Do NOT just report that a similar key exists - you must ADD or FIX the exact key!
Do NOT ask questions - act autonomously to fix this stuck state."

                echo -e "${MAGENTA}>>> FIXER Agent starting...${NC}"

                # Run fixer in new session (fresh context)
                local fixer_session=$(uuidgen | tr '[:upper:]' '[:lower:]')
                local fixer_temp=$(mktemp /tmp/ralph-fixer.XXXXXX)
                echo "$fixer_prompt" > "$fixer_temp"

                if [ "$DEBUG_MODE" = true ]; then
                    echo -e "${CYAN}[FIXER] Session: $fixer_session${NC}"
                    echo -e "${CYAN}[FIXER] Prompt: ${fixer_prompt:0:100}...${NC}"
                fi

                IS_SANDBOX=1 claude --dangerously-skip-permissions --print --session-id "$fixer_session" < "$fixer_temp" 2>&1 | while IFS= read -r line; do
                    echo -e "${MAGENTA}[FIXER] $line${NC}"
                done

                rm -f "$fixer_temp"

                # Check if fixer succeeded
                local fixed_status=$(get_story_status "$story_key")
                echo ""
                echo -e "${BLUE}>>> Post-fixer status: $fixed_status (expected: $expected_status)${NC}"

                if [ "$fixed_status" = "$expected_status" ] || [ "$fixed_status" = "done" ]; then
                    echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
                    echo -e "${GREEN}║  ✅ FIXER Agent SUCCEEDED - Loop unblocked!                   ║${NC}"
                    echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
                    send_webhook "🔧 FIXED: $story_key - Fixer agent unblocked stuck loop (was: $new_status → now: $fixed_status)" "Ralph-BMAD"
                    stale_count=0
                    last_status="$fixed_status"
                    # Continue the main loop - don't return, let it proceed naturally
                else
                    # LAST RESORT: Try brute-force auto-fix for renamed keys
                    echo -e "${YELLOW}[LAST-RESORT] FIXER failed, attempting brute-force fix...${NC}"

                    local fallback_renamed=$(find_similar_story_key "$story_key")
                    if [ -n "$fallback_renamed" ]; then
                        local fallback_status=$(get_story_status "$fallback_renamed")
                        echo -e "${YELLOW}[LAST-RESORT] Found similar key: $fallback_renamed ($fallback_status)${NC}"

                        if [ "$fallback_status" = "$expected_status" ] || [ "$fallback_status" = "done" ]; then
                            # Brute force: append the missing key to the YAML
                            echo "  ${story_key}: ${fallback_status}  # auto-alias (last-resort fix)" >> "$SPRINT_STATUS"
                            echo -e "${GREEN}[LAST-RESORT] Appended: ${story_key}: ${fallback_status}${NC}"

                            # Verify
                            local final_check=$(get_story_status "$story_key")
                            if [ "$final_check" = "$expected_status" ] || [ "$final_check" = "done" ]; then
                                echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
                                echo -e "${GREEN}║  ✅ LAST-RESORT FIX SUCCEEDED - Key alias added!              ║${NC}"
                                echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
                                send_webhook "🔧 LAST-RESORT FIX: $story_key - Added alias for renamed key $fallback_renamed" "Ralph-BMAD"
                                stale_count=0
                                last_status="$final_check"
                                continue
                            fi
                        fi
                    fi

                    echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}"
                    echo -e "${RED}║  ❌ FIXER Agent FAILED - Manual intervention required         ║${NC}"
                    echo -e "${RED}╠═══════════════════════════════════════════════════════════════╣${NC}"
                    echo -e "${RED}║  Status still: $fixed_status (expected: $expected_status)${NC}"
                    echo -e "${RED}║  → Manually update: $SPRINT_STATUS${NC}"
                    echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}"
                    send_webhook "🚨 STUCK: $story_key - Fixer agent failed. Manual fix needed. Status: $fixed_status, Expected: $expected_status" "Ralph-BMAD Alert"
                    return 1
                fi
            else
                echo -e "${YELLOW}>>> Status unchanged ($stale_count/$MAX_STALE_CONTINUES before fixer)${NC}"
            fi
        else
            stale_count=0
            last_status="$new_status"
        fi

        continue_count=$((continue_count + 1))
        echo -e "${YELLOW}>>> Will resume session ($continue_count/$MAX_CONTINUES)${NC}"
        sleep 2
    done

    echo -e "${RED}Max continues reached${NC}"
    return 1
}

# ═══════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════

check_dependencies

# ═══════════════════════════════════════════════════════════════
# VALIDATE MODE
# ═══════════════════════════════════════════════════════════════

if [ "$VALIDATE_MODE" = true ]; then
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║           Ralph-BMAD - Story Detection Validation             ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""

    echo -e "${CYAN}Sprint Status File:${NC} $SPRINT_STATUS"
    echo ""

    # Show all detected stories by status
    echo -e "${YELLOW}═══ Stories by Status ═══${NC}"
    echo ""

    for status in "ready-for-dev" "in-progress" "review" "backlog" "done"; do
        count=$(grep -E "^[[:space:]]+[0-9]+-[0-9]+-[^:]+:[[:space:]]*${status}" "$SPRINT_STATUS" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -gt 0 ]; then
            case $status in
                ready-for-dev) color=$GREEN ;;
                in-progress) color=$YELLOW ;;
                review) color=$CYAN ;;
                backlog) color=$MAGENTA ;;
                done) color=$NC ;;
            esac
            echo -e "${color}[$status] ($count stories)${NC}"
            # Only show first 5 for backlog to avoid clutter
            if [ "$status" = "backlog" ] && [ "$count" -gt 5 ]; then
                grep -E "^[[:space:]]+[0-9]+-[0-9]+-[^:]+:[[:space:]]*${status}" "$SPRINT_STATUS" 2>/dev/null | head -5 | while read line; do
                    story=$(extract_story_key "$line")
                    epic=$(get_epic_from_story "$story")
                    echo "  - $story (Epic $epic) (will be created)"
                done
                remaining=$((count - 5))
                echo "  ... and $remaining more in backlog"
            else
                grep -E "^[[:space:]]+[0-9]+-[0-9]+-[^:]+:[[:space:]]*${status}" "$SPRINT_STATUS" 2>/dev/null | while read line; do
                    story=$(extract_story_key "$line")
                    epic=$(get_epic_from_story "$story")
                    story_file="$STORIES_DIR/${story}.md"
                    file_exists="✓"
                    [ ! -f "$story_file" ] && file_exists="✗ (missing)"
                    echo "  - $story (Epic $epic) $file_exists"
                done
            fi
            echo ""
        fi
    done

    # Show next story that would be picked
    echo -e "${YELLOW}═══ Detection Test ═══${NC}"
    NEXT=$(get_next_story)
    if [ -n "$NEXT" ]; then
        STATUS=$(get_story_status "$NEXT")
        EPIC=$(get_epic_from_story "$NEXT")
        echo -e "${GREEN}Next story:${NC} $NEXT"
        echo -e "${GREEN}Epic:${NC} $EPIC"
        echo -e "${GREEN}Status:${NC} $STATUS"
        echo -e "${GREEN}Story file:${NC} $STORIES_DIR/${NEXT}.md"
        if [ -f "$STORIES_DIR/${NEXT}.md" ]; then
            echo -e "${GREEN}File exists:${NC} ✓"
        else
            echo -e "${RED}File exists:${NC} ✗ MISSING"
        fi
    else
        # No ready story - check backlog
        NEXT_BACKLOG=$(get_next_backlog_story)
        if [ -n "$NEXT_BACKLOG" ]; then
            echo -e "${MAGENTA}No ready stories - will AUTO-CREATE from backlog:${NC}"
            echo -e "${MAGENTA}Next backlog:${NC} $NEXT_BACKLOG"
            echo -e "${MAGENTA}Action:${NC} Ralph will run /bmad_bmm_create-story automatically"
        else
            echo -e "${GREEN}All stories complete! (including backlog)${NC}"
        fi
    fi

    echo ""
    echo -e "${YELLOW}═══ Epic Summary ═══${NC}"
    for epic_num in $(grep -E "^[[:space:]]+epic-[0-9]+:" "$SPRINT_STATUS" 2>/dev/null | sed 's/.*epic-//' | sed 's/:.*//' | sort -n | uniq); do
        epic_status=$(get_epic_status "$epic_num")
        story_count=$(grep -E "^[[:space:]]+${epic_num}-[0-9]+-" "$SPRINT_STATUS" 2>/dev/null | wc -l | tr -d ' ')
        done_count=$(grep -E "^[[:space:]]+${epic_num}-[0-9]+-[^:]+:[[:space:]]*done" "$SPRINT_STATUS" 2>/dev/null | wc -l | tr -d ' ')
        echo "  Epic $epic_num: $epic_status ($done_count/$story_count stories done)"
    done

    echo ""
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║           Ralph-BMAD - Autonomous Development Loop            ║"
echo "║         Session: --session-id/--resume | Mode: --print        ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}>>> DRY-RUN MODE <<<${NC}"
    echo ""
fi

REMAINING=$(count_remaining)
BACKLOG=$(count_backlog)

if [ "$REMAINING" -eq 0 ] && [ "$BACKLOG" -eq 0 ]; then
    echo -e "${GREEN}All stories complete! (no backlog remaining)${NC}"
    echo "<promise>COMPLETE</promise>"
    exit 0
fi

echo "Stories ready/in-progress/review: $REMAINING"
echo "Stories in backlog: $BACKLOG"
echo "Auto-create: enabled (will create from backlog when needed)"
if [ "$INFINITE_MODE" = true ]; then
    echo "Mode: infinite (until all stories complete)"
else
    echo "Max iterations: $MAX_ITERATIONS"
fi
[ -n "$WEBHOOK_URL" ] && echo "Webhook: enabled"
[ "$NOTIFY_SOUND" = true ] && echo "Sound notification: enabled"
echo ""

[ "$DRY_RUN" = false ] && archive_previous && init_progress

CURRENT_EPIC=""
ITERATION=0

# Main loop (while-based to support infinite mode)
while [ "$INFINITE_MODE" = true ] || [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    if [ "$INFINITE_MODE" = true ]; then
        echo -e "${BLUE}  ITERATION $ITERATION (infinite mode)${NC}"
    else
        echo -e "${BLUE}  ITERATION $ITERATION of $MAX_ITERATIONS${NC}"
    fi
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"

    NEXT_STORY=$(get_next_story)

    # If no ready story, try to create one from backlog
    if [ -z "$NEXT_STORY" ]; then
        BACKLOG_STORY=$(get_next_backlog_story)
        if [ -n "$BACKLOG_STORY" ]; then
            echo -e "${YELLOW}No ready stories, but backlog has: $BACKLOG_STORY${NC}"
            create_next_story "$BACKLOG_STORY"

            # Re-check for ready story after creation
            NEXT_STORY=$(get_next_story)
            if [ -z "$NEXT_STORY" ]; then
                echo -e "${RED}Story creation did not produce a ready-for-dev story${NC}"
                echo -e "${RED}Manual intervention may be required${NC}"
                send_webhook "⚠️ Story creation failed for $BACKLOG_STORY - no ready-for-dev story found after create-story" "Creation Failed"
                # Continue loop to try again or exit
                sleep 5
                continue
            fi
        else
            echo -e "${GREEN}No more stories! (backlog empty)${NC}"
            echo "<promise>COMPLETE</promise>"

            # Print final stats and exit
            print_stats_summary
            if [ "$DRY_RUN" = false ]; then
                REPORT_FILE=$(generate_sprint_report)
                echo -e "${CYAN}Sprint report saved: $REPORT_FILE${NC}"
            fi
            send_webhook "🎉 Sprint complete! All stories done including backlog." "Sprint Complete"
            play_notification_sound
            exit 0
        fi
    fi

    # Epic transition detection
    STORY_EPIC=$(get_epic_from_story "$NEXT_STORY")
    if [ -n "$CURRENT_EPIC" ] && [ "$STORY_EPIC" != "$CURRENT_EPIC" ]; then
        echo ""
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║          EPIC TRANSITION: Epic $CURRENT_EPIC → Epic $STORY_EPIC${NC}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"

        # Check if previous epic retrospective exists and is pending
        retro_status=$(get_story_status "epic-${CURRENT_EPIC}-retrospective")
        if [ "$retro_status" = "optional" ] || [ "$retro_status" = "pending" ]; then
            echo -e "${YELLOW}Note: epic-${CURRENT_EPIC}-retrospective is $retro_status (skipping auto-run)${NC}"
        fi

        [ "$DRY_RUN" = false ] && echo "### EPIC TRANSITION: $CURRENT_EPIC → $STORY_EPIC - $(date)" >> "$PROGRESS_FILE"
    fi
    CURRENT_EPIC="$STORY_EPIC"

    STORY_STATUS=$(get_story_status "$NEXT_STORY")
    echo "Story: $NEXT_STORY (Epic $STORY_EPIC) (status: $STORY_STATUS)"

    [ "$DRY_RUN" = false ] && echo "### $NEXT_STORY - $(date)" >> "$PROGRESS_FILE"

    # Track story timing
    STORY_START_TIME=$(date +%s)
    STORY_COST=0

    # Phase 1: dev-story
    if [ "$STORY_STATUS" = "ready-for-dev" ] || [ "$STORY_STATUS" = "in-progress" ]; then
        run_workflow "$NEXT_STORY" "dev-story" "review"
        STORY_COST=$(echo "$STORY_COST + $LAST_RUN_COST" | bc 2>/dev/null || echo "$LAST_RUN_COST")
    fi

    # Phase 2: code-review
    STORY_STATUS=$(get_story_status "$NEXT_STORY")
    if [ "$STORY_STATUS" = "review" ]; then
        run_workflow "$NEXT_STORY" "code-review" "done"
        STORY_COST=$(echo "$STORY_COST + $LAST_RUN_COST" | bc 2>/dev/null || echo "$LAST_RUN_COST")
    fi

    # Phase 3: commit (after successful code-review)
    STORY_STATUS=$(get_story_status "$NEXT_STORY")
    if [ "$STORY_STATUS" = "done" ]; then
        echo -e "${CYAN}┌─────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│  commit: $NEXT_STORY${NC}"
        echo -e "${CYAN}└─────────────────────────────────────────┘${NC}"

        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}[DRY-RUN] Would commit changes for $NEXT_STORY${NC}"
        else
            # Run commit skill
            COMMIT_SESSION=$(new_session_id)
            COMMIT_PROMPT="Run /commit for story $NEXT_STORY. Stage all changes and commit with message: feat($NEXT_STORY): complete story implementation. Work autonomously, do not ask questions."
            run_claude_with_retry "$COMMIT_PROMPT" "$COMMIT_SESSION" ""
            STORY_COST=$(echo "$STORY_COST + $LAST_RUN_COST" | bc 2>/dev/null || echo "$LAST_RUN_COST")
            echo -e "${GREEN}>>> Committed changes for $NEXT_STORY${NC}"
        fi
    fi

    # Calculate story duration and track stats
    STORY_END_TIME=$(date +%s)
    STORY_DURATION=$((STORY_END_TIME - STORY_START_TIME))

    # Log final status
    FINAL_STATUS=$(get_story_status "$NEXT_STORY")
    echo -e "${GREEN}Story $NEXT_STORY: $FINAL_STATUS${NC}"
    echo -e "${CYAN}  ├─ Duration: $(format_duration $STORY_DURATION)${NC}"
    echo -e "${CYAN}  └─ Cost: \$$(printf "%.2f" ${STORY_COST:-0})${NC}"

    [ "$DRY_RUN" = false ] && echo "  Final: $FINAL_STATUS ($(format_duration $STORY_DURATION), \$${STORY_COST})" >> "$PROGRESS_FILE"

    # Track stats
    track_story_stats "$NEXT_STORY" "$STORY_DURATION" "${STORY_COST:-0}" "$FINAL_STATUS"

    # Send webhook notification for completed story
    if [ "$FINAL_STATUS" = "done" ]; then
        send_webhook "✅ Story completed: $NEXT_STORY ($(format_duration $STORY_DURATION), \$$(printf "%.2f" ${STORY_COST:-0}))" "Story Done"
    fi

    # Check if all done
    if [ "$(count_remaining)" -eq 0 ]; then
        echo ""
        echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              ALL STORIES COMPLETE!                            ║${NC}"
        echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"

        # Print stats summary
        print_stats_summary

        # Generate report
        if [ "$DRY_RUN" = false ]; then
            REPORT_FILE=$(generate_sprint_report)
            echo -e "${CYAN}Sprint report saved: $REPORT_FILE${NC}"
        fi

        # Send completion webhook
        send_webhook "🎉 Sprint complete! $STORIES_COMPLETED stories done in $(format_duration $TOTAL_TIME). Total cost: \$$(printf "%.2f" $TOTAL_COST)" "Sprint Complete"

        # Play sound
        play_notification_sound

        echo "<promise>COMPLETE</promise>"
        exit 0
    fi
done

# Max iterations reached
print_stats_summary

if [ "$DRY_RUN" = false ]; then
    REPORT_FILE=$(generate_sprint_report)
    echo -e "${CYAN}Sprint report saved: $REPORT_FILE${NC}"
fi

send_webhook "⚠️ Max iterations reached ($MAX_ITERATIONS). $STORIES_COMPLETED stories done, $(count_remaining) remaining." "Iterations Limit"
play_notification_sound

echo -e "${RED}Max iterations reached. Remaining: $(count_remaining)${NC}"
exit 1
