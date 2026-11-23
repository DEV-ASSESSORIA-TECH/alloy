# alloyctl

| | Linux | Windows |
|-|-------|---------|
| Ferramenta | `/opt/alloyctl/` | `C:\Program Files\AssessoriaTech\alloyctl\` |
| Comando | `/usr/local/bin/alloyctl` (link) | `alloyctl.cmd`, pasta no PATH da máquina (vale em terminais novos); se o registro da máquina recusar (política, antivírus), no PATH do usuário; se também recusar, avisa e indica o caminho completo |
| Sem administrador | pede `sudo` | pede elevação (UAC) e continua em uma nova janela |

- **Atualização a cada execução**: o `alloyctl` acompanha um canal (veja
  [Versões e canais](#versões-e-canais)). A cada execução descobre a versão
  atual do canal; se mudou, baixa o núcleo (ponto de entrada + `lib/`) daquela
  versão, troca a pasta inteira e reinicia com a versão nova. Sem acesso ao
  GitHub, avisa e segue com a versão instalada. `--no-update` (`-NoUpdate`)
  pula a verificação; `alloyctl update` só atualiza e mostra a versão.
- **Falhas visíveis**: o motivo (ex.: `HTTP 403: limite da API`, nome não
  resolvido, sem permissão na pasta) aparece na tela, na linha `alloyctl` do
  cabeçalho do menu e no log: `/var/log/alloyctl.log` (Linux) ou
  `C:\ProgramData\GrafanaLabs\Alloy\logs\alloyctl-AAAAMMDD.log` (Windows, 14
  dias). Se a instalação pelo comando do README falhar num terminal
  interativo, a ferramenta para e pergunta se deve continuar sem o
  `alloyctl` (arquivos temporários); em automação, segue com aviso. Falha de
  atualização nunca bloqueia: segue com a versão instalada.
- **Arquivos sob demanda**: instalação, credencial, módulos e heartbeat são
  baixados na primeira vez que a operação precisa deles, **da mesma versão** do
  núcleo, e ficam na pasta até a próxima versão.
- **Configuração do Alloy não muda sozinha**: a atualização mexe só no
  `alloyctl`. Aplicar uma configuração nova continua sendo **[1] Reaplicar
  configuração**.
- **Remoção**: a desinstalação mantém o `alloyctl`; a limpeza completa remove
  a pasta, o comando e (Windows) a entrada do PATH.

Executado a partir de um clone do repositório, o ponto de entrada usa os
arquivos locais e não instala nem atualiza o `alloyctl`.

## Versões e canais

| Canal | Como é resolvido | Uso |
|-------|------------------|-----|
| `stable` (padrão) | última release publicada | servidores e estações |
| `v1.2.0` | a própria tag, sem consulta (tags não mudam) | fixar uma versão |
| `main` ou outra branch | commit atual da branch (API do GitHub) | testar antes de publicar |

- `--ref <canal>` (`-Ref` no Windows) troca o canal e fica gravado (arquivo
  `channel` na pasta). O comando do README volta para `stable`, salvo com
  `--ref`.
- A última release é descoberta pelo redirecionamento de
  `github.com/DEV-ASSESSORIA-TECH/alloy/releases/latest`, que não conta no
  limite da API (60 consultas por hora por IP). Se esse endereço falhar, usa a
  API. `main` e outras branches continuam usando a API.
- Os arquivos são sempre baixados de
  `raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/<tag ou commit>/`. A
  release é só a tag: nenhum pacote anexado é usado.
- O cabeçalho do menu mostra `stable @ v1.0.0` (ou `main @ 1a2b3c4`).
- Instalações anteriores à separação do repositório (com arquivo `ref` em vez
  de `channel`) passam para `stable` na primeira execução. Veja
  [migracao.md](migracao.md).

## Versão do Alloy

Cada versão do `alloyctl` instala **uma versão fixa do Alloy**, definida em
[`alloy.Dockerfile`](../alloy.Dockerfile) na raiz do repositório (linha
`FROM grafana/alloy:vX.Y.Z`). O arquivo é baixado junto com o núcleo.

- **Primeira instalação**: instala a versão fixada.
- **Reaplicar configuração**: nunca muda a versão de um Alloy já instalado.
- **[3] Atualizar Alloy** (`upgrade`): leva o Alloy para a versão fixada.
  Nunca rebaixa: se o instalado for mais novo (atualizado na mão), fica, com
  aviso.
- **Linux**: o pacote fica retido (`apt-mark hold alloy`) para um
  `apt upgrade` do sistema não trocar a versão. A desinstalação libera o
  pacote antes de remover.
- **Windows**: o instalador oficial vem da release da Grafana com aquela
  versão, conferido pelo `SHA256SUMS` e pela assinatura.
- O diagnóstico marca em amarelo um Alloy instalado em versão diferente da
  fixada.

O Dependabot abre um PR quando sai uma versão nova do Alloy. Veja
[release.md](release.md#atualizar-a-versão-do-alloy).

## Comandos diretos (automação)

Os mesmos comandos valem para `alloyctl` e para o ponto de entrada baixado
(`alloy.sh` / `alloy.ps1`).

| Linux | Windows | Ação |
|-------|---------|------|
| `install [--modules docker\|none] [--upgrade]` | `install [-Perfil servidor\|estacao] [-Modules hyperv,sqlanywhere,mysql,dbct\|none] [-Upgrade]` | credencial (se ausente) + instalação |
| `credentials` | `credentials` | só o setup da credencial |
| `check` | `check` | testa a credencial gravada, sem alterar nada |
| `rotate` | `rotate` | troca a credencial e reinicia o Alloy |
| `modules docker\|none` | `modules hyperv,sqlanywhere,mysql,dbct\|none` | define os módulos opcionais (os não listados são desativados) |
| `upgrade` | `upgrade` | instala a versão do Alloy fixada nesta versão do `alloyctl` |
| `status` | `status` | diagnóstico |
| `uninstall [--yes]` | `uninstall [-Yes]` | remove o Alloy, mantendo credencial, configuração e o `alloyctl` |
| `purge [--yes]` | `purge [-Yes]` | limpeza completa (inclui o `alloyctl`) |
| `heartbeat [--url URL]` | `heartbeat [-Url URL]` | configura o heartbeat (Uptime Kuma + Loki) |
| `heartbeat-test` | `heartbeat-test` | executa o heartbeat agora e mostra o resultado |
| `heartbeat-remove [--yes]` | `heartbeat-remove [-Yes]` | remove o heartbeat |
| `update` | `update` | atualiza só o `alloyctl` e mostra a versão |

`--ref <canal>` (`-Ref`) troca o canal acompanhado (`stable`, uma tag,
`main`); `--no-update` (`-NoUpdate`) não atualiza antes de executar.
