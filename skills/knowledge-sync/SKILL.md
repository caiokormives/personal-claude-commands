---
name: knowledge-sync
description: Use when working on any repo that has a Claude/ Obsidian vault. Ensures the knowledge base stays in sync with code changes. Trigger at session start (read context) and before session end (write updates). Also use when fixing bugs, discovering patterns, changing architecture, or altering API contracts.
---

# Knowledge Sync — Manter o Cérebro Vivo

O Obsidian vault (`Claude/`) é o coração, cérebro e veias do repo. Se o código muda e o vault não acompanha, o próximo Claude erra. Esta skill garante que o conhecimento evolui junto com o código — com profundidade proporcional ao tamanho da mudança.

## Quando Usar

- **Toda sessão** em repo com `Claude/`
- Não é opcional. Se `Claude/` existe, esta skill é obrigatória.

---

## Fase 0a — Carregar Config do Repo (OBRIGATÓRIO se existir)

**A skill é genérica. As particularidades de cada repo vivem em `Claude/.knowledge-sync.yml`.**

```bash
CONFIG="Claude/.knowledge-sync.yml"
if [ -f "$CONFIG" ]; then
  echo "✅ Config local encontrado — usando áreas obrigatórias, consumidores e validações deste repo"
  cat "$CONFIG"
else
  echo "⚠️  Sem .knowledge-sync.yml — usando fallback genérico (regras-negocio, glossario, arquitetura)"
  echo "    Recomendação: criar Claude/.knowledge-sync.yml seguindo template de outros repos NPU"
fi
```

### Como usar o config

O YAML declara:

| Campo | Uso pela skill |
|-------|----------------|
| `repo.name`, `repo.stack`, `repo.role` | Contexto pro relatório final |
| `consumers[]` | Cross-repo sync — sister vaults a sincronizar quando contratos mudam |
| `producers[]` | De onde vem dados/endpoints consumidos |
| `mandatory_rule_areas[]` | Lista exaustiva pra validar Fase 9 — substitui qualquer hardcode |
| `tier_targets` | Metas de cobertura (default: T1=100% com Regras e Invariantes) |
| `custom_validations[]` | Greps específicos do repo (ex: "toda regra marca consumidor afetado") |
| `code_audit_patterns[]` | Anti-patterns a buscar no diff (SQL injection, fetch raw, etc.) |

### Fallback (sem config)

Se o repo não tem `.knowledge-sync.yml`, usar áreas mínimas universais:
- `regras-negocio` — toda stack tem regras
- `glossario` — toda stack tem termos
- `arquitetura` — toda stack tem arquitetura

E **AVISAR** no relatório final que o repo precisa de config próprio.

### Template pra criar config em repo novo

Ver `~/Documentos/NPU/hinc-backend/Claude/.knowledge-sync.yml` (backend dual-consumer) ou
`~/Documentos/NPU/hinc-onepage/Claude/.knowledge-sync.yml` (frontend simples) como referência.

---

## Fase 0b — Diagnóstico de Magnitude (OBRIGATÓRIO)

ANTES de qualquer atualização, medir o tamanho da mudança:

```bash
# Diff desde último checkpoint relevante (HEAD~10 cobre sessão típica)
files_changed=$(git diff --name-only HEAD~10..HEAD 2>/dev/null | grep -E '\.(ts|tsx|js|jsx|py)$' | wc -l)
loc_added=$(git diff --stat HEAD~10..HEAD 2>/dev/null | tail -1 | grep -oP '\d+(?= insertion)' || echo 0)
new_endpoints=$(git diff HEAD~10..HEAD 2>/dev/null | grep -cE '^\+.*(axiosInstance|axios\.|fetch\(|@app\.(get|post|put|delete)|@router\.)')
new_files=$(git diff --name-only --diff-filter=A HEAD~10..HEAD 2>/dev/null | grep -E '\.(ts|tsx|js|jsx|py)$' | wc -l)

echo "Files: $files_changed | LOC: $loc_added | Endpoints: $new_endpoints | New files: $new_files"
```

