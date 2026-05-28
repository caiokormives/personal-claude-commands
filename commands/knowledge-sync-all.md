---
description: Sincroniza Claude/ vault de todos os repos NPU-Brain via knowledge-sync skill em paralelo. Cria PRs contra dev. Two-phase com validação cross-repo no meio.
argument-hint: "[repo1 repo2 ...]"
---

# /knowledge-sync-all

Você é o orquestrador do knowledge-sync multi-repo. Siga o protocolo abaixo
EXATAMENTE. Não improvise.

## Passo 1 — descobrir repos

Se `$ARGUMENTS` vazio:
```bash
REPOS=$(ls -d ~/code/*/Claude/.knowledge-sync.yml 2>/dev/null \
        | sed 's|/Claude/.knowledge-sync.yml||' \
        | xargs -n1 basename)
```
Senão: `REPOS="$ARGUMENTS"` — valida cada um existe e tem `Claude/.knowledge-sync.yml`.

Para cada repo na lista, valide que `~/code/<repo>/Claude/.knowledge-sync.yml`
existe. Se algum não existir, ABORTE com mensagem clara e NÃO siga.

Imprima: `"Vou sincronizar N repos: <lista>. Iniciando fase 1..."`

## Passo 2 — fase 1 (paralelo)

Despache UM subagente por repo, TODOS na mesma mensagem (paralelismo real).

Para cada repo:
- `subagent_type`: `"general-purpose"`
- `description`: `"knowledge-sync <repo>"`
- `prompt`: o template abaixo, com `<REPO_NAME>` substituído pelo nome do repo:

````
TAREFA: Sincronizar o vault Claude/ do repo <REPO_NAME>.

Você está sozinho neste repo. Outros subagentes cuidam dos outros repos em
paralelo — NÃO toque em nenhum outro diretório fora de ~/code/<REPO_NAME>.

## Passos

### 1. Pré-sync (git ops)
Rode: bash ~/.claude/scripts/sync-repo.sh prepare <REPO_NAME>

Se exit code != 0:
- Capture stderr inteiro
- Pule pro passo 4 (REPORTE) com status "failed_pre"
- NÃO continue, NÃO tente corrigir, NÃO mexa em stash

### 2. Knowledge sync
cd ~/code/<REPO_NAME>
Invoque a skill `knowledge-sync` (via Skill tool, NÃO via Bash).

Aguarde a skill terminar. Ela vai gerar um relatório final em formato
markdown. Salve ESSE relatório em:
  /tmp/knowledge-sync-<REPO_NAME>-report.md

Se a skill falhar ou abortar (Red Flags da própria skill):
- Pule pro passo 4 com status "failed_sync"

### 3. Terminar (NÃO faça commit/PR aqui)
A fase 1 termina aqui. NÃO rode commit-pr, NÃO crie branch, NÃO faça push.
O orquestrador faz isso depois da validação global. Você só:
- Garante que /tmp/knowledge-sync-<REPO_NAME>-report.md existe.
- Verifica que está em ~/code/<REPO_NAME>.
- Pula pro passo 4 (reporte).

### 4. REPORTE (sempre rode, mesmo em falha)
Termine sua resposta com EXATAMENTE este bloco JSON entre marcadores:

<<<SYNC_RESULT>>>
{
  "repo": "<REPO_NAME>",
  "status": "phase1_ok" | "failed_pre" | "failed_sync",
  "error": "<mensagem curta ou null>",
  "stash_preserved": true | false,
  "state_file": "<caminho ou null>",
  "report_file": "<caminho ou null>",
  "duration_seconds": <int>
}
<<<END_SYNC_RESULT>>>

## Regras invioláveis

- NÃO rode comandos fora de ~/code/<REPO_NAME>
- NÃO tente "consertar" falhas dos scripts (são desenhados pra falhar
  explícito; intervenção sua piora)
- NÃO modifique arquivos fora de Claude/
- NÃO faça push --force, NÃO use --no-verify
- NÃO crie branches nem PRs (orquestrador faz isso na fase 2)
- Se a skill knowledge-sync pedir input interativo, responda
  "modo automatizado: prossiga com defaults"

LINKS — proteções obrigatórias:

- NÃO renomeie nem mova notas existentes. Se o nome está ruim, anote
  no relatório como "nota X candidata a renomear", mas não toque.
  Renomear quebra [[wikilinks]] silenciosamente.

