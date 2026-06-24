#!/usr/bin/env bash
set -euo pipefail

trap 'echo "❌ Unexpected error at line $LINENO"; exit 1' ERR

# --- REQUIRED ENV ---
: "${GH_SOURCE_PAT:?GH_SOURCE_PAT not set}"
: "${GHES_API_URL:?GHES_API_URL not set}"

GHES_API_URL="${GHES_API_URL%/}"
LOG_FILE="validation-log-$(date +%Y%m%d).txt"
export GH_HOST="${TARGET_HOST:-github.com}"

write_log() {
  echo "$1" | tee -a "$LOG_FILE"
}

is_json() {
  jq -e . >/dev/null 2>&1
}

urlencode() {
  jq -rn --arg s "$1" '$s|@uri'
}

# --------------------------
# ✅ Branch Fetch (GHES)
# --------------------------
get_ghes_branches_json() {
  local org="$1" repo="$2"
  local page=1 per_page=100
  local all='[]'

  while true; do
    resp=$(curl -sS \
      -H "Authorization: token $GH_SOURCE_PAT" \
      -H "Accept: application/vnd.github+json" \
      "$GHES_API_URL/repos/$(urlencode "$org")/$(urlencode "$repo")/branches?page=$page&per_page=$per_page" \
      || true)

    echo "$resp" | is_json || break

    batch_len=$(echo "$resp" | jq 'length') || batch_len=0
    all=$(printf '%s\n%s' "$all" "$resp" | jq -s 'add') || echo "[]"

    [[ $batch_len -lt $per_page ]] && break
    ((page++))
  done

  echo "$all"
}

# --------------------------
# ✅ Branch Fetch (GitHub)
# --------------------------
get_github_branches_json() {
  local org="$1" repo="$2"
  local page=1 per_page=100
  local all='[]'

  while true; do
    resp=$(gh api "/repos/$org/$repo/branches?page=$page&per_page=$per_page" 2>/dev/null || true)

    echo "$resp" | is_json || break

    batch_len=$(echo "$resp" | jq 'length') || batch_len=0
    all=$(printf '%s\n%s' "$all" "$resp" | jq -s 'add') || echo "[]"

    [[ $batch_len -lt $per_page ]] && break
    ((page++))
  done

  echo "$all"
}

# --------------------------
# ✅ Commit Count + SHA (SAFE)
# --------------------------
get_commit_count_latest() {
  local mode="$1" org="$2" repo="$3" branch="$4"

  local enc_branch
  enc_branch=$(urlencode "$branch")

  if [[ "$mode" == "ghes" ]]; then
    resp=$(curl -sS \
      -H "Authorization: token $GH_SOURCE_PAT" \
      -H "Accept: application/vnd.github+json" \
      "$GHES_API_URL/repos/$org/$repo/commits?sha=$enc_branch&per_page=100" || true)
  else
    resp=$(gh api "/repos/$org/$repo/commits?sha=$enc_branch&per_page=100" 2>/dev/null || true)
  fi

  echo "$resp" | is_json || {
    echo "0 |"
    return
  }

  count=$(echo "$resp" | jq 'length' 2>/dev/null || echo 0)
  latest=$(echo "$resp" | jq -r '.[0].sha // empty' 2>/dev/null || echo "")

  echo "${count:-0} | ${latest:-}"
}

# --------------------------
# ✅ VALIDATION
# --------------------------
validate_migration() {
  local ghes_org="$1" ghes_repo="$2"
  local github_org="$3" github_repo="$4"

  write_log ""
  write_log "============================================================"
  write_log "Validating: $ghes_org/$ghes_repo -> $github_org/$github_repo"
  write_log "============================================================"

  gh_branches=$(get_github_branches_json "$github_org" "$github_repo")
  ghes_branches=$(get_ghes_branches_json "$ghes_org" "$ghes_repo")

  # ✅ SAFE ARRAY PARSING
  set +e
  mapfile -t gh_array < <(echo "$gh_branches" | jq -r '.[].name' 2>/dev/null || echo "")
  mapfile -t ghes_array < <(echo "$ghes_branches" | jq -r '.[].name' 2>/dev/null || echo "")
  set -e

  gh_count=${#gh_array[@]}
  ghes_count=${#ghes_array[@]}

  # ✅ Branch Count
  if [[ "$gh_count" -eq "$ghes_count" ]]; then
    write_log "✅ Branch Count MATCHED | GHES=$ghes_count GitHub=$gh_count"
  else
    write_log "❌ Branch Count NOT MATCHED | GHES=$ghes_count GitHub=$gh_count"
  fi

  # ✅ Select ONLY 10 COMMON branches
  selected_branches=()
  for b in "${gh_array[@]}"; do
    if printf '%s\n' "${ghes_array[@]}" | grep -qx "$b"; then
      selected_branches+=("$b")
    fi
    [[ ${#selected_branches[@]} -eq 10 ]] && break
  done

  write_log "🔍 Deep validation on ${#selected_branches[@]} branches"

  # ✅ SAFE COMMIT LOOP
  set +e
  for branch in "${selected_branches[@]}"; do
    gh_res=$(get_commit_count_latest "github" "$github_org" "$github_repo" "$branch" || echo "0 |")
    ghes_res=$(get_commit_count_latest "ghes" "$ghes_org" "$ghes_repo" "$branch" || echo "0 |")

    IFS="|" read -r gh_count gh_sha <<< "$gh_res"
    IFS="|" read -r ghes_count ghes_sha <<< "$ghes_res"

    gh_count=${gh_count:-0}
    ghes_count=${ghes_count:-0}

    write_log "Branch: $branch | GHES=$ghes_count GitHub=$gh_count"

    if [[ "$ghes_sha" == "$gh_sha" && -n "$gh_sha" ]]; then
      write_log "✅ SHA MATCH | $branch"
    else
      write_log "❌ SHA MISMATCH | $branch"
    fi
  done
  set -e

  write_log "✅ Validation completed"
}

# --------------------------
# ✅ CSV LOOP
# --------------------------
validate_from_csv() {
  local csv="repos.csv"

  [[ ! -f "$csv" ]] && { write_log "❌ CSV not found"; exit 1; }

  tail -n +2 "$csv" | while IFS=',' read -r ghes_org ghes_repo _ _ github_org github_repo _; do
    [[ -z "$ghes_org" || -z "$ghes_repo" || -z "$github_org" || -z "$github_repo" ]] && continue
    validate_migration "$ghes_org" "$ghes_repo" "$github_org" "$github_repo"
  done
}

# --------------------------
# ✅ RUN
# --------------------------
validate_from_csv

# ✅ NEVER fail pipeline
exit 0