### Critérios de Modo

| Métrica | Light sync | Deep sync |
|---------|-----------|-----------|
| LOC adicionadas | <500 | **>=500** |
| Arquivos alterados | <10 | **>=10** |
| Novos endpoints | 0 | **>=1** |
| Arquivos novos | <3 | **>=3** |
| Merge de branch | — | **sempre deep** |

**Qualquer linha que cair em "deep" → modo deep obrigatório.** Não negociável.

---

## Modo Light (mudanças pequenas)

Fluxo enxuto para refactors triviais, fixes pontuais, ajustes:

1. `git diff --name-only` — quais arquivos de código mudaram?
2. Para cada arquivo: a nota correspondente foi atualizada?
3. Algum bug mudou de status?
4. Algum novo endpoint ou mudança de contrato?
5. Atualizar `updated:` no frontmatter das notas tocadas

### Eventos → Ações (Light)

| Evento | O que atualizar |
|--------|----------------|
| Bug resolvido | `bugs-conhecidos.md` (status → RESOLVIDO) + criar `post-mortems/YYYY-MM-descricao.md` |
| Bug investigado | Nota do módulo afetado + `bugs-conhecidos.md` (adicionar achados) |
| Arquivo alterado | Nota relacionada (se line numbers ou comportamento mudaram) |
| Endpoint criado/alterado | `mapa-requests.md` + `contratos-api-*.md` |
| Padrão descoberto | Nota relevante ou nova nota |
| Débito técnico encontrado | `tech-debt.md` |
| Regra de negócio clarificada | `regras-negocio.md` ou nota equivalente |
| Dependência adicionada/removida | `dependencias.md` |
| Line numbers mudaram | TODAS as notas que referenciam aquele arquivo |

---

## Modo Deep (refactor sísmico)

Quando o diagnóstico bate critério deep, fluxo expandido:

### 1. Dispatch 3 subagents EM PARALELO

- **Agent 1 — Core layer:** ler todos services/hooks/utils alterados. Mapear funções novas, params, retornos, edge cases.
- **Agent 2 — Components/screens:** ler componentes novos/alterados. Mapear props, state, callbacks, regras.
- **Agent 3 — Contratos + Regras:** rodar checklist de captura de regras (abaixo) + verificar contratos API.

### 2. Para cada arquivo alterado >100 LOC

- Ler o arquivo COMPLETO
- Comparar com nota existente (se houver)
- Documentar discrepâncias

### 3. Auditoria de regras implícitas (CHECKLIST OBRIGATÓRIO)

Para CADA arquivo no deep audit, executar:

```bash
ARQ="caminho/do/arquivo"

# Constantes mágicas
grep -nE '=\s*[0-9]+\b' "$ARQ" | grep -vE 'import|test|//'

# Thresholds e comparações com literais
grep -nE '(>=|<=|>|<)\s*[0-9.]+' "$ARQ"

# Fallbacks e defaults
grep -nE '\|\|\s*("[^"]*"|[0-9]+|null|undefined|\[\]|\{\})' "$ARQ"
grep -nE '\?\?\s*' "$ARQ"

# Branches por string literal
grep -nE '===\s*"[^"]+"' "$ARQ"

# Early returns / guard clauses
grep -nE '^\s*if.*return' "$ARQ"

# Try/catch silenciosos
grep -B1 -A3 'catch' "$ARQ" | grep -A2 '{}'

# Math.max/min/floor (caps e clamps silenciosos)
grep -nE 'Math\.(max|min|floor|ceil|round)' "$ARQ"
```

Cada hit não-trivial → linha em `regras-negocio.md`, `regras-calculo-*.md` ou nota do módulo. **Não documentar = bug futuro garantido.**