- NÃO delete notas. Se ficou obsoleta, marque `status: archived` no
  frontmatter e mantenha o arquivo.

- NÃO altere o campo `cross_ref_note` do .knowledge-sync.yml. Esse
  contrato é congelado — sister repos dependem desses caminhos.

- Ao LER sister vaults (../sister-repo/Claude/), trate como read-only
  e snapshot — não assuma que reflete a versão final que o outro
  subagente vai produzir.

- Se a skill knowledge-sync detectar inconsistência cross-repo (nota
  referenciada não existe na sister), reporte mas NÃO crie a nota
  faltante neste sync. Cross-repo fixes precisam de execução separada
  e coordenada.

Reporte mesmo se você morrer (timeout, erro inesperado): pelo menos
o JSON com status preenchido.
````

Aguarde TODOS retornarem.

Para cada retorno, parseie o bloco entre `<<<SYNC_RESULT>>>` e `<<<END_SYNC_RESULT>>>`
como JSON. Armazene em `PHASE1_RESULTS`.

## Passo 3 — validação global (paralelo via Bash)

Para cada repo com `PHASE1_RESULTS[repo].status == "phase1_ok"`:
```bash
bash ~/.claude/scripts/sync-repo.sh validate-links <repo>
```

Despache as N validações em paralelo (múltiplos Bash tool calls na mesma
mensagem). Aguarde todas. Armazene em `VALIDATION_RESULTS`.

## Passo 4 — fase 2 (sequencial via Bash)

Para cada repo, decida o path:

**CASO `PHASE1_RESULTS[repo].status != "phase1_ok"`:**
```bash
bash ~/.claude/scripts/sync-repo.sh preserve <repo> "phase1_failure"
```
Marque como `FAILED_PHASE1`.

**CASO `VALIDATION_RESULTS[repo].ok == false`:**
```bash
bash ~/.claude/scripts/sync-repo.sh preserve <repo> "links_broken"
```
Marque como `REJECTED_LINKS`, capture listas `broken_*`.

**CASO `bash sync-repo.sh has-diff <repo>` retornar exit 1 (sem diff):**
```bash
bash ~/.claude/scripts/sync-repo.sh restore-clean <repo>
```
Marque como `NO_CHANGES`.

**CASO default (validação ok + tem diff):**
```bash
bash ~/.claude/scripts/sync-repo.sh commit-pr <repo>
# captura PR URL do JSON em stdout
bash ~/.claude/scripts/sync-repo.sh restore-clean <repo>
# se restore-clean falhar, marque CLEANUP_FAILED (PR criado mas cleanup falhou)
```
Marque como `PR_CREATED`.

**NÃO paralelize fase 2.** Sequencial garante que falhas são fáceis de
rastrear e evita corrida em saída.

## Passo 5 — relatório final

Imprima no formato:

```
=== /knowledge-sync-all — YYYY-MM-DD HH:MM:SS ===

PRs criados (N):
  - <repo> -> <pr_url>

Sem mudanças (N):
  - <repo>

Estado preservado — REQUER AÇÃO MANUAL (N):
  - <repo> (<motivo>)
      Patch: /tmp/knowledge-sync-<repo>-rejected.patch
      Stash: preservado em ~/code/<repo> stash@{0}
      Branch atual: <branch>
      Detalhes: /tmp/knowledge-sync-<repo>-preserved.txt

Validação cross-repo: N falhas bloqueantes
  - <repo>: <lista de problemas>

Duração total: <tempo>
```

NÃO ofereça `/schedule` no final. NÃO tente "consertar" estados preservados.
O user revisa manualmente.

## Regras invioláveis do orquestrador

- NÃO modifique nenhum repo fora dos descobertos no passo 1.
- NÃO altere a lista de repos passada via `$ARGUMENTS` — use exatamente o que veio.
- NÃO tente recovery automático em failures preservados.
- Se uma fase abortar (ex: passo 1 não achou nenhum repo), pare e reporte.
  NÃO pule pro passo 2.
- Se ALGUM subagente da fase 1 não retornar JSON parseable, marque-o como
  `failed_pre` com erro `"subagent_no_result"` e continue. Outros continuam.
- Tempo total > 30 minutos = algo deu MUITO errado. Reporte status parcial
  e abort em vez de esperar indefinido.
