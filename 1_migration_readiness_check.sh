#!/usr/bin/env bash
# ------------------------------------------------------------
# GitLab Readiness Check Script
# - Reads inventory CSV
# - Checks:
#   1) Open Merge Requests
#   2) Running / Pending Pipelines
# ------------------------------------------------------------

set -euo pipefail
# -e: exit immediately if a command exits with a non-zero status.
# -u: treat unset variables as an error and exit.
# -o pipefail: if any command in a pipeline fails, the whole pipeline fails.

# --- Config ---> # Set script base path and load env from config.sh.
BASE_SCRIPT_LOC="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$BASE_SCRIPT_LOC/logs"
GITLAB_API_ENDPOINT="${SOURCE_GL_SERVER_URL}/api/v4"

RUN_TS="$(date +"%Y%m%d_%H%M%S")"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/migration_readiness_${RUN_TS}.log"

# Save all stdout+stderr to logfile AND still show on terminal
exec > >(tee -a "$LOG_FILE") 2>&1

# ------------------------------------------------------------
# Basic validations
# ------------------------------------------------------------
INVENTORY_FILE="${INVENTORY_FILE:-projects.csv}"
export INVENTORY_FILE
[[ -z "${INVENTORY_FILE:-}" ]] && echo "[ERROR] INVENTORY_FILE $INVENTORY_FILE not set" && exit 1
[[ ! -s "$INVENTORY_FILE" ]] && echo "[ERROR] Inventory file $INVENTORY_FILE  missing or empty" && exit 1
[[ -z "${GITLAB_API_ENDPOINT:-}" ]] && echo "[ERROR] GITLAB_API_ENDPOINT not set" && exit 1
[[ -z "${GITLAB_PAT:-}" ]] && echo "[ERROR] GITLAB_PAT not set" && exit 1

# ----------------------------
# Helper: URL encode project path (namespace/project)
# ----------------------------
urlencode() {
  # Uses jq to URL-encode safely
  printf '%s' "$1" | jq -Rr @uri
}

# ----------------------------
# Helper: Call GitLab API (single call) - used for project resolve only.
# Returns: <http_code>|<response_body>
# ----------------------------
curl_api() {
  local url="$1"
  local out code rc

  set +e
  out="$(curl -k -sS \
    -H "PRIVATE-TOKEN: $GITLAB_PAT" \
    -H "Content-Type: application/json" \
    "$url" -w "%{http_code}" 2>/dev/null)"
  rc=$?
  set -e

  # Curl/network failure (no HTTP response)
  if [[ $rc -ne 0 || -z "$out" ]]; then
    echo "[ERROR] GitLab REST API call failed: $url" >&2
    echo "FAILED|"
    return 0
  fi

  # Extract HTTP code (last 3 chars)
  code="${out: -3}"

  # Extract response body (everything except last 3 chars)
  out="${out::-3}"

  echo "${code}|${out}"
}

# ----------------------------
# Helper: Call GitLab API (single paged call).
# Writes body to a tmp file and extracts X-Next-Page from response headers.
# Returns: <http_code>|<next_page>|<body>
# ----------------------------
curl_api_paged() {
  local url="$1"
  local tmpfile headers http_code next_page body rc

  tmpfile="$(mktemp)"
  headers="$(mktemp)"

  set +e
  # -D headers  => write response headers to file
  # -o tmpfile  => write response body to file
  # -w          => print HTTP status code to stdout
  http_code="$(curl -k -sS \
    -H "PRIVATE-TOKEN: $GITLAB_PAT" \
    -H "Content-Type: application/json" \
    -D "$headers" \
    -o "$tmpfile" \
    -w "%{http_code}" \
    "$url" 2>/dev/null)"
  rc=$?
  set -e

  if [[ $rc -ne 0 || -z "$http_code" ]]; then
    echo "[ERROR] GitLab REST API call failed: $url" >&2
    rm -f "$tmpfile" "$headers"
    echo "FAILED||"
    return 0
  fi

  body="$(cat "$tmpfile")"

  # Extract X-Next-Page header value (case-insensitive grep)
  next_page="$(grep -i '^x-next-page:' "$headers" | awk -F': ' '{print $2}' | tr -d '\r' | tail -n 1)"

  rm -f "$tmpfile" "$headers"

  echo "${http_code}|${next_page}|${body}"
}

