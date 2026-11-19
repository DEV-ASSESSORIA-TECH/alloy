# Migração a partir do repositório `scripts`

Até a v1.0.0 o código ficava em `DEV-ASSESSORIA-TECH/scripts`
(`monitoring/alloy`), e o `alloyctl` acompanhava a branch `main` de lá. O
histórico foi trazido para cá com `git subtree split`.

## Como as máquinas migram sozinhas

O `alloyctl` antigo tem o repositório `scripts` fixo no código. Por isso a
pasta `monitoring/alloy` do `scripts` virou uma **ponte**: `alloy.sh` /
`alloy.ps1` que baixam o ponto de entrada daqui, mais `lib/` vazios (o
`alloyctl` antigo exige que existam).

```
alloyctl antigo ──(se atualiza por scripts/main)──▶ recebe a ponte
      ponte ──▶ baixa alloy/main/<so>/alloy.sh ──▶ resolve stable = v1.0.0
      ──▶ reinstala /opt/alloyctl (ou Program Files\AssessoriaTech\alloyctl)
      ──▶ segue com o mesmo comando
```

O mesmo vale para o comando antigo do README e para o script do Tactical RMM
ainda não recolado. Uma instalação antiga (arquivo `ref`, sem `channel`)
também é levada para `stable` pelo código novo.

Se a ponte rodar **antes** de existir uma release, o `stable` não resolve:
a máquina avisa (`nenhuma release publicada`) e tenta de novo na execução
seguinte. Por isso a ordem abaixo importa.

## Ordem

1. **Repositório `alloy`**: criar a `main` a partir da branch desta migração
   e defini-la como branch padrão (o repositório estava vazio; a primeira
   branch enviada virou a padrão).
2. **CI verde** na `main`.
3. **Publicar a v1.0.0** ([release.md](release.md)).
4. **Testar numa máquina nova** de cada sistema, com o comando novo do
   README.
5. **Testar a migração** numa máquina com o `alloyctl` antigo, sem mexer na
   `main` do `scripts`: `alloyctl --ref <branch da ponte no scripts>`. O
   cabeçalho deve passar a mostrar `stable @ v1.0.0`.
6. **Merge da ponte** na `main` do `scripts`. A partir daí cada máquina
   migra na próxima execução do `alloyctl`.
7. **Tactical RMM**: recolar `windows/rmm/tactical-estacao.ps1` no Script
   Manager (o conteúdo fica salvo no Tactical; até lá, a ponte atende).
8. **Base de conhecimento**: trocar os comandos e links para este
   repositório.
9. **Remover a ponte** quando os logs mostrarem que não há mais máquinas no
   caminho antigo: linhas `atualizado: ... (stable)` em
   `/var/log/alloyctl.log` e `alloyctl-*.log`.

## O que muda para quem usa

| Antes | Agora |
|-------|-------|
| `raw.githubusercontent.com/DEV-ASSESSORIA-TECH/scripts/main/monitoring/alloy/<so>/alloy.*` | `raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/main/<so>/alloy.*` |
| acompanha a branch `main` | acompanha `stable` (última release) |
| `--ref main` era o padrão | `--ref main` testa o que ainda não foi publicado |
| cabeçalho `main @ 1a2b3c4` | `stable @ v1.0.0` |
| arquivo `ref` na pasta do `alloyctl` | arquivo `channel` |
