#!/usr/bin/env bash
# sync-repo.sh — operações git determinísticas para /knowledge-sync-all
# Subcomandos: prepare, validate-links, has-diff, commit-pr, restore-clean, preserve, status
set -euo pipefail

STATE_DIR="${KNOWLEDGE_SYNC_STATE_DIR:-/tmp}"
REPOS_ROOT="${KNOWLEDGE_SYNC_REPOS_ROOT:-$HOME/code}"
INTEGRATION_BRANCH="${KNOWLEDGE_SYNC_BRANCH:-dev}"

usage() {
  cat >&2 <<EOF
uso: sync-repo.sh <subcomando> <repo> [args]

subcomandos:
  prepare <repo>             stash + checkout $INTEGRATION_BRANCH + pull
  validate-links <repo>      verifica wikilinks + cross_refs (read-only)
  has-diff <repo>            exit 0 se tem diff em Claude/, 1 caso contrário
  commit-pr <repo>           cria branch + commit + push + gh pr create
  restore-clean <repo>       checkout original + stash pop (workspace deve estar limpo)
  preserve <repo> <reason>   salva patch + relatório; NÃO mexe em git state
  status <repo>              diagnóstico
EOF
  exit 2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Caminhos auxiliares (placeholders preenchidos nas próximas tasks)
state_file() { echo "$STATE_DIR/knowledge-sync-$1.json"; }
report_file() { echo "$STATE_DIR/knowledge-sync-$1-report.md"; }
patch_file() { echo "$STATE_DIR/knowledge-sync-$1-rejected.patch"; }
preserved_file() { echo "$STATE_DIR/knowledge-sync-$1-preserved.txt"; }
repo_path() { echo "$REPOS_ROOT/$1"; }

cmd_status() {
  local repo="$1"
  local path; path=$(repo_path "$repo")
  cd "$path"
  echo "repo: $repo"
  echo "path: $path"
  echo "branch: $(git branch --show-current)"
  if [ -z "$(git status --porcelain)" ]; then
    echo "dirty: no"
  else
    echo "dirty: yes"
    git status --short | sed 's/^/  /'
  fi
  echo "last commit: $(git log -1 --oneline)"
  if [ -f "$(state_file "$repo")" ]; then
    echo "state_file: present ($(state_file "$repo"))"
  else
    echo "state_file: absent"
  fi
  echo "stashes: $(git stash list | wc -l)"
}

cmd_has_diff() {
  local repo="$1"
  cd "$(repo_path "$repo")"
  if [ -n "$(git status --porcelain Claude/)" ]; then
    exit 0
  else
    exit 1
  fi
}

# Escape para JSON: barra invertida, aspas, controle. Suficiente p/ valores que controlamos.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

write_state() {
  local repo="$1"; shift
  local file; file=$(state_file "$repo")
  local tmp="$file.tmp.$$"
  {
    echo "{"
    echo "  \"repo\": \"$(json_escape "$repo")\","
    echo "  \"timestamp\": \"$(date +%FT%T)\","
    local first=true
    for kv in "$@"; do
      local k="${kv%%=*}"
      local v="${kv#*=}"
      if $first; then
        first=false
      else
        echo ","
      fi
      # Booleanos e null sem aspas, resto com aspas
      if [ "$v" = "true" ] || [ "$v" = "false" ] || [ "$v" = "null" ]; then
        printf '  "%s": %s' "$(json_escape "$k")" "$v"
      else
        printf '  "%s": "%s"' "$(json_escape "$k")" "$(json_escape "$v")"
      fi
    done
    echo
    echo "}"
  } > "$tmp"
  mv "$tmp" "$file"
}

read_state() {
  local repo="$1" field="$2"
  local file; file=$(state_file "$repo")
  [ -f "$file" ] || die "state file não existe: $file"
  # Parse: strip "field": prefix, trailing comma, surrounding quotes (if any).
  # Handles both string values ("foo") and boolean/null values (true/false/null).
  grep -E "\"$field\":" "$file" | head -1 \
    | sed -E "s/.*\"$field\":[[:space:]]*//" \
    | sed -E 's/,[[:space:]]*$//' \
    | sed -E 's/^"(.*)"$/\1/'
}

cmd_prepare() {
  local repo="$1"
  cd "$(repo_path "$repo")"

  local original_branch original_head
  original_branch=$(git branch --show-current) || die "não consegui ler branch atual"
  original_head=$(git rev-parse HEAD)

  local had_stash=false stash_ref="" stash_sha=""
  if [ -n "$(git status --porcelain)" ]; then
    local stash_msg="knowledge-sync-all $(date +%FT%T)"
    git stash push -u -m "$stash_msg" > /dev/null || die "stash falhou"
    had_stash=true
    stash_ref="stash@{0}"
    stash_sha=$(git rev-parse stash@{0})
  fi

  git fetch origin "$INTEGRATION_BRANCH" || die "fetch origin $INTEGRATION_BRANCH falhou (stash preservado se existia)"

  local dev_head_before
  dev_head_before=$(git rev-parse "origin/$INTEGRATION_BRANCH" 2>/dev/null || echo "none")

  if [ "$original_branch" != "$INTEGRATION_BRANCH" ]; then
    git checkout "$INTEGRATION_BRANCH" || die "checkout $INTEGRATION_BRANCH falhou"
  fi

  git pull --ff-only origin "$INTEGRATION_BRANCH" || die "pull --ff-only falhou ($INTEGRATION_BRANCH local divergiu — resolver manualmente)"

  local dev_head_after
  dev_head_after=$(git rev-parse HEAD)

  write_state "$repo" \
    "original_branch=$original_branch" \
    "original_head=$original_head" \
    "had_stash=$had_stash" \
    "stash_ref=$stash_ref" \
    "stash_sha=$stash_sha" \
    "dev_head_before=$dev_head_before" \
    "dev_head_after=$dev_head_after"

  echo "prepare OK: $repo (branch=$INTEGRATION_BRANCH, had_stash=$had_stash)"
}

cmd_validate_links() {
  local repo="$1"
  local path; path=$(repo_path "$repo")
  cd "$path"

  local -a broken_intra=() broken_cross_ref=() broken_cross_repo=()

  # 1. Wikilinks intra-vault: para cada [[X]], verifica se existe uma nota X.md
  #    em QUALQUER subpasta do vault (o Obsidian resolve [[X]] por basename, não
  #    só no nível raiz — ex.: post-mortems/X.md resolve [[X]]).
  #    Ignora: Claude/_templates/ (templates com placeholders intencionais)
  #            e [[X]] dentro de `backticks` (exemplos pedagógicos em code spans).
  if [ -d Claude ]; then
    # Índice de basenames de todas as notas (qualquer subpasta, exceto _templates).
    declare -A note_index=()
    while IFS= read -r -d '' f; do
      note_index["$(basename "$f" .md)"]=1
    done < <(find Claude -type f -name '*.md' -not -path '*/_templates/*' -print0 2>/dev/null)

    while IFS= read -r match; do
      local file="${match%%:*}"
      local link="${match#*:}"
      [ -n "${note_index[$link]:-}" ] || broken_intra+=("$(printf '{"file":"%s","link":"%s"}' "$(basename "$file")" "$link")")
    done < <(find Claude -type f -name '*.md' -not -path '*/_templates/*' -print0 2>/dev/null \
      | xargs -0 awk '
        {
          line = $0
          gsub(/`[^`]*`/, "", line)
          while (match(line, /\[\[[a-zA-Z0-9_-]+\]\]/)) {
            link = substr(line, RSTART+2, RLENGTH-4)
            print FILENAME ":" link
            line = substr(line, RSTART + RLENGTH)
          }
        }
      ')
  fi

  # 2. cross_ref_note no .knowledge-sync.yml
  local cfg="Claude/.knowledge-sync.yml"
  if [ -f "$cfg" ]; then
    while IFS= read -r note; do
      [ -z "$note" ] && continue
      [ "$note" = "null" ] && continue
      [ -f "Claude/$note" ] || broken_cross_ref+=("$(printf '"%s"' "$note")")
    done < <(grep -E "cross_ref_note:" "$cfg" | sed -E 's/.*cross_ref_note:[[:space:]]*//;s/[[:space:]]*#.*//;s/[[:space:]]*$//')

    # 3. Sister paths existem?
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      [ "$p" = "null" ] && continue
      # path relativo a $path
      [ -d "$path/$p" ] || broken_cross_repo+=("$(printf '"%s"' "$p")")
    done < <(grep -E "^\s+path:" "$cfg" | sed -E 's/.*path:[[:space:]]*//;s/[[:space:]]*#.*//;s/[[:space:]]*$//')
  fi

  local ok=true
  if [ ${#broken_intra[@]} -gt 0 ] || [ ${#broken_cross_ref[@]} -gt 0 ] || [ ${#broken_cross_repo[@]} -gt 0 ]; then
    ok=false
  fi

  # Imprime JSON
  {
    echo "{"
    echo "  \"repo\": \"$repo\","
    echo "  \"ok\": $ok,"
    echo "  \"broken_intra\": [$(IFS=,; echo "${broken_intra[*]:-}")],"
    echo "  \"broken_cross_ref\": [$(IFS=,; echo "${broken_cross_ref[*]:-}")],"
    echo "  \"broken_cross_repo\": [$(IFS=,; echo "${broken_cross_repo[*]:-}")]"
    echo "}"
  }

  $ok && exit 0 || exit 1
}

cmd_preserve() {
  local repo="$1" reason="${2:-unspecified}"
  cd "$(repo_path "$repo")"
  local patch; patch=$(patch_file "$repo")
  local report; report=$(preserved_file "$repo")
  local sf; sf=$(state_file "$repo")

  git diff Claude/ > "$patch" 2>/dev/null || true
  git diff --cached Claude/ >> "$patch" 2>/dev/null || true

  local branch dirty stash_info original_branch="unknown"
  branch=$(git branch --show-current)
  dirty=$(git status --short || echo "")
  # sed -n '1,3p' lê o stream inteiro (não fecha o pipe cedo como 'head -3'):
  # evita SIGPIPE no 'git stash list' sob set -e/pipefail em repos com >3 stashes.
  stash_info=$(git stash list | sed -n '1,3p' || true)
  { [ -f "$sf" ] && original_branch=$(read_state "$repo" original_branch); } || true

  cat > "$report" <<EOF
Repo: $repo
Motivo: $reason
Timestamp: $(date +%FT%T)

State atual:
  branch: $branch
  original_branch (do prepare): $original_branch
  uncommitted:
$(echo "$dirty" | sed 's/^/    /')
  stashes:
$(echo "$stash_info" | sed 's/^/    /')

Arquivos preservados:
  patch:  $patch
  state:  $sf (mantido)

Pra recuperar manualmente:
  cd $(repo_path "$repo")

  # Opção A — descartar mudanças do sync:
  git restore Claude/
  git checkout $original_branch
  git stash pop      # se had_stash=true

  # Opção B — manter e revisar:
  # você está em $branch com diff em Claude/. Decida o que fazer.
EOF

  echo "preserve OK: $repo (patch=$patch, report=$report)"
}

cmd_commit_pr() {
  local repo="$1"
  cd "$(repo_path "$repo")"

  local sf; sf=$(state_file "$repo")
  [ -f "$sf" ] || die "state file ausente — rode prepare antes"

  # Confere que tem mudança em Claude/
  [ -n "$(git status --porcelain Claude/)" ] || die "sem diff em Claude/ — nada a commitar"

  local date_stamp; date_stamp=$(date +%F)
  local branch="chore/knowledge-sync-$date_stamp"
  # Colisão? Adiciona HHMMSS
  if git show-ref --quiet "refs/heads/$branch" || git ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1; then
    branch="$branch-$(date +%H%M%S)"
  fi

  git checkout -b "$branch" || die "checkout -b $branch falhou"
  git add Claude/
  git commit -m "chore(knowledge): sync vault $date_stamp" || die "commit falhou"
  git push -u origin "$branch" || die "push falhou — branch local existe, state preservado"

  # Body do PR a partir do report da skill (se existir)
  local body_file; body_file=$(report_file "$repo")
  local body_tmp; body_tmp=$(mktemp)
  local dev_sha; dev_sha=$(git rev-parse --short "$INTEGRATION_BRANCH" 2>/dev/null || echo "?")
  local files_changed; files_changed=$(git diff --stat HEAD~1 HEAD -- Claude/ | tail -1 | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")
  {
    echo "## Knowledge Sync — $date_stamp"
    echo
    echo "Atualização automatizada do vault \`Claude/\` após \`knowledge-sync\` skill."
    echo
    echo "**Branch base:** $INTEGRATION_BRANCH @ $dev_sha"
    echo "**Arquivos alterados em Claude/:** $files_changed"
    echo
    echo "### Resumo"
    if [ -f "$body_file" ]; then
      cat "$body_file"
    else
      echo "_(relatório da skill não disponível)_"
    fi
    echo
    echo "---"
    echo "Gerado por \`/knowledge-sync-all\`"
  } > "$body_tmp"

  local pr_url
  pr_url=$(gh pr create --base "$INTEGRATION_BRANCH" --head "$branch" \
    --title "chore: knowledge-sync $date_stamp" \
    --body-file "$body_tmp") || { rm -f "$body_tmp"; die "gh pr create falhou (branch + push já feitos)"; }
  rm -f "$body_tmp"

  cat <<EOF
{
  "status": "pr_created",
  "pr_url": "$pr_url",
  "branch": "$branch",
  "files_changed": $files_changed
}
EOF
}

cmd_restore_clean() {
  local repo="$1"
  cd "$(repo_path "$repo")"
  local file; file=$(state_file "$repo")
  [ -f "$file" ] || die "state file ausente — prepare não rodou? ($file)"

  [ -z "$(git status --porcelain)" ] || die "workspace sujo em $repo — recuso cleanup automático (rode 'preserve' ou limpe manual)"

  local original_branch had_stash stash_ref
  original_branch=$(read_state "$repo" original_branch)
  had_stash=$(read_state "$repo" had_stash)
  stash_ref=$(read_state "$repo" stash_ref)

  if [ "$(git branch --show-current)" != "$original_branch" ]; then
    git checkout "$original_branch" || die "checkout $original_branch falhou (stash preservado se existia)"
  fi

  if [ "$had_stash" = "true" ]; then
    if ! git stash pop "$stash_ref" > /dev/null 2>&1; then
      die "stash pop falhou (conflito?) — stash preservado, resolver manual em $(repo_path "$repo")"
    fi
  fi

  rm -f "$file"
  echo "restore-clean OK: $repo (branch=$original_branch)"
}

# Dispatch
[ $# -lt 1 ] && usage
SUBCMD="$1"; shift

# Atalho interno para chamar funções diretamente (uso: testes)
if [ "$SUBCMD" = "--internal-call" ]; then
  fn="$1"; shift
  $fn "$@"
  exit
fi

case "$SUBCMD" in
  prepare|validate-links|has-diff|commit-pr|restore-clean|preserve|status)
    [ $# -lt 1 ] && usage
    REPO="$1"; shift
    [ -d "$(repo_path "$REPO")" ] || die "repo não existe: $(repo_path "$REPO")"
    cmd_${SUBCMD//-/_} "$REPO" "$@"
    ;;
  *)
    usage
    ;;
esac
