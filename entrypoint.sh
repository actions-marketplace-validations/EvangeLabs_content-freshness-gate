#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[content-freshness-gate] $*"
}

debug() {
  if [[ "$DEBUG" == "true" ]]; then
    echo "[content-freshness-gate][debug] $*"
  fi
}

normalize_bool() {
  local raw="${1:-false}"
  raw="${raw,,}"
  case "$raw" in
    true|1|yes|y|on) echo "true" ;;
    *) echo "false" ;;
  esac
}

to_int_or_default() {
  local raw="${1:-}"
  local default_value="${2:-0}"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "$raw"
  else
    echo "$default_value"
  fi
}

require_env() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    log "Missing required environment variable: $key"
    exit 1
  fi
}

url_encode() {
  jq -nr --arg v "$1" '$v|@uri'
}

# Globals populated by api_request.
API_BODY=""
API_STATUS=""
API_HEADERS_FILE=""
RATE_LIMITED="false"

api_request() {
  local method="$1"
  local url="$2"
  local data="${3:-}"

  API_HEADERS_FILE="$(mktemp)"
  local body_file
  body_file="$(mktemp)"

  local auth_header=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi

  local curl_args=(
    -sS
    -X "$method"
    -D "$API_HEADERS_FILE"
    -o "$body_file"
    -w "%{http_code}"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    "${auth_header[@]}"
  )

  if [[ -n "$data" ]]; then
    curl_args+=(-H "Content-Type: application/json" -d "$data")
  fi

  API_STATUS="$(curl "${curl_args[@]}" "$url" || true)"
  API_BODY="$(cat "$body_file")"
  rm -f "$body_file"

  local remaining
  remaining="$(awk 'tolower($1)=="x-ratelimit-remaining:" {print $2}' "$API_HEADERS_FILE" | tr -d '\r' | tail -n1)"
  if [[ "$API_STATUS" == "403" && "$remaining" == "0" ]]; then
    RATE_LIMITED="true"
    log "GitHub API rate limit reached. Further API writes will be skipped."
  fi

  debug "API $method $url -> $API_STATUS"
  if [[ "$DEBUG" == "true" ]]; then
    local rate_reset
    rate_reset="$(awk 'tolower($1)=="x-ratelimit-reset:" {print $2}' "$API_HEADERS_FILE" | tr -d '\r' | tail -n1)"
    if [[ -n "$remaining" ]]; then
      debug "Rate limit remaining: $remaining (reset: $rate_reset)"
    fi
  fi
}

parse_iso_to_unix() {
  local iso="$1"
  if [[ -z "$iso" ]]; then
    echo "0"
    return
  fi
  date -u -d "$iso" +%s 2>/dev/null || echo "0"
}

