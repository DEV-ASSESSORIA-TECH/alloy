# Backups

Todo servidor (Linux e Windows no perfil servidor) tem a leitura de backups:
o `backup.alloy` lê uma pasta e publica o que estiver nela no job
`integrations/backup`. Não é módulo opcional nem tem coletor: quem sabe do
backup (o próprio software ou um script que observa outro sistema) grava o
arquivo, e o Alloy só lê e envia. Pasta vazia não publica nada, então um host
sem backup não gera série nem alerta.

| | Linux | Windows |
|-|-------|---------|
| Pasta | `/var/lib/alloy-textfile/backup/` | `C:\ProgramData\GrafanaLabs\Alloy\textfile\backup\` |
| Escrita | root e o grupo `alloy-backup` (setgid: arquivos novos herdam o grupo) | SYSTEM, Administradores e o grupo local `Alloy Backup Writers` (Modify) |
| Leitura | todos (o Alloy roda como `alloy` ou root) | SYSTEM (conta do serviço Alloy) |

O instalador cria a pasta e o grupo a cada aplicação ([1] Reaplicar). Para um
produtor gravar, coloque a conta que o executa no grupo:

```bash
sudo usermod -aG alloy-backup <conta>
```

```powershell
net localgroup "Alloy Backup Writers" <conta> /add
```

A associação vale no próximo logon da conta (no Windows, na próxima execução
de uma tarefa agendada). Num controlador de domínio, sem grupos locais, a
pasta fica só com SYSTEM e Administradores e o instalador avisa.

O formato está no contrato `contracts/prometheus/backup.yml` do repositório
`grafana`. Resumo:

- um arquivo por backup, `<service>__<backup_id>.prom`, e cada produtor só
  escreve o próprio;
- o produtor publica só os labels `service` e `backup_id`; `job`, `instance` e
  `host` são do Alloy;
- HELP e TYPE iguais aos do contrato; escrita atômica (`.prom.tmp` e rename na
  mesma pasta); LF e quebra de linha no final; no Linux, arquivo legível por
  todos (`0644`);
- aposentar um backup = apagar o arquivo.

Os alertas (área `backups`, códigos BKP no repositório `grafana`) são genéricos:
nenhum servidor ou horário fica nas regras. O que cada produtor publica define
como o backup é avaliado:

| O produtor publica | Efeito nos alertas |
|---|---|
| `backup_success_due_timestamp_seconds` (prazo do próximo sucesso: primeira execução agendada depois do último sucesso) | Atraso medido pelo prazo; preciso em qualquer agenda (fim de semana, mensal) |
| só `backup_expected_interval_seconds` (maior intervalo entre execuções) | Atraso medido pelo intervalo |
| nenhum dos dois | Sem alerta de atraso; falha, degradado e coleta continuam valendo |
| `criticality="baixa"` em `backup_info` | Alertas do backup um nível abaixo (padrão `alta`) |

Para garantir que um backup existe (e alertar se nunca for reportado), liste-o
na seção `backups` do `catalogo.yml` do repositório `grafana`. A lista é opt-in:
servidor sem backup interno não entra.

No Linux, série duplicada em dois arquivos ou HELP diferente para a mesma
métrica são descartadas sem erro; arquivo inválido ou pasta ausente aparecem
como `node_textfile_scrape_error 1`. No Windows, o mesmo erro aparece como
`windows_exporter_collector_success{collector="textfile"} 0`. O diagnóstico ([6]) mostra a seção
**BACKUPS** com os arquivos presentes e os membros do grupo.