# ----------------------------
# Fetch all pages for a GitLab endpoint that returns a JSON array.
# Paginates using X-Next-Page header until no more pages remain.
# Input : base_url WITHOUT &page= (but may contain other query params)
# Output: combined JSON array (all pages merged)
#         OR "FAILED"       on curl/network error
#         OR "HTTP_<code>"  on non-200 HTTP response
# ----------------------------
fetch_all_pages_json() {
  local base_url="$1"
  local page="1"
  local next_page=""
  local combined='[]'

  while true; do
    local resp code body
    resp="$(curl_api_paged "${base_url}&page=${page}")"
    code="${resp%%|*}"
    resp="${resp#*|}"
    next_page="${resp%%|*}"
    body="${resp#*|}"

    # Network / curl failure
    if [[ "$code" == "FAILED" ]]; then
      echo "FAILED"
      return 0
    fi

    # Non-200 HTTP response
    if [[ "$code" != "200" ]]; then
      echo "HTTP_${code}"
      return 0
    fi

    # Append this page's results into the combined array
    combined="$(jq -s '.[0] + .[1]' <(echo "$combined") <(echo "$body") 2>/dev/null || echo "$combined")"

    # Stop pagination when X-Next-Page is empty (last page reached)
    if [[ -z "$next_page" ]]; then
      break
    fi

    page="$next_page"
  done

  echo "$combined"
}

# ----------------------------
# Read CSV header and find indexes for Namespace & Project
# ----------------------------
header="$(head -n 1 "$INVENTORY_FILE" | tr -d '\r')"
IFS=',' read -r -a cols <<< "$header"

# Find column index for new projects.csv format
NS_IDX=""
PR_IDX=""
URL_IDX=""

for i in "${!cols[@]}"; do
  # Trim spaces and strip quotes
  h="$(echo "${cols[$i]}" | xargs)"
  h="${h%\"}"; h="${h#\"}"

  [[ "$h" == "group-path" ]] && NS_IDX="$i"
  [[ "$h" == "project"    ]] && PR_IDX="$i"
  [[ "$h" == "url"        ]] && URL_IDX="$i"
done

# If required headers missing, fail early
[[ -n "$NS_IDX" ]] || { echo "[ERROR] Missing required header: group-path"; exit 1; }
[[ -n "$PR_IDX" ]] || { echo "[ERROR] Missing required header: project"; exit 1; }
[[ -n "$URL_IDX" ]] || { echo "[ERROR] Missing required header: url"; exit 1; }

# ----------------------------
# Summary arrays
# ----------------------------
active_mr_summary=()
active_pipeline_summary=()

# Flags to track failures
mr_check_failed=false
pipeline_check_failed=false
project_check_failed=false

# Counters
total=0
skipped=0

echo
echo "Scanning GitLab projects for open Merge Requests and running/pending pipelines..."
echo