extract_username_from_email() {
  local email="$1"
  if [[ "$email" =~ ^[0-9]+\+([^@]+)@users\.noreply\.github\.com$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$email" =~ ^([^@]+)@users\.noreply\.github\.com$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return
  fi
  echo ""
}

resolve_assignee() {
  local file="$1"
  local email="$2"

  local user
  user="$(extract_username_from_email "$email")"
  if [[ -n "$user" ]]; then
    echo "$user"
    return
  fi

  if [[ -z "${GITHUB_REPOSITORY:-}" || -z "${GITHUB_TOKEN:-}" || "$RATE_LIMITED" == "true" ]]; then
    echo ""
    return
  fi

  local commit_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/commits?path=$(url_encode "$file")&per_page=1"
  api_request "GET" "$commit_url"
  if [[ "$API_STATUS" == "200" ]]; then
    user="$(jq -r '.[0].author.login // empty' <<<"$API_BODY")"
    echo "$user"
    return
  fi

  echo ""
}

ensure_label() {
  local label_name="$1"
  local color="$2"
  local description="$3"

  if [[ "$DRY_RUN" == "true" || "$RATE_LIMITED" == "true" ]]; then
    return
  fi

  local repo_labels_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/labels"
  local payload
  payload="$(jq -n --arg n "$label_name" --arg c "$color" --arg d "$description" '{name:$n,color:$c,description:$d}')"

  api_request "POST" "$repo_labels_url" "$payload"
  if [[ "$API_STATUS" == "201" ]]; then
    log "Created missing label: $label_name"
    return
  fi

  if [[ "$API_STATUS" == "422" ]]; then
    debug "Label already exists or cannot be created: $label_name"
    return
  fi

  log "Could not ensure label '$label_name' (status: $API_STATUS)."
}

marker_for_file() {
  local file="$1"
  echo "<!-- content-freshness-gate:file=$file -->"
}

build_issue_body() {
  local file="$1"
  local state="$2"
  local last_updated_human="$3"
  local age_days="$4"
  local author_email="$5"

  local marker
  marker="$(marker_for_file "$file")"

  cat <<EOF
$marker

## Content Freshness Report
- File: $file
- Status: $state
- Last updated: $last_updated_human
- Age: $age_days days
- Last author email: ${author_email:-unknown}

## Suggestion
Model hint: ${GITHUB_MODEL}
Review this document and update outdated sections, examples, or links.

## Action Checklist
- [ ] Verify that instructions and examples still work
- [ ] Refresh stale links and references
- [ ] Update version-specific details
- [ ] Add changelog context where useful
EOF
}

create_issue() {
  local file="$1"
  local state="$2"
  local last_updated_human="$3"
  local age_days="$4"
  local author_email="$5"
  local assignee="$6"

  local title
  local labels_json

  if [[ "$state" == "STALE" ]]; then
    title="📄 Content refresh needed: $file"
    labels_json='["content-stale"]'
  else
    title="⚠️ Content review warning: $file"
    labels_json='["content-warn"]'
  fi

  local body
  body="$(build_issue_body "$file" "$state" "$last_updated_human" "$age_days" "$author_email")"

  local payload
  if [[ -n "$assignee" ]]; then
    payload="$(jq -n \
      --arg t "$title" \
      --arg b "$body" \
      --arg a "$assignee" \
      --argjson l "$labels_json" \
      '{title:$t, body:$b, labels:$l, assignees:[$a]}')"
  else
    payload="$(jq -n \
      --arg t "$title" \
      --arg b "$body" \
      --argjson l "$labels_json" \
      '{title:$t, body:$b, labels:$l}')"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] Would create $state issue for $file"
    return 0
  fi

  if [[ "$RATE_LIMITED" == "true" ]]; then
    log "Skipping issue creation for $file because API is rate-limited."
    return 1
  fi

  api_request "POST" "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues" "$payload"

  if [[ "$API_STATUS" == "201" ]]; then
    local issue_number
    issue_number="$(jq -r '.number' <<<"$API_BODY")"
    log "Created $state issue #$issue_number for $file"
    return 0
  fi

  log "Failed to create issue for $file (status: $API_STATUS)."
  debug "Response: $API_BODY"
  return 1
}

update_issue_to_stale() {
  local issue_number="$1"
  local file="$2"
  local last_updated_human="$3"
  local age_days="$4"
  local author_email="$5"
  local assignee="$6"

  local title="📄 Content refresh needed: $file"
  local body
  body="$(build_issue_body "$file" "STALE" "$last_updated_human" "$age_days" "$author_email")"

  local payload
  if [[ -n "$assignee" ]]; then
    payload="$(jq -n --arg t "$title" --arg b "$body" --arg a "$assignee" '{title:$t, body:$b, labels:["content-stale"], assignees:[$a]}')"
  else
    payload="$(jq -n --arg t "$title" --arg b "$body" '{title:$t, body:$b, labels:["content-stale"]}')"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] Would upgrade warning issue #$issue_number to STALE for $file"
    return 0
  fi

  if [[ "$RATE_LIMITED" == "true" ]]; then
    log "Skipping issue update for $file because API is rate-limited."
    return 1
  fi

  api_request "PATCH" "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/$issue_number" "$payload"
  if [[ "$API_STATUS" == "200" ]]; then
    log "Upgraded issue #$issue_number to STALE for $file"
    return 0
  fi

  log "Failed to update issue #$issue_number for $file (status: $API_STATUS)."
  debug "Response: $API_BODY"
  return 1
}

close_issue_if_updated() {
  local issue_number="$1"
  local file="$2"
  local issue_created_iso="$3"
  local file_updated_unix="$4"

  local issue_created_unix
  issue_created_unix="$(parse_iso_to_unix "$issue_created_iso")"

  if (( issue_created_unix == 0 )); then
    debug "Skipping close check for #$issue_number (cannot parse created_at)."
    return 1
  fi

  if (( file_updated_unix <= issue_created_unix )); then
    debug "No close needed for #$issue_number ($file unchanged since issue creation)."
    return 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[dry-run] Would close issue #$issue_number for updated file $file"
    return 0
  fi

  if [[ "$RATE_LIMITED" == "true" ]]; then
    log "Skipping close operation for #$issue_number because API is rate-limited."
    return 1
  fi

  local payload
  payload='{"state":"closed","state_reason":"completed"}'
  api_request "PATCH" "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/$issue_number" "$payload"

  if [[ "$API_STATUS" == "200" ]]; then
    log "Closed issue #$issue_number because $file was updated."
    return 0
  fi

  log "Failed to close issue #$issue_number (status: $API_STATUS)."
  debug "Response: $API_BODY"
  return 1
}

# Inputs
require_env "INPUT_PATHS"

