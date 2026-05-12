#!/usr/bin/env bash
# gh_shortcut.sh — Deterministic guardrails for one-click CodeRabbit review loop
#
# Usage:
#   eval "$(gh_shortcut.sh init)"
#   gh_shortcut.sh check [--since TIMESTAMP]
#   gh_shortcut.sh fetch-reviews [--since TIMESTAMP]
#   gh_shortcut.sh reply <comment_id> <body>
#   gh_shortcut.sh reply --pr-comment <body>
#   gh_shortcut.sh create-issue <title> [< body]
#   gh_shortcut.sh wait-for-coderabbit [--timeout N] [--interval N]

set -euo pipefail

# ─── Config ────────────────────────────────────────────────────
CODERABBIT_BOT="${CODERABBIT_BOT:-coderabbit-for-wrtn}"
CODERABBIT_REVIEW_COMMAND="${CODERABBIT_REVIEW_COMMAND:-@coderabbitai review}"
CODERABBIT_RESUME_COMMAND="${CODERABBIT_RESUME_COMMAND:-@coderabbitai resume}"
DEFAULT_TIMEOUT=600
DEFAULT_INTERVAL=30
TRIGGER_AFTER=60

# ─── Utilities ─────────────────────────────────────────────────
die() { local code=$1; shift; printf '[guard] ERROR: %s\n' "$*" >&2; exit "$code"; }
log() { printf '[guard] %s\n' "$*" >&2; }

require_env() {
  local var
  for var in OWNER REPO PR_NUMBER BRANCH; do
    [[ -n "${!var:-}" ]] || die 3 "env var $var not set. Run: eval \"\$(gh_shortcut.sh init)\""
  done
}

gh_api() {
  if [[ -n "${GH_HOST:-}" ]]; then
    GH_HOST="$GH_HOST" gh api "$@"
  else
    gh api "$@"
  fi
}

post_pr_comment() {
  local body="$1"
  gh_api "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" \
    --method POST -f body="$body" >/dev/null 2>&1
}

# ─── init ──────────────────────────────────────────────────────
# Detect GH_HOST, OWNER, REPO, PR_NUMBER, BRANCH from git remote.
# Output: export KEY=VALUE lines (eval-able)
cmd_init() {
  command -v gh >/dev/null 2>&1 || die 3 "gh CLI not found. Install: https://cli.github.com"
  command -v jq >/dev/null 2>&1 || die 3 "jq not found. Install: brew install jq"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 3 "not a git repository"

  local remote_url host owner repo owner_repo gh_host=""
  remote_url=$(git remote get-url origin 2>/dev/null) || die 3 "no 'origin' remote"

  case "$remote_url" in
    git@*:*)
      host="${remote_url#git@}"; host="${host%%:*}"
      owner_repo="${remote_url#*:}"; owner_repo="${owner_repo%.git}"
      ;;
    https://*|http://*)
      host="${remote_url#*://}"; host="${host%%/*}"
      owner_repo=$(echo "$remote_url" | sed -E 's|https?://[^/]+/||'); owner_repo="${owner_repo%.git}"
      ;;
    ssh://git@*)
      host="${remote_url#ssh://git@}"; host="${host%%/*}"
      owner_repo="${remote_url#ssh://git@*/}"; owner_repo="${owner_repo%.git}"
      ;;
    *) die 3 "unsupported remote URL: $remote_url" ;;
  esac

  owner="${owner_repo%%/*}"
  repo="${owner_repo#*/}"
  [[ "$host" != "github.com" ]] && gh_host="$host"

  # Auth check — validate against the correct host (GH Enterprise or github.com)
  if [[ -n "$gh_host" ]]; then
    gh auth status --hostname "$gh_host" >/dev/null 2>&1 || die 3 "gh not authenticated for $gh_host. Run: gh auth login --hostname $gh_host"
  else
    gh auth status >/dev/null 2>&1 || die 3 "gh not authenticated. Run: gh auth login"
  fi

  local branch pr_number
  branch=$(git branch --show-current)

  if [[ -n "$gh_host" ]]; then
    pr_number=$(GH_HOST="$gh_host" gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
  else
    pr_number=$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
  fi
  [[ -z "$pr_number" ]] && die 3 "no open PR for branch '$branch'"

  printf 'export GH_HOST=%q\n' "$gh_host"
  printf 'export OWNER=%q\n' "$owner"
  printf 'export REPO=%q\n' "$repo"
  printf 'export PR_NUMBER=%q\n' "$pr_number"
  printf 'export BRANCH=%q\n' "$branch"
}

