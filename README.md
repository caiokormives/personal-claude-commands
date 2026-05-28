# personal-claude-commands

Slash commands e skills personalizados do Claude Code, versionados pra sincronizar entre máquinas.

## Conteúdo

```
commands/
  knowledge-sync-all.md      # /knowledge-sync-all — orquestra sync multi-repo NPU-Brain
skills/
  knowledge-sync/SKILL.md    # sync de Claude/ vault contra mudanças de código
  brain-seed/SKILL.md        # setup inicial do Obsidian-as-Brain num repo
```

## Instalação em uma máquina nova

```bash
git clone https://github.com/caiokormives/personal-claude-commands.git ~/code/personal-claude-commands
cd ~/code/personal-claude-commands
chmod +x install.sh
./install.sh
```

O script cria symlinks em `~/.claude/commands/` e `~/.claude/skills/` apontando pros arquivos do repo. Edita num lugar, atualiza em todas as máquinas via `git pull`.

Se já existir um arquivo regular no caminho de destino, o script faz backup com sufixo `.bak.<timestamp>` antes de criar o symlink.

## Atualizar

```bash
cd ~/code/personal-claude-commands
git pull
```

Como os arquivos em `~/.claude/` são symlinks pro repo, o `pull` já propaga as mudanças — não precisa rodar `install.sh` de novo.

## Sincronizar mudanças locais

```bash
cd ~/code/personal-claude-commands
git add -A
git commit -m "ajuste em <arquivo>"
git push
```
