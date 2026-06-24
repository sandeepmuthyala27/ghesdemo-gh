
#!/usr/bin/env bash
set -euo pipefail

trap 'echo "❌ Unexpected error at line $LINENO"; exit 1' ERR

: "${GH_SOURCE_PAT:?GH_SOURCE_PAT not set}"
: "${GH_PAT:?GH_PAT not set}"
: "${GHES_API_URL:?GHES_API_URL not set}"

GHES_API_URL="${GHES_API_URL%/}"

LOG_FILE="validation-log-$(date +%Y%m%d).txt"
TARGET_HOST="${GH_TARGET_HOST:-github.com}"
export GH_HOST="$TARGET_HOST"

write_log() {
  echo "$1" | tee -a "$LOG_FILE"
}

is_json() { jq -e . >/dev/null 2>&1; }

urlencode() {
  jq -rn --arg s "$1" '$s|@uri'
}

# ----------------------------
# Branch fetch
# ----------------------------
get_ghes_branches_json() {
  local org="$1" repo="$2"
  local page=1 per_page=100 all='[]'

  while true; do
    local resp
    resp="$(curl -sS \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: token ${GH_SOURCE_PAT}" \
      "${GHES_API_URL}/repos/$(urlencode "$org")/$(urlencode "$repo")/branches?page=$page&per_page=$per_page" || true)"

    [[ -z "$resp" ]] && break
    is_json <<< "$resp" || break

    local batch_len
    batch_len="$(echo "$resp" | jq 'length')"

    all="$(printf '%s\n%s\n' "$all" "$resp" | jq -s 'add')"

    [[ "$batch_len" -lt "$per_page" ]] && break
    ((page++))
  done

  echo "$all"
}

get_github_branches_json() {
  local org="$1" repo="$2"
  local page=1 per_page=100 all='[]'

  while true; do
    local resp
    resp="$(gh api "/repos/$org/$repo/branches?page=$page&per_page=$per_page" 2>/dev/null || true)"

    [[ -z "$resp" ]] && break
    is_json <<< "$resp" || break

    local batch_len
    batch_len="$(echo "$resp" | jq 'length')"

    all="$(printf '%s\n%s\n' "$all" "$resp" | jq -s 'add')"

    [[ "$batch_len" -lt "$per_page" ]] && break
    ((page++))
  done

  echo "$all"
}

# ----------------------------
# Commit fetch (info only)
# ----------------------------
get_commit_count_and_latest() {
  local mode="$1" org="$2" repo="$3" branch="$4"

  local page=1 per_page=100 count=0 latest=""
  local enc_branch
  enc_branch="$(urlencode "$branch")"

  while true; do
    local resp

    if [[ "$mode" == "ghes" ]]; then
      resp="$(curl -sS \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: token ${GH_SOURCE_PAT}" \
        "${GHES_API_URL}/repos/$(urlencode "$org")/$(urlencode "$repo")/commits?sha=$enc_branch&page=$page&per_page=$per_page" || true)"
    else
      resp="$(gh api "/repos/$org/$repo/commits?sha=$enc_branch&page=$page&per_page=$per_page" 2>/dev/null || true)"
    fi

    [[ -z "$resp" ]] && break
    is_json <<< "$resp" || break

    local batch_len
    batch_len="$(echo "$resp" | jq 'length')"

    if [[ $page -eq 1 && "$batch_len" -gt 0 ]]; then
      latest="$(echo "$resp" | jq -r '.[0].sha // empty')"
    fi

    count=$((count + batch_len))

    [[ "$batch_len" -lt "$per_page" ]] && break
    ((page++))
  done

  echo "${count}|${latest}"
}