# ----------------------------
# Process each CSV row (skip header)
# ----------------------------
while IFS= read -r raw; do
  line="$(echo "$raw" | tr -d '\r')"      # remove CR if Windows file
  IFS=',' read -r -a flds <<< "$line"       # simple CSV split

  # Read group-path, project and project URL from projects.csv
  ns="$(echo "${flds[$NS_IDX]:-}" | xargs)"
  pr="$(echo "${flds[$PR_IDX]:-}" | xargs)"
  full_url="$(echo "${flds[$URL_IDX]:-}" | xargs)"

  # Strip surrounding quotes
  ns="${ns%\"}"; ns="${ns#\"}"
  pr="${pr%\"}"; pr="${pr#\"}"
  full_url="${full_url%\"}"; full_url="${full_url#\"}"

  total=$((total + 1))

  # Skip if missing
  if [[ -z "$ns" || -z "$pr" || -z "$full_url" ]]; then
      skipped=$((skipped + 1))
      echo "[WARN] Row: $total - Skipping due to missing values: group-path='$ns' project='$pr' url='$full_url'"
      continue
  fi

  clean_url="${full_url%%\?*}"
  clean_url="${clean_url%.git}"

  path_part="$(echo "$clean_url" | sed -E 's#https?://[^/]+/##')"

  resolved_ns="$(dirname "$path_part")"
  resolved_pr="$(basename "$path_part")"

  echo "[INFO] Resolved namespace: '$ns' -> '$resolved_ns'"
  echo "[INFO] Resolved project : '$pr' -> '$resolved_pr'"

  ns="$resolved_ns"
  pr="$resolved_pr"

  project_path="$ns/$pr"
  enc_project="$(urlencode "$project_path")"

  # ----------------------------
  # Resolve project (needed for project id + canonical name)
  # ----------------------------
  proj_resp="$(curl_api "$GITLAB_API_ENDPOINT/projects/$enc_project")"
  proj_code="${proj_resp%%|*}"
  proj_body="${proj_resp#*|}"

  if [[ "$proj_code" != "200" ]]; then
    project_check_failed=true
    echo "[ERROR] Failed to resolve project '$project_path' (HTTP $proj_code)"
    continue
  fi

  # Use GitLab's path_with_namespace if possible; else fallback
  proj_display="$(echo "$proj_body" | jq -r '.path_with_namespace // empty' 2>/dev/null || true)"
  [[ -z "$proj_display" || "$proj_display" == "null" ]] && proj_display="$project_path"

  # ----------------------------
  # 1) Open Merge Requests (state=opened) - FETCH ALL PAGES
  # ----------------------------
  mr_base="$GITLAB_API_ENDPOINT/projects/$enc_project/merge_requests?state=opened&per_page=100"
  mr_body="$(fetch_all_pages_json "$mr_base")"

  if [[ "$mr_body" == "FAILED" ]]; then
    mr_check_failed=true
    echo "[ERROR] Failed to retrieve merge requests for '$project_path' (network/curl failure)"
  elif [[ "$mr_body" == HTTP_* ]]; then
    mr_check_failed=true
    echo "[ERROR] Failed to retrieve merge requests for '$project_path' (${mr_body/HTTP_/HTTP })"
  else
    mr_count="$(echo "$mr_body" | jq 'length' 2>/dev/null || echo 0)"
    if [[ "$mr_count" -gt 0 ]]; then
      while IFS='|' read -r iid title state url; do
        [[ -z "$iid" || "$iid" == "null" ]] && continue
        active_mr_summary+=("$proj_display|!$iid|$state|$title|$url")
      done < <(echo "$mr_body" | jq -r '.[]? | "\(.iid)|\(.title)|\(.state)|\(.web_url)"' 2>/dev/null)
    fi
  fi

  # ----------------------------
  # 2) Pipelines running + pending - FETCH ALL PAGES
  # ----------------------------
  run_base="$GITLAB_API_ENDPOINT/projects/$enc_project/pipelines?scope=running&per_page=100"
  pend_base="$GITLAB_API_ENDPOINT/projects/$enc_project/pipelines?scope=pending&per_page=100"

  run_body="$(fetch_all_pages_json "$run_base")"
  pend_body="$(fetch_all_pages_json "$pend_base")"

  # If both failed -> mark failure
  if [[ "$run_body" == "FAILED" && "$pend_body" == "FAILED" ]]; then
    pipeline_check_failed=true
    echo "[ERROR] Failed to retrieve pipelines for '$project_path' (network/curl failure)"
  else
    # If one failed or returned non-200, treat it as empty array to continue
    [[ "$run_body"  == "FAILED" || "$run_body"  == HTTP_* ]] && run_body='[]'
    [[ "$pend_body" == "FAILED" || "$pend_body" == HTTP_* ]] && pend_body='[]'

    # Combine running + pending arrays
    combined="$(jq -s '.[0] + .[1]' <(echo "$run_body") <(echo "$pend_body") 2>/dev/null || echo '[]')"
    pcount="$(echo "$combined" | jq 'length' 2>/dev/null || echo 0)"

    if [[ "$pcount" -gt 0 ]]; then
      while IFS='|' read -r id status ref url; do
        [[ -z "$id" || "$id" == "null" ]] && continue
        active_pipeline_summary+=("$proj_display|$id|$status|$url")
      done < <(echo "$combined" | jq -r '.[]? | "\(.id)|\(.status)|\(.ref)|\(.web_url)"' 2>/dev/null)
    fi
  fi

