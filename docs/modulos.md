# Módulos opcionais (Windows)

Na instalação (`-Modules auto`, padrão), os módulos já ativos são mantidos e os
detectados são oferecidos (só em terminal interativo). `-Modules` com uma lista
(`hyperv`, `sqlanywhere`, `mysql`, `dbct` ou combinações, como `hyperv,sqlanywhere`)
define o conjunto completo: os não listados são desativados; `none` desativa
todos. No menu, **[2] Módulos opcionais** liga e desliga cada um sem afetar os
outros. O DBCT nunca é oferecido automaticamente: ative-o pelo menu ou com
`-Modules dbct`.

Cada módulo com coletor próprio grava em um subdiretório de `textfile\` e o
Alloy lê só esse subdiretório, em job próprio. O MySQL não tem coletor: usa o
exportador embutido do Alloy.

## Módulo Hyper-V

Detectado automaticamente na instalação (serviço `vmms` ativo e `Get-VM`
acessível). Em servidores que já têm o módulo, **[1] Reaplicar configuração**
atualiza tudo, inclusive o inventário de VMs.

| Parte | Onde | O que faz |
|-------|------|-----------|
| Métricas Hyper-V | `config\hyperv.alloy`, job `integrations/hyperv` | contadores do hypervisor: CPU, memória, discos e rede virtuais |
| Inventário de VMs | `scripts\hypervisor-inventory.ps1`, job `integrations/hypervisor` | estado de cada VM (inclusive desligadas), sistema convidado, vCPU, memória, checkpoints, heartbeat, discos e placas de rede |
| Logs | `hyperv.alloy`, job `hyperv-eventlog` | canais VMMS-Admin e Worker-Admin |

O inventário roda a cada minuto, como SYSTEM, pela tarefa agendada
`\GrafanaLabs\Alloy Hypervisor Inventory`, e grava `textfile\hypervisor\hypervisor.prom`,
lido pelo coletor `textfile` do Alloy (requer Alloy v1.11+). As métricas usam
nomes neutros (`hypervisor_*`, com `platform="hyperv"`) para que outras
plataformas possam publicar o mesmo formato.

Diretórios em `C:\ProgramData\GrafanaLabs\Alloy` (acesso só de SYSTEM e
Administradores):

| Diretório | Conteúdo | Retenção |
|-----------|----------|----------|
| `scripts\` | script do inventário | substituído a cada reaplicação |
| `textfile\hypervisor\` | `hypervisor.prom` | sobrescrito a cada execução |
| `data\hypervisor\` | `guests.json`: último hostname/SO conhecido de cada VM (VM desligada não informa) | VMs removidas saem na execução seguinte |
| `logs\` | `hypervisor-inventory-AAAAMMDD.log`, uma linha por execução | 14 dias |

Desativar o módulo remove a tarefa, o script, a saída, o cache e os logs do
inventário. Desinstalar o Alloy remove a tarefa; a limpeza completa remove
também os arquivos. A reaplicação apaga o `textfile\hypervisor.prom` das
versões anteriores, gravado na raiz do `textfile\`.

## Módulo SQL Anywhere

Para servidores com SAP SQL Anywhere 17. Detectado na instalação por serviço
ou processo `dbsrv17.exe`/`dbeng17.exe`. Requer o driver ODBC
`SQL Anywhere 17` de **64 bits** e um usuário SQL somente leitura: o coletor só
executa `PROPERTY()` e `DB_PROPERTY()`. Na ativação, o instalador pede
servidor (ENG), banco (DBN), usuário e senha, e **testa a conexão antes de
gravar**. Para trocar esses dados: **[2] Módulos opcionais → [3] Reconfigurar
SQL Anywhere** (ou `install.ps1 -ReconfigureSqlAnywhere`).

| Parte | Onde | O que faz |
|-------|------|-----------|
| Coletor | `scripts\sqlanywhere-collector.ps1`, job `integrations/sqlanywhere` | servidor: conexões, workers e fila, commits e rollbacks, thread deadlocks, CPU, início, cache (alocado, em uso, livre, sujo, panics) e memória de consulta; banco: leituras de cache e disco, gravações, flushes, checkpoints, locks, tamanho do arquivo e urgência de checkpoint/recuperação |

O coletor roda a cada 30 s, como SYSTEM, pela tarefa agendada
`\GrafanaLabs\Alloy SQL Anywhere` (dois gatilhos de 1 min defasados em 30 s:
o Agendador não repete em menos de 1 min), sem execuções simultâneas e com
limite de 25 s. Conecta via ODBC local (`LINKS=SharedMemory,TCPIP(HOST=127.0.0.1)`)
e grava `textfile\sqlanywhere\sqlanywhere.prom`. Suporta um par ENG/DBN por
servidor.

Métricas: `sqlanywhere_server_*` (`PROPERTY`) e `sqlanywhere_database_*`
(`DB_PROPERTY`), com labels `server` e `database`; `sqlanywhere_info` traz a
versão. Tamanhos de cache são convertidos de KB para bytes e contagens de páginas
(cache em uso/livre, arquivo do banco) multiplicadas pelo `PageSize` do escopo.
A propriedade `Commit` do banco conta flushes do cache de disco
(`sqlanywhere_database_disk_flushes_total`); os COMMITs vêm do servidor
(`sqlanywhere_server_commits_total`). `StartTime` vira `_start_time_seconds` (Unix). A saúde da coleta
fica em `sqlanywhere_up`, `sqlanywhere_collection_success`,
`sqlanywhere_collection_missing_properties`, `_duration_seconds` e
`_timestamp_seconds`. Propriedade sem valor numérico não gera série (nunca
vira zero) e a lista vai para o log quando muda. Em falha, só as métricas de
saúde são publicadas.

| Diretório | Conteúdo | Retenção |
|-----------|----------|----------|
| `scripts\` | `sqlanywhere-collector.ps1` | substituído a cada reaplicação |
| `textfile\sqlanywhere\` | `sqlanywhere.prom` | sobrescrito a cada execução |
| `data\sqlanywhere\` | `config.json` (servidor, banco, usuário e `links`) e `password.dpapi` (senha cifrada com DPAPI da máquina) | mantidos ao desativar o módulo ou desinstalar; removidos na limpeza completa |
| `logs\` | `sqlanywhere-collector-AAAAMMDD.log`: falhas e mudanças nas propriedades ausentes | 14 dias |

Para usar outro protocolo ou porta, edite `links` no `config.json` (sintaxe do
parâmetro `LINKS` do SQL Anywhere); o coletor relê o arquivo a cada execução. Desativar o módulo remove a
tarefa, o script, a saída e os logs; a configuração fica para reativar sem
digitar de novo.

## Módulo MySQL

Para servidores Windows com MySQL (testado com o 5.5) ou MariaDB, uma
instância por máquina. Detectado na instalação por serviço ou processo
`mysqld.exe`/`mariadbd.exe` e oferecido no perfil servidor; no perfil estação
vale também, mas só ativado pelo menu ou com `-Modules mysql`. Para trocar
usuário, senha ou porta, ou reler os caminhos dos logs depois de mudar a
configuração do MySQL: **[2] Módulos opcionais → [7] Reconfigurar MySQL** (ou
`install.ps1 -ReconfigureMysql`).

| Parte | Onde | O que faz |
|-------|------|-----------|
| Métricas | `config\mysql.alloy` (exportador embutido do Alloy), job `integrations/mysql` | `SHOW GLOBAL STATUS`, `SHOW GLOBAL VARIABLES` e threads por estado (`information_schema.PROCESSLIST`), a cada 30 s |
| Logs | `mysql.alloy`, job `mysql` no Loki | error log (`log_type="error"`, com `level` = `error`, `warning` ou `note`) e slow query log (`log_type="slow"`, uma entrada por consulta) |

Sem tarefa agendada nem script: o Alloy conecta direto no MySQL
(`127.0.0.1`, TCP). Só os coletores `global_status`, `global_variables` e
`info_schema.processlist` ficam ativos: o padrão do exportador inclui o
`slave_status`, que usa `SHOW REPLICA STATUS` e falha no 5.5.

### Usuário de monitoramento

Nome padrão **`alloy`**, o mesmo em todos os servidores. Precisa só do
privilégio `PROCESS` (ver as conexões de outros usuários); não lê nenhuma
tabela. Crie com um administrador do MySQL, trocando a senha:

```sql
CREATE USER 'alloy'@'localhost' IDENTIFIED BY 'SENHA';
CREATE USER 'alloy'@'127.0.0.1' IDENTIFIED BY 'SENHA';
GRANT PROCESS ON *.* TO 'alloy'@'localhost' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS ON *.* TO 'alloy'@'127.0.0.1' WITH MAX_USER_CONNECTIONS 3;
```

As duas contas cobrem o MySQL com e sem resolução de nomes
(`skip-name-resolve`): a conexão chega como `127.0.0.1` ou como `localhost`.
`MAX_USER_CONNECTIONS 3` impede que o monitoramento ocupe conexões do sistema.
Para conferir: `SHOW GRANTS FOR 'alloy'@'127.0.0.1';`. Para trocar a senha
(depois, **Reconfigurar MySQL**; sintaxe do 5.5 e 5.6, no 5.7+ use
`ALTER USER ... IDENTIFIED BY`):

```sql
SET PASSWORD FOR 'alloy'@'localhost' = PASSWORD('NOVA');
SET PASSWORD FOR 'alloy'@'127.0.0.1' = PASSWORD('NOVA');
```

### Ativação

Na ativação, o instalador pergunta usuário (padrão `alloy`), porta (padrão
3306), o `mysql.exe` (sugere o da pasta `bin` do serviço) e a senha, e **testa
a conexão antes de gravar** com o `mysql.exe`, pela mesma rota do Alloy
(TCP em `127.0.0.1`, sem ler o `my.ini`; senha pelo ambiente, nunca na linha
de comando). Na mesma conexão lê do próprio servidor `@@log_error`,
`@@slow_query_log`, `@@slow_query_log_file` e `@@log_output`: os logs lidos
são os que o MySQL realmente usa. Ao final, confere pelo Alloy que o
exportador conectou (`mysql_up 1`).

### Logs

- **Error log**: lido se o arquivo existir. Linhas sem data (detalhes de
  deadlock, falhas do InnoDB) entram na entrada anterior. `level`: `error`
  (`[ERROR]`, erros e asserções do InnoDB, `got exception`), `warning`
  (`[Warning]`, deadlocks) ou `note` (o resto).
- **Slow query log**: lido só com `slow_query_log=ON` e `log_output` com
  `FILE`. Uma entrada por consulta (de `# User@Host:` até o SQL), com
  `Query_time`, `Lock_time`, `Rows_sent` e `Rows_examined`. As linhas
  `# Time:` e o cabeçalho de cada início do servidor são descartados.
