#!/usr/bin/env bash

set -euo pipefail
trap 'echo "❌ Unexpected error at line $LINENO"; exit 1' ERR

: "${GH_SOURCE_PAT:?GH_SOURCE_PAT not set}"
: "${GHES_API_URL:?GHES_API_URL not set}"

LOG_FILE="validation-log-$(date +%Y%m%d).txt"
export GH_HOST="${TARGET_HOST:-github.com}"

write_log() {
  echo "$1" | tee -a "$LOG_FILE"
}

# ------------------------------
# SAFE JSON CHECK
# ------------------------------
is_json_array() {
  jq -e 'type=="array"' >/dev/null 2>&1
}

# ------------------------------
# GHES BRANCH FETCH (SAFE)
# ------------------------------
get_ghes_branches_json() {
  local org="$1" repo="$2"
  local page=1 per_page=100
  local all='[]'

  while true; do
    local resp
    resp=$(curl -sS \
      -H "Authorization: token $GH_SOURCE_PAT" \
      -H "Accept: application/vnd.github+json" \
      "$GHES_API_URL/repos/$org/$repo/branches?page=$page&per_page=$per_page" || true)

    if ! echo "$resp" | is_json_array; then
      write_log "❌ GHES API ERROR"
      break
    fi

    local len
    len=$(echo "$resp" | jq 'length')

    all=$(jq -s 'add' <<<"$all"$'\n'"$resp")

    [[ "$len" -lt "$per_page" ]] && break
    ((page++))
  done

  echo "$all"
}

# ------------------------------
# GITHUB BRANCH FETCH (SAFE)
# ------------------------------
get_github_branches_json() {
  local org="$1" repo="$2"
  local page=1 per_page=100
  local all='[]'

  while true; do
    local resp
    resp=$(gh api "/repos/$org/$repo/branches?page=$page&per_page=$per_page" 2>/dev/null || true)

    if ! echo "$resp" | is_json_array; then
      write_log "❌ GitHub API ERROR: $(echo "$resp" | jq -r '.message // "unknown"')"
      break
    fi

    local len
    len=$(echo "$resp" | jq 'length')

    all=$(jq -s 'add' <<<"$all"$'\n'"$resp")

    [[ "$len" -lt "$per_page" ]] && break
    ((page++))
  done

  echo "$all"
}

# ------------------------------
# COMMIT COUNT + SHA (SAFE)
# ------------------------------
get_commit_info() {
  local mode="$1" org="$2" repo="$3" branch="$4"

  local resp
  if [[ "$mode" == "ghes" ]]; then
    resp=$(curl -sS \
      -H "Authorization: token $GH_SOURCE_PAT" \
      -H "Accept: application/vnd.github+json" \
      "$GHES_API_URL/repos/$org/$repo/commits?sha=$(printf '%s' "$branch" | jq -s -R -r @uri)&per_page=100" \
      || true)
  else
    resp=$(gh api "/repos/$org/$repo/commits?sha=$branch&per_page=100" 2>/dev/null || true)
  fi

  if ! echo "$resp" | is_json_array; then
    echo "0|"
    return
  fi

  local count sha
  count=$(echo "$resp" | jq 'length' 2>/dev/null || echo 0)
  sha=$(echo "$resp" | jq -r '.[0].sha // empty' 2>/dev/null || echo "")

  echo "${count:-0}|${sha:-}"
}

# ------------------------------
# VALIDATION
# ------------------------------
validate_migration() {
  local ghes_org="$1" ghes_repo="$2"
  local github_org="$3" github_repo="$4"

  write_log ""
  write_log "============================================================"
  write_log "Validating: $ghes_org/$ghes_repo -> $github_org/$github_repo"
  write_log "============================================================"

  local gh_json ghes_json
  gh_json=$(get_github_branches_json "$github_org" "$github_repo")
  ghes_json=$(get_ghes_branches_json "$ghes_org" "$ghes_repo")

  # SAFE ARRAY EXTRACTION
  set +e
  mapfile -t gh_array < <(echo "$gh_json" | jq -r '.[].name' 2>/dev/null)
  mapfile -t ghes_array < <(echo "$ghes_json" | jq -r '.[].name' 2>/dev/null)
  set -e

  local gh_count="${#gh_array[@]}"
  local ghes_count="${#ghes_array[@]}"

  if [[ "$gh_count" -eq "$ghes_count" ]]; then
    write_log "✅ Branch Count MATCHED | GHES=$ghes_count GitHub=$gh_count"
  else
    write_log "❌ Branch Count NOT MATCHED | GHES=$ghes_count GitHub=$gh_count"
  fi

  # ------------------------------
  # COMMON BRANCHES - PICK 10
  # ------------------------------
  local selected=()

  for b in "${gh_array[@]}"; do
    if printf '%s\n' "${ghes_array[@]}" | grep -qx "$b"; then
      selected+=("$b")
    fi
    [[ "${#selected[@]}" -eq 10 ]] && break
  done

  write_log "🔍 Deep validation on ${#selected[@]} branches"

  # ------------------------------
  # COMMIT VALIDATION (SAFE)
  # ------------------------------
  set +e
  for branch in "${selected[@]}"; do
    gh_res=$(get_commit_info "github" "$github_org" "$github_repo" "$branch")
    ghes_res=$(get_commit_info "ghes" "$ghes_org" "$ghes_repo" "$branch")

    IFS="|" read -r gh_count gh_sha <<<"$gh_res"
    IFS="|" read -r ghes_count ghes_sha <<<"$ghes_res"

    gh_count="${gh_count:-0}"
    ghes_count="${ghes_count:-0}"

    write_log "Branch: $branch | GHES=$ghes_count GitHub=$gh_count"

    if [[ "$gh_sha" == "$ghes_sha" && -n "$gh_sha" ]]; then
      write_log "✅ SHA MATCH | $branch"
    else
      write_log "❌ SHA MISMATCH | $branch"
    fi
  done
  set -e

  write_log "✅ Validation completed"
}

# ------------------------------
# CSV LOOP
# ------------------------------
validate_from_csv() {
  local csv="repos.csv"

  [[ ! -f "$csv" ]] && { write_log "❌ CSV not found"; exit 1; }

  tail -n +2 "$csv" | while IFS=',' read -r ghes_org ghes_repo _ _ github_org github_repo _; do
    [[ -z "$ghes_org" || -z "$ghes_repo" || -z "$github_org" || -z "$github_repo" ]] && continue

    validate_migration "$ghes_org" "$ghes_repo" "$github_org" "$github_repo"
  done
}

# ------------------------------
# RUN
# ------------------------------
validate_from_csv

# ✅ NEVER FAIL PIPELINE
exit 0