done < <(tail -n +2 "$INVENTORY_FILE")

# ----------------------------
# Print Summary
# ----------------------------
echo
echo "Pre-Migration Validation Summary (GitLab)"
echo "========================================"
echo "Total rows processed : $total"
echo "Skipped rows         : $skipped"
echo

# Merge Requests summary
if [[ "$mr_check_failed" != true ]]; then
  if [[ ${#active_mr_summary[@]} -gt 0 ]]; then
    echo -e "\033[33m[WARNING] Detected Open Merge Request(s):\033[0m"
    for entry in "${active_mr_summary[@]}"; do
      IFS='|' read -r project mrid state title url <<< "$entry"
      echo "Project: $project | Title: $title | State: $state"
      echo "MR URL: $url"
      echo ""
    done
  else
    echo -e "\033[32mMerge Request Summary --> No Open Merge Requests\033[0m"
    echo ""
  fi
else
  echo -e "\033[31m[ERROR] Merge request checks failed for one or more projects.\033[0m"
  echo ""
fi

# Pipelines summary
if [[ "$pipeline_check_failed" != true ]]; then
  if [[ ${#active_pipeline_summary[@]} -gt 0 ]]; then
    echo -e "\033[33m[WARNING] Detected Running/Pending Pipeline(s):\033[0m"
    for entry in "${active_pipeline_summary[@]}"; do
      IFS='|' read -r project pid status url <<< "$entry"
      echo "Project: $project | Pipeline ID: $pid | Status: $status"
      echo "Pipeline URL: $url"
      echo ""
    done
  else
    echo -e "\033[32mPipeline Summary --> No Running/Pending Pipelines\033[0m"
    echo ""
  fi
else
  echo -e "\033[31m[ERROR] Pipeline checks failed for one or more projects.\033[0m"
  echo ""
fi

# ----------------------------
# Final decision
# ----------------------------
hasActiveItems=false
[[ ${#active_mr_summary[@]} -gt 0 || ${#active_pipeline_summary[@]} -gt 0 ]] && hasActiveItems=true

hasFailures=false
[[ "$project_check_failed" = true || "$mr_check_failed" = true || "$pipeline_check_failed" = true ]] && hasFailures=true

if [[ "$hasFailures" = true && "$hasActiveItems" = false ]]; then
  echo -e "\033[31mValidation checks could not be completed due to API failures. Please review errors before proceeding.\033[0m"
  exit 1
elif [[ "$hasFailures" = true && "$hasActiveItems" = true ]]; then
  echo -e "\033[33mActive items detected, but some validation checks failed. Review warnings and errors before proceeding.\033[0m"
  exit 0
elif [[ "$hasFailures" = false && "$hasActiveItems" = true ]]; then
  echo -e "\033[33mOpen merge requests or active pipelines found. Continue with migration if you have reviewed and are comfortable proceeding.\033[0m"
  exit 0
else
  echo -e "\033[32mNo open merge requests or active pipelines detected. You can proceed with migration.\033[0m"
  exit 0
fi
 