STALE_DAYS="$(to_int_or_default "${INPUT_STALE_DAYS:-90}" "90")"
WARN_DAYS="$(to_int_or_default "${INPUT_WARN_DAYS:-60}" "60")"
MAX_ISSUES_PER_RUN="$(to_int_or_default "${INPUT_MAX_ISSUES_PER_RUN:-5}" "5")"
CREATE_ISSUES="$(normalize_bool "${INPUT_CREATE_ISSUES:-true}")"
ASSIGN_LAST_AUTHOR="$(normalize_bool "${INPUT_ASSIGN_LAST_AUTHOR:-true}")"
CLOSE_ON_UPDATE="$(normalize_bool "${INPUT_CLOSE_ON_UPDATE:-true}")"
GITHUB_MODEL="${INPUT_GITHUB_MODEL:-gpt-4o-mini}"
DRY_RUN="$(normalize_bool "${INPUT_DRY_RUN:-false}")"
DEBUG="$(normalize_bool "${INPUT_DEBUG:-false}")"

if (( WARN_DAYS > STALE_DAYS )); then
  log "warn-days cannot be greater than stale-days. Adjusting warn-days to stale-days."
  WARN_DAYS="$STALE_DAYS"
fi

if (( MAX_ISSUES_PER_RUN < 0 )); then
  MAX_ISSUES_PER_RUN=0
fi

if [[ "$CREATE_ISSUES" == "true" || "$CLOSE_ON_UPDATE" == "true" ]]; then
  if [[ -z "${GITHUB_REPOSITORY:-}" ]]; then
    log "GITHUB_REPOSITORY is required for API operations."
    exit 1
  fi
  if [[ "$DRY_RUN" == "false" && -z "${GITHUB_TOKEN:-}" ]]; then
    log "GITHUB_TOKEN is required when not in dry-run mode and API operations are enabled."
    exit 1
  fi
fi

# Prepare markdown file list from globs.
shopt -s globstar nullglob

IFS=',' read -r -a RAW_PATTERNS <<<"$INPUT_PATHS"

declare -A FILE_SEEN=()
FILES=()
for raw in "${RAW_PATTERNS[@]}"; do
  pattern="$(xargs <<<"$raw")"
  if [[ -z "$pattern" ]]; then
    continue
  fi

  debug "Expanding pattern: $pattern"
  while IFS= read -r matched; do
    if [[ -z "$matched" ]]; then
      continue
    fi
    if [[ ! -f "$matched" ]]; then
      debug "Skipping non-file match: $matched"
      continue
    fi
    if [[ -z "${FILE_SEEN[$matched]:-}" ]]; then
      FILE_SEEN[$matched]=1
      FILES+=("$matched")
    fi
  done < <(compgen -G "$pattern" || true)
done

FILES_SCANNED=0
STALE_DETECTED=0
WARNING_DETECTED=0
ISSUES_CREATED=0
ISSUES_CLOSED=0

log "Files matched: ${#FILES[@]}"

# Pull existing open managed issues once to avoid duplicate creation.
declare -A OPEN_ISSUE_NUMBER_BY_FILE=()
declare -A OPEN_ISSUE_CREATED_BY_FILE=()
declare -A OPEN_ISSUE_TITLE_BY_FILE=()

