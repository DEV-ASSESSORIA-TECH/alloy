# Heartbeat (Uptime Kuma + Loki)

Opcional, para os hosts: confirma de fora que o servidor está vivo e informa o
estado local do Alloy mesmo quando a telemetria dele para de chegar. Não é
oferecido na instalação; fica em **[9] Configurar heartbeat** (ou no comando
`heartbeat`). A cada minuto, sem depender do processo do Alloy:

1. lê o estado local: serviço, `/-/ready`, `/-/healthy` e o `/metrics` do
   Alloy (atraso do envio de métricas e contadores do envio de logs);
2. envia uma linha logfmt ao **Loki** (job `alloy-heartbeat`), com a
   credencial do Alloy. Sem credencial, só o Kuma recebe a batida;
3. faz o push no **Uptime Kuma** (sempre `status=up`) com um resumo curto no
   `msg`, só para quem olha a tela: o Kuma não exporta o `msg` para o
   Prometheus.

| Telemetria do Alloy | Heartbeat no Loki | Kuma | Leitura |
|---|---|---|---|
| ok | `alloy=ok` | UP | tudo certo |
| sem dados | `alloy=parado`, `degradado`... | UP | problema no Alloy; o motivo está no Loki |
| sem dados | sem dados | UP (`msg` com `loki=401`...) | credencial ou caminho até o `mon` |
| sem dados | sem dados | DOWN | host fora ou sem rede |

**Configurar.** No Uptime Kuma, crie um monitor **Push** chamado
`heartbeat-<host>`, com intervalo de 120 s, 1 tentativa e intervalo de nova
tentativa de 60 s (DOWN em ~3 min). Em [9], cole a URL de push completa, como
o Kuma mostra (`https://.../api/push/<token>?status=up&msg=OK&ping=`). O
endereço não fica no repositório. A configuração faz uma batida de teste e só
grava se o Kuma confirmar (404 = token errado ou monitor pausado). Depois
registra o agendamento e confere a primeira execução. Com o heartbeat
configurado, [9] abre **Testar agora**, **Reconfigurar** e **Remover**.

**Consultar no Grafana** (contrato `contracts/loki/heartbeat.yml` no
repositório `grafana-dashboards`):

```logql
{job="alloy-heartbeat", host="srv-hv01"} | logfmt
{job="alloy-heartbeat"} | logfmt | alloy != "ok"
max by (host) (max_over_time({job="alloy-heartbeat"} | logfmt | unwrap metrics_lag_s [5m]))
```

Campos: `alloy` (`ok`, `degradado`, `nao_pronto`, `parado`, `ausente`),
`service`, `ready`, `healthy`, `unhealthy`, `metrics_lag_s`, `samples_failed`,
`logs_sent`, `logs_dropped` e `version`. `degradado` = componente com problema
ou mais de 300 s sem enviar métricas.

| | Windows | Linux |
|---|---|---|
| Agendamento | tarefa `\GrafanaLabs\Alloy Heartbeat`, como SYSTEM, a cada minuto e no boot | `alloy-heartbeat.timer` → `alloy-heartbeat.service`, usuário dinâmico (sem root) no grupo `alloy`, systemd 247+ |
| Credencial do Alloy | lida direto (SYSTEM) | lida direto pelo grupo `alloy` (`root:alloy 0640`); no Linux, o heartbeat exige o Alloy instalado |
| URL de push | `heartbeat\kuma-url` (só SYSTEM e Administradores) | `/etc/alloy/heartbeat/kuma-url` (root, 0600), entregue por `LoadCredential=` |
| Script | `heartbeat\heartbeat.ps1` | `/usr/local/libexec/alloy-heartbeat/heartbeat.py` |
| Última execução | `heartbeat\last.json` | `/var/lib/alloy-heartbeat/last` |
| Logs | `heartbeat\logs\`, 14 dias | `journalctl -u alloy-heartbeat` |

A URL e o token OAuth2 nunca vão para log nem para a linha de comando. O
token fica em cache (mesma proteção da credencial) até perto de expirar.
**Desinstalar** para o agendamento e mantém a URL, para reativar em [9] sem
colar de novo; **Limpeza completa** remove tudo. Nos dois casos, pause ou
exclua o monitor no Kuma. Rotacionar a credencial não exige mexer no
heartbeat: ele lê o arquivo a cada execução.

Todas as chamadas a `auth` e `mon` (atrás da Cloudflare) usam User-Agent
próprio (`AssessoriaTech-Alloy-*`), não o padrão do PowerShell, Python ou curl.
Se a Cloudflare ainda desafiar clientes que não são navegador, crie uma regra
de *skip* no WAF para `/api/push/*` e `/loki/api/v1/push`.
