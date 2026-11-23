# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/);
versões em [SemVer](https://semver.org/lang/pt-BR/). Veja
[docs/release.md](docs/release.md) para o processo de publicação.

Cada item diz se a mudança exige **[1] Reaplicar configuração** nas máquinas:
a atualização automática troca só o `alloyctl`, nunca a configuração do Alloy.

## [Não publicado]

## [1.1.0] - 2026-11-23

Não exige **[1] Reaplicar**. A versão do Alloy só muda numa máquina quando
alguém executar **[3] Atualizar Alloy** (leva à v1.21.3; quem já está nela
ou acima não muda).

### Adicionado

- **Versão do Alloy fixada**: v1.21.3, definida em `alloy.Dockerfile`. A
  primeira instalação e **[3] Atualizar Alloy** instalam essa versão;
  reaplicar nunca muda a versão. **[3] Atualizar Alloy** nunca rebaixa: um
  Alloy mais novo que o fixado é mantido, com aviso. O diagnóstico aponta
  Alloy instalado em versão diferente da fixada.
  - Linux: instala `alloy=<versão>` pelo APT e retém o pacote
    (`apt-mark hold`), para um `apt upgrade` não trocar a versão.
  - Windows: baixa o instalador da release da Grafana com essa versão
    (SHA256 e assinatura conferidos como antes).
- Dependabot para a versão do Alloy (PR quando sair versão nova).
- Testes de comportamento: bats (canais, troca do `alloyctl`, versão fixada,
  downloads sob demanda, leitura do APT com `awk`/`gawk`/`mawk`) e Pester
  (partes do instalador, canais, `Common.ps1`, `PSModulePath`).
- Conferência dos produtores contra os contratos do repositório `grafana`
  (jobs, métricas dos coletores, heartbeat, leitor de backups), em todo PR e
  semanalmente.

### Alterado

- `install.ps1` dividido em `ops/install/` (pacote, backup e um arquivo por
  módulo). `install.sh` e `install.ps1` usam as constantes de `lib/` em vez
  de repeti-las; funções repetidas entre `install.ps1`, `heartbeat-setup.ps1`
  e `State.ps1` foram para `Common.ps1`.
- Linux: `install.sh`, `uninstall.sh` e `heartbeat-setup.sh` mostram o
  comando, a linha e o código quando algo falha (antes, com `set -e`,
  paravam só com "A operacao nao foi concluida").
- Um `alloyctl` v1.0.0 que se atualiza para esta versão baixa o
  `alloy.Dockerfile` na primeira execução (a v1.0.0 não o conhecia).
- CI também nos branches de trabalho (`claude/**`).
- Publicação: a versão fica no arquivo `VERSION` e a release sai pelo
  workflow **Release**, disparado à mão na `main` (ele cria a tag). Antes era
  preciso criar e enviar a tag localmente.

### Corrigido

- Windows: aberto a partir do PowerShell 7 (inclusive pelo `alloyctl`
  digitado no pwsh), o `alloyctl` falhava ao carregar `Set-Acl`. Agora tira
  do `PSModulePath` as pastas do PowerShell 7 e, se o próprio `alloy.ps1`
  rodar no pwsh, reabre no Windows PowerShell 5.1 no mesmo console.

## [1.0.0] - 2026-11-19

Primeira versão no repositório próprio. Até aqui o código ficava em
`DEV-ASSESSORIA-TECH/scripts` (`monitoring/alloy`), cujo histórico foi trazido
junto.

### Alterado

- Repositório próprio: `DEV-ASSESSORIA-TECH/alloy`. O comando de instalação
  mudou (README). O endereço antigo continua funcionando por um período e
  migra a máquina sozinho ([docs/migracao.md](docs/migracao.md)).
- O `alloyctl` acompanha um **canal**: `stable` (padrão, última release),
  uma tag (`v1.0.0`, versão fixa) ou uma branch (`main`). Antes acompanhava a
  branch `main`. Instalações antigas passam para `stable` na primeira
  execução.
- A última release é descoberta sem usar a API do GitHub (redirecionamento de
  `/releases/latest`), com a API como alternativa. Fora do limite de 60
  consultas por hora por IP.
- Arquivos organizados em subpastas por sistema: `lib/`, `ops/`,
  `heartbeat/`, `modules/` e, no Windows, `collectors/` e `rmm/`.
- README dividido em `docs/`.
- `rmm/tactical-estacao.ps1`: baixa do repositório novo e acompanha `stable`
  (`-Ref main` para testar). **O script cadastrado no Tactical RMM precisa ser
  recolado.**

### Adicionado

- CI: shellcheck, sintaxe Python, sintaxe e PSScriptAnalyzer no Windows
  PowerShell 5.1, `.ps1` só em ASCII, `alloy fmt` nos `.alloy` e conferência
  dos caminhos baixados pelo `alloyctl`.
- Release automática ao enviar uma tag `vX.Y.Z`, com as notas deste arquivo.

Não exige **[1] Reaplicar**: a configuração gerada é a mesma.

[Não publicado]: https://github.com/DEV-ASSESSORIA-TECH/alloy/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/DEV-ASSESSORIA-TECH/alloy/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/DEV-ASSESSORIA-TECH/alloy/releases/tag/v1.0.0