# ─── check ─────────────────────────────────────────────────────
# Check all 3 termination conditions.
# Exit 0 = all met (stop loop), Exit 1 = continue loop.
cmd_check() {
  require_env
  local since="" sha_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) [[ -n "${2-}" ]] || die 2 "missing value for --since"; since="$2"; shift 2 ;;
      --sha) [[ -n "${2-}" ]] || die 2 "missing value for --sha"; sha_override="$2"; shift 2 ;;
      *) die 2 "unknown arg: $1" ;;
    esac
  done

  local sha cr_status cr_description unresolved_count new_review_count review_body_feedback_count
  sha="${sha_override:-$(git rev-parse HEAD)}"

  # Condition 1: CodeRabbit commit status (latest by created_at)
  local statuses_result
  statuses_result=$(gh_api "repos/${OWNER}/${REPO}/commits/${sha}/statuses" 2>/dev/null) || die 4 "failed to query commit statuses"
  cr_status=$(echo "$statuses_result" | jq -r '[.[] | select(.context=="CodeRabbit")] | sort_by(.created_at) | reverse | .[0].state // "not_found"')
  cr_description=$(echo "$statuses_result" | jq -r '[.[] | select(.context=="CodeRabbit")] | sort_by(.created_at) | reverse | .[0].description // ""')

  # Condition 2: Unresolved review threads (cursor-paginated)
  unresolved_count=0
  local cursor=""
  while true; do
    local threads_result cursor_arg=""
    [[ -n "$cursor" ]] && cursor_arg="-f cursor=$cursor"
    threads_result=$(gh_api graphql \
      -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" \
      $cursor_arg \
      -f query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
        repository(owner:$owner,name:$repo){
          pullRequest(number:$pr){
            reviewThreads(first:100,after:$cursor){
              nodes{isResolved}
              pageInfo{hasNextPage endCursor}
            }
          }
        }
      }' 2>/dev/null) || die 4 "failed to query review threads"
    local page_unresolved has_next
    page_unresolved=$(echo "$threads_result" | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false)] | length')
    unresolved_count=$((unresolved_count + page_unresolved))
    has_next=$(echo "$threads_result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
    [[ "$has_next" != "true" ]] && break
    cursor=$(echo "$threads_result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  done

  # Condition 3: New CHANGES_REQUESTED reviews (including empty body)
  local jq_filter
  if [[ -n "$since" ]]; then
    jq_filter='[.[] | select(.submitted_at > "'"${since}"'" and .state == "CHANGES_REQUESTED")] | length'
  else
    jq_filter='[.[] | select(.state == "CHANGES_REQUESTED")] | length'
  fi
  local reviews_raw issue_comments_raw
  reviews_raw=$(gh_api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate 2>/dev/null) || die 4 "failed to query PR reviews"
  new_review_count=$(echo "$reviews_raw" | jq -s 'add // []' | jq "$jq_filter")
  issue_comments_raw=$(gh_api "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" --paginate 2>/dev/null | jq -s 'add // []') || die 4 "failed to query PR issue comments"
  review_body_feedback_count=$(jq -n \
    --argjson reviews "$(echo "$reviews_raw" | jq -s 'add // []')" \
    --argjson issue_comments "$issue_comments_raw" \
    --arg since "$since" '
      def actionable:
        .body != null and
        (.body | test("_⚠️ Potential issue_|Potential issue|Outside diff range comments"));
      def addressed_after($submitted_at):
        [$issue_comments[] |
          select(.created_at > $submitted_at) |
          select((.user.login | test("coderabbit"; "i")) | not) |
          select((.body // "") | test("수정 완료|대응 완료|처리 완료|Addressed|resolved"; "i"))
        ] | length > 0;
      [$reviews[] |
        select((.state == "CHANGES_REQUESTED" or .state == "COMMENTED") and actionable) |
        select($since == "" or .submitted_at > $since) |
        select(addressed_after(.submitted_at) | not)
      ] | length
    ')

  # Determine result
  local cr_ok=false threads_ok=false reviews_ok=false should_stop=false
  [[ "$cr_status" == "success" && "$cr_description" != "Review skipped" ]] && cr_ok=true
  [[ "$unresolved_count" == "0" ]] && threads_ok=true
  [[ "$new_review_count" == "0" && "$review_body_feedback_count" == "0" ]] && reviews_ok=true
  [[ "$cr_ok" == "true" && "$threads_ok" == "true" && "$reviews_ok" == "true" ]] && should_stop=true

  jq -n \
    --argjson should_stop "$should_stop" \
    --argjson cr_ok "$cr_ok" \
    --argjson threads_ok "$threads_ok" \
    --argjson reviews_ok "$reviews_ok" \
    --arg cr_status "$cr_status" \
    --arg cr_description "$cr_description" \
    --argjson unresolved "$unresolved_count" \
    --argjson new_reviews "$new_review_count" \
    --argjson review_body_feedbacks "$review_body_feedback_count" \
    --arg sha "$sha" \
    '{
      should_stop: $should_stop,
      conditions: {
        coderabbit_success: $cr_ok,
        threads_resolved: $threads_ok,
        no_new_reviews: $reviews_ok
      },
      details: {
        coderabbit_status: $cr_status,
        coderabbit_description: $cr_description,
        unresolved_threads: $unresolved,
        new_reviews: $new_reviews,
        review_body_feedbacks: $review_body_feedbacks,
        sha: $sha
      }
    }'

  [[ "$should_stop" == "true" ]] && exit 0 || exit 1
}

# ─── fetch-reviews ─────────────────────────────────────────────
# Fetch reviews/comments, parse CodeRabbit format, output structured JSON.
cmd_fetch_reviews() {
  require_env
  local since=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since) [[ -n "${2-}" ]] || die 2 "missing value for --since"; since="$2"; shift 2 ;;
      *) die 2 "unknown arg: $1" ;;
    esac
  done

  log "fetching reviews for PR #${PR_NUMBER}..."

  # 1. Reviews (REST, paginated → slurp into single array)
  local reviews_json
  reviews_json=$(gh_api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/reviews" --paginate 2>/dev/null | jq -s 'add // []') || die 4 "failed to query PR reviews"

  # 2. Inline comments — original only (REST, paginated → slurp)
  local comments_json
  comments_json=$(gh_api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments" --paginate 2>/dev/null | jq -s 'add // []') || die 4 "failed to query PR comments"

  # 3. PR conversation comments — used to mark review-body feedback as addressed
  local issue_comments_json
  issue_comments_json=$(gh_api "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" --paginate 2>/dev/null | jq -s 'add // []') || die 4 "failed to query PR issue comments"

  # 4. Review threads — for thread_id and isResolved (GraphQL, cursor-paginated)
  local threads_json="[]" cursor=""
  while true; do
    local page_result cursor_arg=""
    [[ -n "$cursor" ]] && cursor_arg="-f cursor=$cursor"
    page_result=$(gh_api graphql \
      -f owner="$OWNER" -f repo="$REPO" -F pr="$PR_NUMBER" \
      $cursor_arg \
      -f query='query($owner:String!,$repo:String!,$pr:Int!,$cursor:String){
        repository(owner:$owner,name:$repo){
          pullRequest(number:$pr){
            reviewThreads(first:100,after:$cursor){
              nodes{
                id isResolved isOutdated path line
                comments(first:1){nodes{databaseId body}}
              }
              pageInfo{hasNextPage endCursor}
            }
          }
        }
      }' 2>/dev/null) || die 4 "failed to query review threads"
    local page_nodes has_next
    page_nodes=$(echo "$page_result" | jq '.data.repository.pullRequest.reviewThreads.nodes')
    threads_json=$(echo "$threads_json" "$page_nodes" | jq -s '.[0] + .[1]')
    has_next=$(echo "$page_result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')
    [[ "$has_next" != "true" ]] && break
    cursor=$(echo "$page_result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  done

  # 5. Merge and parse with jq
  local jq_filter
  jq_filter=$(cat <<'JQ'
def parse_severity:
  if . == null then "unknown"
  elif test("🔴") then "critical"
  elif test("🟠") then "major"
  elif test("🟡") then "minor"
  elif test("[Nn]itpick|🟢") then "nitpick"
  else "unknown" end;

def extract_summary:
  if . == null then null
  else
    [split("\n")[] | select(startswith("**") and endswith("**"))] |
    .[0] // null |
    if . then ltrimstr("**") | rtrimstr("**") else null end
  end;

def extract_prompt:
  if . == null or (test("Prompt for") | not) then null
  else
    (split("Prompt for") | .[1] // "") |
    (split("</summary>") | .[1] // "") |
    (split("</details>") | .[0] // "") |
    (split($fence) | if length >= 3 then .[1] | ltrimstr("\n") | rtrimstr("\n") else null end)
  end;

def extract_suggestion:
  if . == null or (test("수정 제안") | not) then null
  else
    (split("수정 제안</summary>") | .[1] // "") |
    (split("</details>") | .[0] // "") |
    (split($fence_diff) |
      if length >= 2 then (.[1] | split($fence) | .[0] | ltrimstr("\n") | rtrimstr("\n"))
      else null end)
  end;

def is_addressed: . != null and test("✅ Addressed");

def is_review_body_actionable:
  .body != null and
  (.body | test("_⚠️ Potential issue_|Potential issue|Outside diff range comments"));

def review_body_addressed($submitted_at):
  [$issue_comments[] |
    select(.created_at > $submitted_at) |
    select((.user.login | test("coderabbit"; "i")) | not) |
    select((.body // "") | test("수정 완료|대응 완료|처리 완료|Addressed|resolved"; "i"))
  ] | length > 0;

# Build thread lookup: comment databaseId -> thread info
($threads
  | [.[] | (.comments.nodes[0].databaseId | tostring) as $key |
     {key: $key, value: {thread_id: .id, is_resolved: .isResolved, is_outdated: (.isOutdated // false)}}]
  | from_entries
) as $thread_map |

# Process ALL inline comments (original only, no replies) — no --since filter
[
  $comments[] |
  select(.in_reply_to_id == null) |
  . as $c |
  ($thread_map[($c.id | tostring)] // {thread_id: null, is_resolved: false, is_outdated: false}) as $t |
  {
    comment_id: $c.id,
    thread_id: $t.thread_id,
    path: $c.path,
    line: ($c.line // $c.original_line),
    severity: ($c.body | parse_severity),
    summary: ($c.body | extract_summary),
    prompt: ($c.body | extract_prompt),
    suggestion: ($c.body | extract_suggestion),
    is_resolved: $t.is_resolved,
    is_outdated: $t.is_outdated,
    addressed: ($c.body | is_addressed),
    diff_hunk: $c.diff_hunk,
    created_at: $c.created_at
  }
] as $all_comments |

# Recent comments (--since filtered)
[if $since != "" then $all_comments[] | select(.created_at > $since) else $all_comments[] end] as $recent |

# Review-level consolidated prompt
([$reviews[] | select(.body != null and (.body | test("Prompt for")))] |
  .[0] // null) as $main_review |

# Review-level feedbacks (CHANGES_REQUESTED with non-empty body)
[$reviews[] | select(.state == "CHANGES_REQUESTED" and .body != null and .body != "") |
  {review_id: .id, body: .body, state: .state, submitted_at: .submitted_at}
] as $review_feedbacks |

# Review-body feedbacks that cannot be represented as GitHub review threads
[$reviews[] |
  select((.state == "CHANGES_REQUESTED" or .state == "COMMENTED") and is_review_body_actionable) |
  select($since == "" or .submitted_at > $since) |
  {
    comment_id: null,
    review_id: .id,
    thread_id: null,
    source: "review_body",
    path: null,
    line: null,
    severity: (.body | parse_severity),
    summary: (.body | extract_summary),
    prompt: (.body | extract_prompt),
    suggestion: null,
    is_resolved: false,
    is_outdated: false,
    addressed: review_body_addressed(.submitted_at),
    diff_hunk: null,
    created_at: .submitted_at,
    body: .body,
    state: .state
  }
] as $review_body_feedbacks |

# Unresolved: inline threads plus recent/unaddressed review-body feedbacks
([$all_comments[] | select(.is_resolved == false and .addressed == false)] +
 [$review_body_feedbacks[] | select(.addressed == false)]) as $unresolved_all |

{
  fetched_at: (now | todate),
  review_prompt: (if $main_review then $main_review.body | extract_prompt else null end),
  review_feedbacks: ($review_feedbacks + $review_body_feedbacks),
  comments: $recent,
  unresolved: $unresolved_all,
  summary: {
    total: (($all_comments | length) + ($review_body_feedbacks | length)),
    unresolved: ($unresolved_all | length),
    review_feedbacks: (($review_feedbacks | length) + ($review_body_feedbacks | length)),
    addressed: (([$all_comments[] | select(.addressed)] | length) + ([$review_body_feedbacks[] | select(.addressed)] | length)),
    by_severity: (($all_comments + $review_body_feedbacks) | group_by(.severity) | map({key: .[0].severity, value: length}) | from_entries)
  }
}
JQ
)

  jq -n \
    --argjson reviews "$reviews_json" \
    --argjson comments "$comments_json" \
    --argjson issue_comments "$issue_comments_json" \
    --argjson threads "$threads_json" \
    --arg since "${since:-}" \
    --arg fence '```' \
    --arg fence_diff '```diff' \
    "$jq_filter"
}

# ─── reply ─────────────────────────────────────────────────────
# Post a reply to an inline comment or a PR-level comment.
cmd_reply() {
  require_env

  if [[ "${1:-}" == "--pr-comment" ]]; then
    shift
    local body="${1:-}"
    [[ -z "$body" ]] && body=$(cat)
    [[ -z "$body" ]] && die 2 "body required"
    gh_api "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" \
      --method POST -f body="$body" \
      --jq '{id:.id, url:.html_url}'
  else
    local comment_id="${1:-}"
    [[ -z "$comment_id" ]] && die 2 "usage: gh_shortcut.sh reply <comment_id> <body>"
    shift
    local body="${1:-}"
    [[ -z "$body" ]] && body=$(cat)
    [[ -z "$body" ]] && die 2 "body required"
    gh_api "repos/${OWNER}/${REPO}/pulls/${PR_NUMBER}/comments/${comment_id}/replies" \
      --method POST -f body="$body" \
      --jq '{id:.id, url:.html_url}'
  fi
}

# ─── create-issue ──────────────────────────────────────────────
# Create a GitHub issue for out-of-scope review items.
cmd_create_issue() {
  require_env
  local title="${1:-}"
  [[ -z "$title" ]] && die 2 "usage: gh_shortcut.sh create-issue <title> [body via stdin]"
  shift

  local body=""
  if [[ -n "${1:-}" ]]; then
    body="$1"
  elif [[ ! -t 0 ]]; then
    body=$(cat)
  fi

  # Prepend source info
  local full_body
  full_body=$(printf '## 출처\n\nPR #%d CodeRabbit 리뷰\n\n## 내용\n\n%s' "$PR_NUMBER" "$body")

  gh_api "repos/${OWNER}/${REPO}/issues" \
    --method POST \
    -f title="$title" \
    -f body="$full_body" \
    --jq '{number:.number, url:.html_url}'
}

# ─── wait-for-coderabbit ──────────────────────────────────────
# Poll until CodeRabbit finishes reviewing. Auto-triggers review if not started.
# If paused (auto_pause_after_reviewed_commits), sends resume instead of review.
# Exit 0 = success, Exit 2 = timeout. Failures auto-trigger re-review.
cmd_wait_for_coderabbit() {
  require_env
  local timeout=$DEFAULT_TIMEOUT interval=$DEFAULT_INTERVAL
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) [[ -n "${2-}" ]] || die 2 "missing value for --timeout"; timeout=$2; shift 2 ;;
      --interval) [[ -n "${2-}" ]] || die 2 "missing value for --interval"; interval=$2; shift 2 ;;
      *) die 2 "unknown arg: $1" ;;
    esac
  done

  local elapsed=0 triggered=false cr_state=""

  while [[ $elapsed -lt $timeout ]]; do
    # Check if CodeRabbit is in "Reviews paused" state and resume if so (every iteration)
    local paused=false
    local latest_cr_comment
    latest_cr_comment=$(gh_api "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" \
      --paginate 2>/dev/null | jq -s 'add // []' | \
      jq "[.[] | select(.user.login==\"${CODERABBIT_BOT}[bot]\") | select(.body | test(\"review paused by coderabbit\"))] | last // empty" \
      || echo "")
    if [[ -n "$latest_cr_comment" ]]; then
      local paused_at resumed_after
      paused_at=$(echo "$latest_cr_comment" | jq -r '.created_at // empty')
      if [[ -n "$paused_at" ]]; then
        resumed_after=$(gh_api "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" \
          --paginate 2>/dev/null | jq -s 'add // []' | \
          jq --arg cmd "$CODERABBIT_RESUME_COMMAND" "[.[] | select(.created_at > \"${paused_at}\") | select(.body | contains(\$cmd))] | length" \
          || echo "0")
        if [[ "$resumed_after" == "0" ]]; then
          paused=true
        fi
      fi
    fi

    if [[ "$paused" == "true" ]]; then
      log "CodeRabbit is paused — sending resume to re-enable automatic reviews"
      post_pr_comment "$CODERABBIT_RESUME_COMMAND" \
        || log "failed to post resume comment"
    fi

    local sha cr_status_json cr_description
    sha=$(git rev-parse HEAD)
    cr_status_json=$(gh_api "repos/${OWNER}/${REPO}/commits/${sha}/statuses" \
      --jq '[.[] | select(.context=="CodeRabbit")] | sort_by(.created_at) | reverse | .[0] // {}' \
      2>/dev/null || echo '{}')
    cr_state=$(echo "$cr_status_json" | jq -r '.state // "not_found"' 2>/dev/null || echo "api_error")
    cr_description=$(echo "$cr_status_json" | jq -r '.description // ""' 2>/dev/null || echo "")

    case "$cr_state" in
      success)
        if [[ "$cr_description" == "Review skipped" ]]; then
          if [[ "$triggered" == "false" ]]; then
            log "CodeRabbit review skipped — triggering manual review with: ${CODERABBIT_REVIEW_COMMAND}"
            if post_pr_comment "$CODERABBIT_REVIEW_COMMAND"; then
              triggered=true
            else
              log "failed to post review trigger comment"
            fi
          else
            log "CodeRabbit review still skipped after trigger (${elapsed}s/${timeout}s)"
          fi
        else
          log "CodeRabbit review complete (${elapsed}s)"
          jq -n --arg state "$cr_state" --arg description "$cr_description" --argjson elapsed "$elapsed" \
            '{status:"success", coderabbit_state:$state, coderabbit_description:$description, elapsed:$elapsed}'
          exit 0
        fi
        ;;
      pending)
        log "CodeRabbit reviewing... (${elapsed}s/${timeout}s)"
        ;;
      failure|error)
        if [[ "$triggered" == "false" ]]; then
          log "CodeRabbit ${cr_state} — triggering re-review with: ${CODERABBIT_REVIEW_COMMAND}"
          if post_pr_comment "$CODERABBIT_REVIEW_COMMAND"; then
            triggered=true
          else
            log "failed to post re-review trigger comment"
          fi
        else
          log "CodeRabbit ${cr_state} after retry (${elapsed}s/${timeout}s)"
        fi
        ;;
      not_found|api_error)
        if [[ $elapsed -ge $TRIGGER_AFTER && "$triggered" == "false" ]]; then
          log "no CodeRabbit status after ${elapsed}s — triggering review with: ${CODERABBIT_REVIEW_COMMAND}"
          if post_pr_comment "$CODERABBIT_REVIEW_COMMAND"; then
            triggered=true
          else
            log "failed to post review trigger comment"
          fi
        else
          log "waiting for CodeRabbit to start... (${elapsed}s/${timeout}s)"
        fi
        ;;
    esac

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  log "timeout after ${timeout}s (last state: ${cr_state:-unknown})"
  jq -n --arg state "${cr_state:-unknown}" --argjson elapsed "$elapsed" \
    '{status:"timeout", coderabbit_state:$state, elapsed:$elapsed}'
  exit 2
}

# ─── Main ──────────────────────────────────────────────────────
main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" ]]; then
    cat >&2 <<'USAGE'
gh_shortcut.sh — Deterministic guardrails for one-click review loop

Commands:
  init                             Detect env (GH_HOST, OWNER, REPO, PR, BRANCH)
  check [--since TS]               Check 3 termination conditions (exit 0=stop, 1=continue)
  fetch-reviews [--since TS]       Fetch & parse CodeRabbit reviews → structured JSON
  reply <comment_id> <body>        Reply to inline comment
  reply --pr-comment <body>        Post PR-level comment
  create-issue <title> [< body]    Create issue for out-of-scope item
  wait-for-coderabbit [opts]       Poll until CodeRabbit finishes (auto-triggers if needed)
    --timeout N (default: 600)
    --interval N (default: 30)
USAGE
    exit 2
  fi
  shift

  case "$cmd" in
    init)                 cmd_init "$@" ;;
    check)                cmd_check "$@" ;;
    fetch-reviews)        cmd_fetch_reviews "$@" ;;
    reply)                cmd_reply "$@" ;;
    create-issue)         cmd_create_issue "$@" ;;
    wait-for-coderabbit)  cmd_wait_for_coderabbit "$@" ;;
    *) die 2 "unknown command: $cmd" ;;
  esac
}

main "$@"