### 3.1 Checklist de Áreas de Regra OBRIGATÓRIAS (lido do config local)

**As áreas obrigatórias vêm de `Claude/.knowledge-sync.yml` (campo `mandatory_rule_areas[]`).** A skill NÃO tem lista hardcoded — cada repo declara as suas.

Comando de verificação (extrai do YAML automaticamente):

```bash
CONFIG="Claude/.knowledge-sync.yml"
if [ -f "$CONFIG" ]; then
  # Extrai IDs declarados no config
  AREAS=$(grep -E "^\s+- id:" "$CONFIG" | sed 's/.*id: *//' | tr -d '"')
else
  # Fallback genérico
  AREAS="regras-negocio glossario arquitetura"
fi

echo "=== Áreas obrigatórias declaradas no config ==="
for area in $AREAS; do
  count=$(ls Claude/${area}*.md 2>/dev/null | wc -l)
  links=$(grep -rl "\[\[${area}" Claude/ --include="*.md" 2>/dev/null | wc -l)
  if [ "$count" -eq 0 ]; then
    echo "❌ $area: NOTA FALTA (criar agora)"
  elif [ "$links" -lt 3 ]; then
    echo "⚠️  $area: existe mas poucos links inbound ($links — propagar)"
  else
    echo "✅ $area: $count nota(s), $links inbound links"
  fi
done
```

Se algum core do config tem `0 notas` ou `<3 inbound links` → **gap crítico, criar/propagar links**.

### 3.2 Validações custom do repo (config-driven)

Se o config declara `custom_validations[]` ou `code_audit_patterns[]`, rodar cada um:

```bash
# Exemplo: custom_validations.every-rule-marks-consumer
# (extraído de Claude/.knowledge-sync.yml — varia por repo)
#
# Aqui você itera sobre os patterns do YAML e roda grep contra Claude/
# Hits que violam a regra → bloqueio até corrigir
```

Cada repo pode ter validações stack-específicas. Backend = SQL injection, workgroup do JWT.
Frontend = fetch raw vs axiosInstance, "-" to zero conversion. Ler do config e rodar.

### 4. Auditoria de contratos API

```bash
# Endpoints no código vs mapa-requests.md
code_endpoints=$(grep -rnE "axiosInstance\.(get|post|put|delete)|fetch\(" src/ --include="*.ts" --include="*.tsx" --include="*.jsx" --include="*.js" 2>/dev/null | grep -v node_modules | wc -l)
doc_endpoints=$(grep -cE "^\| [0-9]+ \|" Claude/mapa-requests.md 2>/dev/null || echo 0)
echo "Código: $code_endpoints | Documentados: $doc_endpoints"

# Backend (se sister repo existe): rotas vs notas
# ls ../hinc-backend/app/routers/*.py 2>/dev/null

# Diff cobre novos endpoints?
git diff HEAD~10..HEAD -- 'src/**/*.ts' 'src/**/*.tsx' 2>/dev/null | grep -E '^\+.*(axiosInstance|fetch\()'
```

Se algum endpoint do código não está no mapa → criar linha + investigar contrato.

### 5. Reescrever seções de `arquitetura.md` se módulo inteiro mudou

Se o módulo cresceu/diminuiu >30% de LOC, a seção dele em `arquitetura.md` provavelmente está obsoleta. Reescrever, não só adicionar nota.

### 6. Atualizar MOCs

Se criou nota nova → incluir em MOC relevante. MOCs também precisam estar atualizados.

---

## Cross-Repo Sync (config-driven, path-resolution robusto)

**Sister vaults são declarados no config local** (`consumers[]` e `producers[]` em `Claude/.knowledge-sync.yml`).

### Resolução de path (3 tentativas, sem quebrar)

A skill resolve cada `path:` declarado no YAML nesta ordem:

1. **`$NPU_WORKSPACE/<name>`** — env var override. Use em CI ou setups custom.
2. **`<repo_root>/<path_yaml>`** — caminho relativo declarado no YAML, resolvido a partir da raiz do REPO atual (não do CWD do shell).
3. **`../<name>`** — fallback autodetectado (siblings no mesmo diretório pai).

Se NENHUMA resolver → skill **NÃO falha**, apenas registra "sister vault ausente — sync cross-repo skipped" no relatório.

### Script de resolução

```bash
CONFIG="Claude/.knowledge-sync.yml"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

resolve_sister() {
  local name="$1"
  local yaml_path="$2"

  # 1. Env var override
  if [ -n "$NPU_WORKSPACE" ] && [ -d "$NPU_WORKSPACE/$name/Claude" ]; then
    echo "$NPU_WORKSPACE/$name"; return 0
  fi

  # 2. YAML path (relativo à raiz do repo)
  if [ -n "$yaml_path" ] && [ -d "$REPO_ROOT/$yaml_path/Claude" ]; then
    (cd "$REPO_ROOT/$yaml_path" && pwd); return 0
  fi

  # 3. Autodetect siblings
  if [ -d "$REPO_ROOT/../$name/Claude" ]; then
    (cd "$REPO_ROOT/../$name" && pwd); return 0
  fi

  return 1  # não encontrado — caller decide
}

if [ -f "$CONFIG" ]; then
  echo "=== Sister vaults ==="
  # Parse consumers + producers do YAML
  awk '/^(consumers|producers):/{section=$1} /^\s+- name:/{name=$3} /^\s+path:/{print section, name, $2}' "$CONFIG" | \
  while read section name yaml_path; do
    [ "$yaml_path" = "null" ] && { echo "  ⊘ $name ($section): sem repo local (serviço externo)"; continue; }
    resolved=$(resolve_sister "$name" "$yaml_path")
    if [ -n "$resolved" ]; then
      echo "  ✅ $name → $resolved"
    else
      echo "  ⚠️  $name: NÃO encontrado (\$NPU_WORKSPACE=$NPU_WORKSPACE, yaml=$yaml_path) — skip cross-sync"
    fi
  done
fi
```

### Ações quando sister vault encontrado

1. Criar nota de evento em AMBOS os vaults: `cross-repo-YYYY-MM-evento.md`
2. Tag `#cross-repo` obrigatória
3. **Avisar dev no relatório final** que sister repo precisa sync
4. Atualizar `Claude/<cross_ref_note>` declarado no config (ex: `hinc-onepage.md`, `hinc-pda.md`)
5. Se o repo é backend dual-consumer, garantir que TODA mudança de contrato lista QUAL consumidor afeta

### Quando sister vault NÃO encontrado

- Sync cross-repo é **skipped**, não bloqueia
- Relatório final lista: "⚠️ Cross-sync com X foi pulado — execute `/knowledge-sync` no outro repo manualmente"
- Notas internas (`hinc-onepage.md`, `hinc-pda.md`) ainda são atualizadas — elas vivem DENTRO de `Claude/` deste repo

---

## Validação Automatizada (antes de encerrar)

```bash
# Total de notas e links
find Claude/ -name '*.md' -not -path '*/_templates/*' -type f | wc -l
grep -ro '\[\[' Claude/ --include='*.md' | wc -l

# Notas tocadas no diff atual têm 'updated' = hoje?
today=$(date +%Y-%m-%d)
git diff --name-only -- 'Claude/*.md' 2>/dev/null | while read f; do
  [ -f "$f" ] && grep -q "updated: $today" "$f" || echo "STALE: $f"
done

# Notas órfãs (zero outbound links)
find Claude/ -name "*.md" -not -path "*/_templates/*" -type f -print0 | while IFS= read -r -d '' f; do
  out=$(grep -co '\[\[' "$f" 2>/dev/null || echo 0)
  if [ "$out" -eq 0 ]; then echo "ILHA: $f"; fi
done

# Notas criadas nesta sessão têm links chegando?
git diff --name-only --diff-filter=A -- 'Claude/*.md' 2>/dev/null | while read f; do
  base=$(basename "$f" .md)
  grep -rq "\[\[$base" Claude/ || echo "SEM_INBOUND: $f"
done

# Frontmatter em tudo
find Claude/ -name "*.md" -not -path "*/_templates/*" -type f -print0 | while IFS= read -r -d '' f; do
  has_fm=$(head -1 "$f" | grep -c "^---$")
  if [ "$has_fm" -eq 0 ]; then echo "SEM_FM: $f"; fi
done
```