if [[ "$CREATE_ISSUES" == "true" || "$CLOSE_ON_UPDATE" == "true" ]]; then
  if [[ "$RATE_LIMITED" == "false" ]]; then
    local_page=1
    all_open='[]'
    while :; do
      api_request "GET" "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues?state=open&per_page=100&page=$local_page"
      if [[ "$API_STATUS" != "200" ]]; then
        log "Could not fetch open issues (status: $API_STATUS). Dedup and close checks may be limited."
        break
      fi

      page_count="$(jq 'length' <<<"$API_BODY")"
      all_open="$(jq -s '.[0] + .[1]' <(printf '%s' "$all_open") <(printf '%s' "$API_BODY"))"

      if (( page_count < 100 )); then
        break
      fi
      local_page=$((local_page + 1))
    done

    while IFS=$'\t' read -r issue_number issue_created marker_file issue_title; do
      if [[ -z "$issue_number" || -z "$marker_file" ]]; then
        continue
      fi
      OPEN_ISSUE_NUMBER_BY_FILE["$marker_file"]="$issue_number"
      OPEN_ISSUE_CREATED_BY_FILE["$marker_file"]="$issue_created"
      OPEN_ISSUE_TITLE_BY_FILE["$marker_file"]="$issue_title"
    done < <(
      jq -r '.[]
        | select(.pull_request | not)
        | [
            (.number | tostring),
            (.created_at // ""),
            (try ((.body // "") | capture("<!-- content-freshness-gate:file=(?<file>[^>]+) -->").file) catch ""),
            (.title // "")
          ]
        | @tsv' <<<"$all_open"
    )

    debug "Managed open issues indexed: ${#OPEN_ISSUE_NUMBER_BY_FILE[@]}"
  fi
fi

if [[ "$CREATE_ISSUES" == "true" && "$DRY_RUN" == "false" ]]; then
  ensure_label "content-stale" "d73a4a" "Documentation is stale and needs refresh"
  ensure_label "content-warn" "fbca04" "Documentation is approaching stale threshold"
fi

NOW_UNIX="$(date +%s)"

for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    log "Skipping deleted/missing file: $file"
    continue
  fi

  FILES_SCANNED=$((FILES_SCANNED + 1))

  log_data="$(git log -1 --format="%ae|%ad" --date=unix -- "$file" 2>/dev/null || true)"
  if [[ -z "$log_data" ]]; then
    log "No git history for $file. Skipping."
    continue
  fi

  author_email="${log_data%%|*}"
  last_updated_unix="${log_data##*|}"

  if [[ ! "$last_updated_unix" =~ ^[0-9]+$ ]]; then
    log "Invalid git timestamp for $file. Skipping."
    continue
  fi

  age_days=$(( (NOW_UNIX - last_updated_unix) / 86400 ))
  if (( age_days < 0 )); then
    age_days=0
  fi

  last_updated_human="$(date -u -d "@$last_updated_unix" "+%Y-%m-%d %H:%M:%S UTC")"

  state="OK"
  if (( age_days > STALE_DAYS )); then
    state="STALE"
    STALE_DETECTED=$((STALE_DETECTED + 1))
  elif (( age_days > WARN_DAYS )); then
    state="WARNING"
    WARNING_DETECTED=$((WARNING_DETECTED + 1))
  fi

  log "Scanned: $file | age=${age_days}d | status=$state"

  open_issue_number="${OPEN_ISSUE_NUMBER_BY_FILE[$file]:-}"
  open_issue_created="${OPEN_ISSUE_CREATED_BY_FILE[$file]:-}"
  open_issue_title="${OPEN_ISSUE_TITLE_BY_FILE[$file]:-}"

  if [[ "$CLOSE_ON_UPDATE" == "true" && -n "$open_issue_number" && "$state" == "OK" ]]; then
    if close_issue_if_updated "$open_issue_number" "$file" "$open_issue_created" "$last_updated_unix"; then
      ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
      unset OPEN_ISSUE_NUMBER_BY_FILE["$file"]
      unset OPEN_ISSUE_CREATED_BY_FILE["$file"]
      unset OPEN_ISSUE_TITLE_BY_FILE["$file"]
    fi
  fi

  if [[ "$CREATE_ISSUES" != "true" ]]; then
    continue
  fi

  if [[ "$state" != "STALE" && "$state" != "WARNING" ]]; then
    continue
  fi

  if (( ISSUES_CREATED >= MAX_ISSUES_PER_RUN )); then
    log "Reached max-issues-per-run ($MAX_ISSUES_PER_RUN). Skipping new issue creation."
    continue
  fi

  assignee=""
  if [[ "$ASSIGN_LAST_AUTHOR" == "true" ]]; then
    assignee="$(resolve_assignee "$file" "$author_email")"
    if [[ -z "$assignee" ]]; then
      debug "No assignee resolved for $file"
    else
      debug "Resolved assignee for $file: $assignee"
    fi
  fi

  if [[ -n "$open_issue_number" ]]; then
    if [[ "$state" == "STALE" && "$open_issue_title" == "⚠️ Content review warning:"* ]]; then
      if update_issue_to_stale "$open_issue_number" "$file" "$last_updated_human" "$age_days" "$author_email" "$assignee"; then
        log "Escalated existing warning issue #$open_issue_number for $file"
      fi
    else
      log "Issue already exists for $file (#$open_issue_number). Skipping duplicate."
    fi
    continue
  fi

  if create_issue "$file" "$state" "$last_updated_human" "$age_days" "$author_email" "$assignee"; then
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
  fi
done

log "Summary"
log "- Files scanned: $FILES_SCANNED"
log "- Stale detected: $STALE_DETECTED"
log "- Warning detected: $WARNING_DETECTED"
log "- Issues created: $ISSUES_CREATED"
log "- Issues closed: $ISSUES_CLOSED"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "files-scanned=$FILES_SCANNED"
    echo "stale-detected=$STALE_DETECTED"
    echo "warning-detected=$WARNING_DETECTED"
    echo "issues-created=$ISSUES_CREATED"
    echo "issues-closed=$ISSUES_CLOSED"
  } >> "$GITHUB_OUTPUT"
fi