- A primeira leitura começa do fim de cada arquivo (o histórico não é
  reenviado); depois a posição fica em `data\`. O horário das entradas é o da
  leitura (segundos depois da gravação).

O módulo **não altera** a configuração do MySQL. Para ter consultas lentas e
deadlocks no Loki, ligue no `my.ini` (seção `[mysqld]`) e reinicie o serviço
na janela do sistema; ou, sem reiniciar, com `SET GLOBAL` (vale até o próximo
reinício):

```ini
slow_query_log = 1
long_query_time = 2
innodb_print_all_deadlocks = 1
```

```sql
SET GLOBAL slow_query_log = 1;
SET GLOBAL long_query_time = 2;
SET GLOBAL innodb_print_all_deadlocks = 1;
```

O `long_query_time` define o que é "lento"; 2 s é um ponto de partida.
`log_slow_queries` é o nome antigo do `slow_query_log` (5.0/5.1). Depois de
ligar, use **Reconfigurar MySQL** para incluir o arquivo.

### Arquivos

| Diretório | Arquivos | Ciclo de vida |
|---|---|---|
| `config\` | `mysql.alloy` | substituído a cada reaplicação; removido ao desativar |
| `data\mysql\` | `dsn` (`usuario:senha@tcp(host:porta)/`, lido pelo Alloy como segredo) e `config.json` (host, porta, usuário, `mysql.exe` e logs lidos) | mantidos ao desativar o módulo ou desinstalar; removidos na limpeza completa |

A senha não usa DPAPI, como no SQL Anywhere: quem a lê é o próprio Alloy
(`local.file` com `is_secret`), que não decifra DPAPI. O arquivo fica só com
a ACL de `data\` (SYSTEM e Administradores) e não aparece na configuração, na
interface do Alloy nem nos logs. O Alloy relê `dsn` e `config.json` sozinho:
reconfigurar não reinicia o serviço. Para outra porta ou host, prefira
**Reconfigurar MySQL** (testa antes); editar os dois arquivos à mão também
funciona.

No diagnóstico (**[6]**), a seção MYSQL mostra o alvo, se o exportador está
conectado (com a versão), coletores com falha e os logs lidos.

## Módulo DB Connection Tester

Publica no Prometheus as falhas e lentidões de uma execução do
[DB Connection Tester](https://github.com/DEV-ASSESSORIA-TECH/DBConnectionTester)
(DBCT), para consultar pelo horário. Vale para servidores **e estações**.

O módulo **só lê** o banco do DBCT, pela CLI pública (`dbct run status` e
`dbct history cycles`). A execução é do próprio DBCT, que funciona sem o Alloy:
para mantê-la rodando e voltando com o Windows, configure-a no DBCT, por exemplo
em um terminal de administrador:

```powershell
dbct run --type tcp --host srv-db --port 1433 --interval 5 --data-dir "C:\ProgramData\DBConnectionTester" --autostart
```

(`dbct run status`, `dbct run stop`, `dbct autostart show|disable`; veja o guia da
CLI do DBCT.) Requer um DBCT com `run status` e `history cycles`, posterior à 3.0.0.

Ative em **[2] Módulos opcionais > [4] Ativar DBCT** (ou `-Modules dbct`). A
configuração pergunta, sugerindo o que encontrar na máquina, o `dbct.exe` (MSI por
máquina ou por usuário, PATH ou portátil) e a pasta do banco do DBCT, a que contém
o `data.db`. A primeira sugestão é a pasta da execução automática do DBCT (por
exemplo `C:\ProgramData\DBConnectionTester\Monitor\mysql-erp`); depois vêm as
demais pastas de `Monitor`, a compartilhada, as locais e a portátil. Avisa se o banco não tiver execução ativa nem automática.
**[5] Reconfigurar DBCT** (ou `install.ps1 -ReconfigureDbct`) pergunta de novo.

| Parte | Onde | O que faz |
|---|---|---|
| Coletor | tarefa `\GrafanaLabs\Alloy DBCT Collector` (a cada 30 s), `scripts\dbct-collector.ps1`, job `integrations/dbconnectiontester` | encontra a execução ativa, processa só os ciclos novos e grava `textfile\dbct\dbct.prom` |

Métricas (sem labels de host além dos que o Alloy adiciona; uma execução por banco):

| Métrica | Uso |
|---|---|
| `dbct_stage_failures_total{stage,code}` | falhas por etapa (`dns`, `ping`, `tcp`, `database_connect`, `database_query`) e código de diagnóstico do DBCT |
| `dbct_stage_duration_seconds` (histograma) e `dbct_stage_duration_max_seconds{stage}` | lentidão: quantis por janela e pior duração entre duas coletas |
| `dbct_stage_checks_total{stage}`, `dbct_cycles_total` | volume de testes |
| `dbct_stage_last_success{stage}`, `dbct_stage_last_duration_seconds{stage}` | estado do último ciclo |
| `dbct_run_active`, `dbct_run_info{run_id,profile,target,database_type}` | execução monitorada |
| `dbct_autostart_configured`, `dbct_autostart_running` | execução automática do DBCT no banco |
| `dbct_collection_success`, `_duration_seconds`, `_timestamp_seconds` | saúde da coleta |

Consultas para investigar um horário (Explore, intervalo em volta do horário
informado):

```promql
sum by (stage, code) (increase(dbct_stage_failures_total{host="<host>"}[5m]))
histogram_quantile(0.95, sum by (stage, le) (rate(dbct_stage_duration_seconds_bucket{host="<host>"}[5m])))
max by (stage) (dbct_stage_duration_max_seconds{host="<host>"})
```

Os contadores pertencem à execução atual e voltam a zero numa execução nova
(`increase` e `rate` tratam isso). Ao encontrar pela primeira vez uma execução
iniciada há mais de 2 minutos, o coletor começa a partir do ciclo atual, sem
lançar o passado no horário presente; o detalhe ciclo a ciclo continua no
histórico do DBCT.

| Pasta | Arquivos | Ciclo de vida |
|---|---|---|
| `scripts\` | `dbct-collector.ps1` | substituído a cada reaplicação |
| `textfile\dbct\` | `dbct.prom` | sobrescrito a cada execução |
| `data\dbct\` | `config.json` (`dbct.exe` e pasta do banco) | mantido ao desativar o módulo ou desinstalar; removido na limpeza completa |
| `data\dbct\` | `state.json` (posição e contadores da coleta) | removido ao desativar o módulo |
| `logs\` | `dbct-collector-AAAAMMDD.log` | 14 dias |

Desativar o módulo ou desinstalar o Alloy não altera o DBCT: a execução
automática, se configurada, continua.
