# Antivírus (Bitdefender GravityZone)

Antivírus com análise de comportamento podem interromper a instalação ou o
agente. Caso real: numa estação Windows, o **Advanced Threat Control** do
Bitdefender encerrou o instalador oficial do Alloy
(`ATC.SuspiciousBehavior`) enquanto ele rodava a partir de uma pasta
aleatória em `%TEMP%`. A desinfecção desfez parte da instalação (a chave do
registro sumiu) e o serviço ficou rodando com a configuração de exemplo do
pacote, sem enviar nada.

## O que o instalador faz para reduzir o risco (Windows)

- Baixa o instalador oficial para uma **pasta fixa**,
  `C:\ProgramData\AssessoriaTech\alloy-installer\`, restrita a SYSTEM e
  Administradores. Não usa mais `%TEMP%\<aleatório>`, que é o padrão "script
  baixou e executou um binário desconhecido" que o ATC vigia. A pasta fixa
  também permite exclusão por caminho. O conteúdo é apagado depois da
  instalação; a pasta fica.
- Antes de executar, confere o **SHA256** contra o `SHA256SUMS` da mesma
  release e a **assinatura Authenticode** (assinante `CN=Grafana Labs,
  O=Grafana Labs`). Se não bater, não executa.
- Se o instalador for encerrado, sumir depois da extração ou deixar a
  instalação incompleta, a mensagem aponta o antivírus, a quarentena e as
  pastas a excluir.
- Instalação incompleta (executável, serviço ou chave do registro faltando)
  é reinstalada pelo **[1] Reaplicar**. O menu mostra
  `[ !! ] sem configuracao (incompleto)` quando o serviço não usa a nossa
  configuração, em vez de "ativo e pronto".
- Na primeira instalação, uma falha deixa o serviço **parado** (início
  manual), em vez de rodando com o exemplo do pacote.

## Exclusões recomendadas

Aplicar na **política do GravityZone** (vale para todas as máquinas da
política), nos módulos Antimalware (no acesso) e Advanced Threat Control.

**Windows (servidores e estações)**

| Tipo | Caminho | Por quê |
|------|---------|---------|
| Pasta | `C:\Program Files\GrafanaLabs\Alloy\` | binário do agente e desinstalador |
| Processo | `C:\Program Files\GrafanaLabs\Alloy\alloy-windows-amd64.exe` | o agente lê eventos e contadores e envia pela rede o tempo todo |
| Pasta | `C:\ProgramData\GrafanaLabs\Alloy\` | configuração, credencial, WAL (`data\`, escrita contínua), bookmarks, scripts dos módulos, textfile, logs e heartbeat |
| Pasta | `C:\ProgramData\AssessoriaTech\alloy-installer\` | instalador oficial durante a instalação ou atualização |
| Processo | `C:\ProgramData\AssessoriaTech\alloy-installer\package\alloy-installer-windows-amd64.exe` | o processo que o ATC encerrou |
| Pasta | `C:\Program Files\AssessoriaTech\alloyctl\` | comando `alloyctl` (`alloyctl.cmd` + scripts PowerShell) |

**Linux (servidores)**

| Tipo | Caminho | Por quê |
|------|---------|---------|
| Processo | `/usr/bin/alloy` | o agente (pacote `alloy` do APT da Grafana) |
| Pasta | `/var/lib/alloy/` | WAL e posições, escrita contínua (desempenho) |
| Pasta | `/etc/alloy/` | configuração, credencial e backups |
| Pasta | `/opt/alloyctl/` | comando `alloyctl` (link em `/usr/local/bin/alloyctl`) |
| Pasta | `/usr/local/libexec/alloy-heartbeat/` | `heartbeat.py`, executado pelo timer `alloy-heartbeat` |
| Pasta | `/var/lib/alloy-heartbeat/` | estado do heartbeat |
| Pasta | `/var/lib/alloy-textfile/` | arquivos `.prom` dos backups, lidos pelo agente |

**Não excluir** `powershell.exe`, `bash`, `python3` nem pastas temporárias
inteiras: isso abriria uma brecha para qualquer script. As tarefas agendadas
dos módulos (`heartbeat.ps1`, `hypervisor-inventory.ps1`,
`sqlanywhere-collector.ps1`, `dbct-collector.ps1`) rodam com `powershell.exe -File <script>` a
partir das pastas acima. Se o ATC as bloquear, prefira uma exclusão por
**linha de comando** que contenha o caminho do script, se a versão do
GravityZone oferecer.

**Exclusão por certificado**: o instalador e o binário são assinados via
Microsoft Trusted Signing. O certificado da Grafana Labs é trocado a cada
poucos dias, então exclusão pela impressão digital do certificado deixa de
valer logo. Use o nome do assinante, se o console permitir, ou os caminhos
acima.

## Se o antivírus já agiu

1. Restaure da quarentena os arquivos do Alloy e crie as exclusões.
2. Windows: execute `alloyctl upgrade` (ou **[3] Atualizar Alloy**). O
   instalador oficial roda de novo, recria o que faltar e aplica a
   configuração. A credencial é mantida.
3. Confira no diagnóstico (**[6]**): `Config` sem erro e serviço "ativo e
   pronto".