Corrigir tudo encontrado ANTES de declarar sync completo.

---

## Relatório Final ao Dev (OBRIGATÓRIO)

Toda execução da skill termina com este template:

```markdown
## Knowledge Sync Report — {data}

### Modo: {light|deep}
**Motivo:** {LOC X / files Y / endpoints Z / merge}

### Código alterado
- {N} arquivos, {LOC} linhas, {endpoints} endpoints novos

### Vault atualizado
| Nota | Mudança | Motivo |
|------|---------|--------|
| {nota.md} | {o que mudou} | {por quê} |

### Regras de negócio capturadas
- {regra 1} — `arquivo:linha`
- {regra 2} — `arquivo:linha`

### Contratos API
- Novos endpoints: {lista} → mapa-requests.md atualizado
- Discrepâncias encontradas: {lista}
- Cross-repo pendente: {sister-repo notes a criar}

### Pendências
- [ ] {nota X precisa de revisão humana}
- [ ] {investigar comportamento Y in vivo}

### Validação
- Notas: {N}  |  Links: {M}
- Ilhas: 0  |  Frontmatter stale: 0  |  Endpoints não mapeados: 0
```

---

## Estrutura esperada do Claude/

```
Claude/
├── _templates/          ← Templates Templater
├── post-mortems/        ← Cronológico
├── _MOC *.md            ← Hubs de navegação (interligados)
├── *.md                 ← Notas por conceito (flat, sem subpastas)
```

Notas são conceitos, não categorias. Links e tags fazem a organização.

---

## Fase 9 — Cobertura 10/10 (executar a cada deep sync)

Garantia de que toda nota tem (1) regras explícitas e (2) código verificado.

### Verificação de seção "Regras e Invariantes"

```bash
echo "=== T1 sem seção Regras e Invariantes ==="
for f in $(grep -rl "^tier: 1" Claude/ --include="*.md"); do
  has=$(grep -c "^## Regras e Invariantes" "$f")
  if [ "$has" -eq 0 ]; then echo "  FALTA: $(basename $f .md)"; fi
done

echo "=== T2 grandes (>200 linhas) sem seção Regras e Invariantes ==="
for f in $(grep -rl "^tier: 2" Claude/ --include="*.md"); do
  lines=$(wc -l < "$f")
  if [ "$lines" -gt 200 ]; then
    has=$(grep -c "^## Regras e Invariantes" "$f")
    if [ "$has" -eq 0 ]; then echo "  FALTA: $(basename $f .md) ($lines linhas)"; fi
  fi
done
```

Cada FALTA → adicionar seção antes de declarar sync completo.

### Verificação de áreas obrigatórias (lido do config local)

**Áreas vêm de `Claude/.knowledge-sync.yml` — campo `mandatory_rule_areas[].id`.** Sem config = fallback mínimo.

```bash
CONFIG="Claude/.knowledge-sync.yml"
if [ -f "$CONFIG" ]; then
  AREAS=$(grep -E "^\s+- id:" "$CONFIG" | sed 's/.*id: *//' | tr -d '"')
else
  AREAS="regras-negocio glossario arquitetura"
fi

for area in $AREAS; do
  count=$(ls Claude/${area}*.md 2>/dev/null | wc -l)
  links=$(grep -rl "\[\[${area}" Claude/ --include="*.md" 2>/dev/null | wc -l)
  if [ "$count" -eq 0 ]; then
    echo "❌ $area: NOTA FALTA"
  elif [ "$links" -lt 3 ]; then
    echo "⚠️  $area: poucos links ($links)"
  fi
done
```