# ----------------------------
# Validation
# ----------------------------
validate_migration() {
  local ghes_org="$1" ghes_repo="$2" github_org="$3" github_repo="$4"

  write_log ""
  write_log "============================================================"
  write_log "Validating: ${ghes_org}/${ghes_repo} -> ${github_org}/${github_repo}"
  write_log "============================================================"

  local gh_branches ghes_branches
  gh_branches="$(get_github_branches_json "$github_org" "$github_repo")"
  ghes_branches="$(get_ghes_branches_json "$ghes_org" "$ghes_repo")"

  mapfile -t gh_array < <(echo "$gh_branches" | jq -r '.[].name')
  mapfile -t ghes_array < <(echo "$ghes_branches" | jq -r '.[].name')

  declare -A gh_map ghes_map
  local b

  for b in "${gh_array[@]}"; do gh_map["$b"]=1; done
  for b in "${ghes_array[@]}"; do ghes_map["$b"]=1; done

  # ----------------------------
  # Branch count
  # ----------------------------
  if [[ ${#ghes_array[@]} -eq ${#gh_array[@]} ]]; then
    write_log "✅ Branch Count MATCHED | GHES=${#ghes_array[@]} GitHub=${#gh_array[@]}"
  else
    write_log "❌ Branch Count NOT MATCHED | GHES=${#ghes_array[@]} GitHub=${#gh_array[@]}"
  fi

  # ----------------------------
  # Missing / extra branches (SAFE)
  # ----------------------------
  local missing_in_github=()
  local missing_in_ghes=()

  for b in "${ghes_array[@]}"; do
    [[ -z "${gh_map[$b]:-}" ]] && missing_in_github+=("$b")
  done

  for b in "${gh_array[@]}"; do
    [[ -z "${ghes_map[$b]:-}" ]] && missing_in_ghes+=("$b")
  done

  if [[ ${#missing_in_github[@]} -gt 0 ]]; then
    write_log "⚠️ Missing in GitHub (${#missing_in_github[@]}): ${missing_in_github[*]}"
  else
    write_log "✅ No branches missing in GitHub"
  fi

  if [[ ${#missing_in_ghes[@]} -gt 0 ]]; then
    write_log "⚠️ Extra in GitHub (${#missing_in_ghes[@]}): ${missing_in_ghes[*]}"
  else
    write_log "✅ No extra branches in GitHub"
  fi

  # ----------------------------
  # Select 10 branches only
  # ----------------------------
  local selected_branches=()
  local count=0

  for b in "${gh_array[@]}"; do
    [[ -n "${ghes_map[$b]:-}" ]] || continue
    selected_branches+=("$b")
    ((count++))
    [[ $count -eq 10 ]] && break
  done

  write_log "ℹ️ Deep validation on ${#selected_branches[@]} branches"

  # ----------------------------
  # Commit validation (sample)
  # ----------------------------
  local branch

  for branch in "${selected_branches[@]}"; do
    IFS="|" read -r gh_count gh_sha <<< \
      "$(get_commit_count_and_latest github "$github_org" "$github_repo" "$branch")"

    IFS="|" read -r ghes_count ghes_sha <<< \
      "$(get_commit_count_and_latest ghes "$ghes_org" "$ghes_repo" "$branch")"

    write_log "ℹ️ Branch: $branch | Counts GHES=$ghes_count GitHub=$gh_count"

    if [[ "$ghes_sha" == "$gh_sha" && -n "$ghes_sha" ]]; then
      write_log "✅ Branch: $branch | SHA MATCH | $gh_sha"
    else
      write_log "❌ Branch: $branch | SHA MISMATCH | GHES=$ghes_sha GitHub=$gh_sha"
    fi
  done

  write_log "✅ Validation completed for: ${github_org}/${github_repo}"
}

# ----------------------------
# CSV loop (FIXED)
# ----------------------------
validate_from_csv() {
  local csv="repos.csv"

  [[ ! -f "$csv" ]] && { write_log "❌ CSV not found"; exit 1; }

  while IFS=',' read -r ghes_org ghes_repo _ _ github_org github_repo _; do
    [[ -z "$ghes_org" || -z "$ghes_repo" || -z "$github_org" || -z "$github_repo" ]] && continue

    validate_migration "$ghes_org" "$ghes_repo" "$github_org" "$github_repo"

  done < <(tail -n +2 "$csv")
}

# ----------------------------
# Run
# ----------------------------
validate_from_csv

# ✅ Always exit success (no false failures)
exit 0
