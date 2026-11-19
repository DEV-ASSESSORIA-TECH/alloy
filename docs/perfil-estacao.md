# Perfil estação (Windows)

Para máquinas Windows de uso pessoal, descartáveis, que podem sumir a qualquer
momento. Elas publicam em jobs próprios e por isso ficam fora dos alertas e dos
dashboards de servidores, que sempre fixam o job:

| | Servidor | Estação |
|---|---|---|
| Configuração | `config\config.alloy` | `config\desktop.alloy` |
| Métricas | `integrations/windows` | `integrations/windows-desktop` |
| Logs | `windows-eventlog` | `windows-desktop-eventlog` (só crítico, erro e aviso) |
| Coletores | inclui `service` | sem `service`; scrape de 60 s |
| Credencial | `alloy-<hostname>` | compartilhada: `alloy-estacoes` |
| Módulos opcionais e heartbeat | disponíveis | só os módulos MySQL e DBCT |
| Leitura de backups | sim | não |
| Alertas | sim | nenhum |

Na primeira instalação o perfil é detectado: estação no Windows de cliente
(10/11), servidor no Windows Server. No modo interativo dá para trocar antes de
continuar; na automação, use `alloyctl install -Perfil estacao`. Depois,
reaplicar e atualizar mantêm o perfil instalado. Trocar de perfil é
`alloyctl install -Perfil <outro>`: o arquivo base do outro perfil é removido
(com o mesmo rollback) e, ao virar estação, os módulos Hyper-V e SQL Anywhere
ativos são desativados (MySQL e DBCT são mantidos). No menu, Hyper-V, SQL Anywhere e
**[9] Heartbeat** aparecem como "(so servidor)" e só servem para remover o que
já existia.

A conta `alloy-estacoes` é uma só para todas as estações: uma máquina que some
não deixa credencial órfã, e revogar a conta corta todas de uma vez.

Ao converter para estação uma máquina que já mandava métricas como servidor, a
série antiga some e o alerta de servidor sem métricas (WIN-102) dispara por até
7 dias. Marque o host como `ignorar` em `servidores:` no `catalogo.yml` do
`grafana-dashboards` durante a transição.

## Estações pelo Tactical RMM

Para instalar sem terminal interativo (o Tactical roda o script como SYSTEM,
sem área de trabalho), use `windows/rmm/tactical-estacao.ps1`. Ele não faz
nenhuma pergunta: baixa o `alloy.ps1`, instala o `alloyctl` e executa
`install -Perfil estacao`.

1. **Senha no Key Store**: *Settings > Global Settings > Key Store*, chave
   `ALLOY_ESTACOES_SENHA` com a senha de aplicativo da `alloy-estacoes`.
2. **Script**: *Settings > Script Manager > New Script*, com o conteúdo de
   `windows/rmm/tactical-estacao.ps1`, Shell `PowerShell`, timeout `900` e
   *Run As User* desmarcado.
3. **Environment vars** do script:
   `ALLOY_PASSWORD={{global.ALLOY_ESTACOES_SENHA}}`. **Não** passe a senha em
   *Script Arguments*: argumentos ficam na linha de comando do processo e no
   histórico.
4. Execute na estação (ou em lote por *Bulk Script*). Saída `0` = instalado;
   `1` = falha, com o motivo na saída.

O script é idempotente: com a credencial já gravada, só reaplica a
configuração (útil depois de mudar o `desktop.alloy`). A credencial é testada
(OAuth2 + Loki) antes de ser gravada; senha errada não altera nada.

Fora do Tactical vale o mesmo mecanismo: se `ALLOY_PASSWORD` estiver definida,
o `setup-credentials.ps1` usa a conta do perfil e não pergunta nada (a
variável é apagada do processo logo após a leitura). Sem ela e sem terminal
interativo, para na hora com o motivo, em vez de esperar a janela de senha que
ninguém vê.