### Verificação de cross_ref_note declarados (config-driven)

**Toda nota declarada em `consumers[*].cross_ref_note` ou `producers[*].cross_ref_note` deve existir em `Claude/`.** Se não existir, é gap crítico (relação declarada sem nota).

```bash
CONFIG="Claude/.knowledge-sync.yml"
if [ -f "$CONFIG" ]; then
  grep "cross_ref_note:" "$CONFIG" | sed 's/.*cross_ref_note: *//' | sed 's/#.*//' | sed 's/ *$//' | while read f; do
    if [ "$f" = "null" ]; then
      continue
    elif [ -f "Claude/$f" ]; then
      has_regras=$(grep -c "^## Regras e Invariantes" "Claude/$f")
      if [ "$has_regras" -gt 0 ]; then
        echo "  ✅ Claude/$f (com Regras)"
      else
        echo "  ⚠️  Claude/$f (existe mas sem Regras e Invariantes)"
      fi
    else
      echo "  ❌ Claude/$f declarado mas NÃO existe"
    fi
  done
fi
```

Se algum cross_ref_note declarado não existe → **gap crítico, criar agora**.

### Métrica final 10/10

```bash
CONFIG="Claude/.knowledge-sync.yml"

# 1. Cobertura T1
total_t1=$(grep -rl "^tier: 1" Claude/ --include="*.md" | wc -l)
t1_com_regras=$(for f in $(grep -rl "^tier: 1" Claude/ --include="*.md"); do
  has=$(grep -c "^## Regras e Invariantes" "$f"); [ "$has" -gt 0 ] && echo "$f"
done | wc -l)
echo "Cobertura T1: $t1_com_regras / $total_t1"

# 2. Cobertura T2 grandes
total_t2_big=0; t2_big_ok=0
for f in $(grep -rl "^tier: 2" Claude/ --include="*.md"); do
  lines=$(wc -l < "$f")
  if [ "$lines" -gt 200 ]; then
    total_t2_big=$((total_t2_big + 1))
    has=$(grep -c "^## Regras e Invariantes" "$f")
    [ "$has" -gt 0 ] && t2_big_ok=$((t2_big_ok + 1))
  fi
done
echo "Cobertura T2 grandes: $t2_big_ok / $total_t2_big"

# 3. Áreas obrigatórias do config
if [ -f "$CONFIG" ]; then
  AREAS=$(grep -E "^\s+- id:" "$CONFIG" | sed 's/.*id: *//' | tr -d '"')
  total_areas=0; ok_areas=0
  for a in $AREAS; do
    total_areas=$((total_areas + 1))
    count=$(ls Claude/${a}*.md 2>/dev/null | wc -l)
    [ "$count" -gt 0 ] && ok_areas=$((ok_areas + 1))
  done
  echo "Áreas obrigatórias (config): $ok_areas / $total_areas"
fi

# 4. Cross-refs declarados existem
if [ -f "$CONFIG" ]; then
  total_crossrefs=0; ok_crossrefs=0
  while read f; do
    [ -z "$f" ] && continue
    [ "$f" = "null" ] && continue
    total_crossrefs=$((total_crossrefs + 1))
    [ -f "Claude/$f" ] && ok_crossrefs=$((ok_crossrefs + 1))
  done < <(grep "cross_ref_note:" "$CONFIG" | sed 's/.*cross_ref_note: *//' | sed 's/#.*//' | sed 's/ *$//')
  echo "Cross-refs declarados existentes: $ok_crossrefs / $total_crossrefs"
fi
```

Meta: **100% em todas as quatro métricas**. Se algum item falhou → BLOQUEIO até criar/expandir.

---

## Fase 10 — Auditoria do CLAUDE.md (anti-deriva)

O `CLAUDE.md` (raiz do repo + hub `/home/npu/code/CLAUDE.md`) carrega em TODA sessão e compete por contexto. Deve conter só o **estável e de alto sinal**; fato perecível mora no vault (que co-evolui aqui). A cada deep sync, audite o `CLAUDE.md` do repo:

```bash
F="CLAUDE.md"
[ -f "$F" ] || F="$(git rev-parse --show-toplevel 2>/dev/null)/CLAUDE.md"

# 1. Tamanho — meta < 200 linhas (acima disso a aderência do agente cai)
echo "Linhas: $(wc -l < "$F") (meta < 200)"

# 2. Secret literal versionado no doc
grep -nE '(SECRET|API[_-]?KEY|PASSWORD|TOKEN) *[:=] *["'"'"']' "$F" && echo "PARE: possível secret literal no CLAUDE.md"

# 3. Data perecível / vencida cravada no texto (preferir fato qualitativo + nota no vault)
grep -nE '(expir|venc)|20[0-9]{2}' "$F" && echo "Revisar: data perecível"

# 4. Número de linha cravado (envelhece a cada edição → usar âncora de função/handler achável por grep)
grep -nE '~?L[0-9]{2,}|linha[s]? [0-9]{2,}|:[0-9]{3,}' "$F" && echo "Revisar: trocar número de linha por âncora"

# 5. Contagem auto-declarada / folclore de cobertura (mover para o relatório do /knowledge-sync)
grep -nE '[0-9]+ notas|wiki ?links|Cobertura 10/10|[0-9]+ endpoints' "$F" && echo "Revisar: contagem auto-declarada"
```

Para cada alerta: **corrija no mesmo PR** (co-evolução). Princípio: "remover esta linha faria o agente errar?" Se não, corte. Datas/contagens/números de linha → vão para o vault ou para um comando que os deriva; no `CLAUDE.md` fica só o fato qualitativo estável.

> O `AGENTS.md` de cada repo é **symlink** para o `CLAUDE.md` (interop cross-tool) — não há arquivo separado para auditar.

---

## Taxonomia de Tags (controlada)

```
Domínio:        #frontend  #backend  #database  #frontend/grid  #backend/kpi
Problema:       #bug  #bug/fase-0..3  #debt/alta  #debt/media  #debt/baixa
Padrão:         #pattern  #pattern/react-query  #pattern/singleton
Status:         #resolved  #pending  #in-progress
Tipo:           #feature  #performance  #post-mortem  #cross-repo  #moc
```

Max 5 tags por nota. Não inventar tags — usar as existentes.

## Formato do frontmatter

```yaml
---
title: Nome descritivo do conceito
type: architecture | business-rules | dependencies | tech-debt | bug | post-mortem | flow | anatomy | reference | moc
status: active | draft | review | archived | resolved
tags: [tag1, tag2]
created: YYYY-MM-DD
updated: YYYY-MM-DD
owner: claude
project: {nome-do-repo}
related:
  - "[[nota-relacionada]]"
tier: 1 | 2 | 3
---
```

## Red Flags — PARE e atualize

- Alterou arquivo de código e não atualizou nenhuma nota → PARE
- Modo light disparado em merge → PARE, é deep
- Resolveu bug e não criou post-mortem → PARE
- Descobriu regra de negócio e não documentou → PARE
- Mudou endpoint e não atualizou mapa-requests → PARE
- Line numbers nas notas estão desatualizadas → PARE
- Endpoint novo não está documentado → PARE
- Relatório final não foi gerado → PARE
- `CLAUDE.md` com data vencida, secret literal, contagem auto-declarada ou número de linha cravado → PARE e pode (ver Fase 10)
