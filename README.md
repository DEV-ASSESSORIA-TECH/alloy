# Grafana Alloy

Instalação e gestão do agente [Grafana Alloy](https://grafana.com/docs/alloy/latest/),
que envia métricas e logs de cada servidor ao monitoramento central.

Um único comando abre a ferramenta: **`alloyctl`**, instalado no servidor na
primeira execução do comando abaixo. Na primeira vez, ele segue direto o fluxo
de credencial e depois a instalação. Nas seguintes, abre um menu:

```
 ==============================================================
  GRAFANA ALLOY                                        srv-web
 ==============================================================
  Servico      [ OK ]  ativo e pronto         v1.11.2
  Credencial   [ OK ]  alloy-srv-web
  Modulos              Linux
  Ultima acao  [ OK ]  Testar credencial - concluido (10:42)
 --------------------------------------------------------------
  INSTALACAO                    CREDENCIAL
   [1] Reaplicar configuracao    [4] Testar
   [2] Ativar Docker             [5] Rotacionar
   [3] Atualizar Alloy

  DIAGNOSTICO                   REMOCAO
   [6] Ver diagnostico           [7] Desinstalar
   [9] Configurar heartbeat      [8] Limpeza completa
 --------------------------------------------------------------
  Tecle a opcao (0 sai):
```

As opções são escolhidas com uma tecla, sem Enter. Quando o serviço não
está instalado ou está parado, Enter executa a opção recomendada ([1]). O
diagnóstico mostra avisos e erros das últimas 24h, a conectividade com
`auth` e `mon` e links do Grafana Explore já filtrados pelo host.

## Executar

**Linux (Debian/Ubuntu)**

```bash
(
  set -e
  dir=$(mktemp -d)
  trap 'rm -rf "$dir"' EXIT
  curl -fsSL https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/main/linux/alloy.sh -o "$dir/alloy.sh"
  sudo bash "$dir/alloy.sh"
)
```

**Windows Server ou estação (PowerShell como Administrador)**

```powershell
$dir = Join-Path $env:TEMP ("alloy-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    Invoke-WebRequest "https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/main/windows/alloy.ps1" -OutFile "$dir\alloy.ps1" -UseBasicParsing
    & "$dir\alloy.ps1"
} finally {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}
```

O ponto de entrada vem da `main`, mas o que ele instala é a **última release**
(canal `stable`). Para testar o que ainda não foi publicado, acrescente
`--ref main` (`-Ref main`); para fixar uma versão, `--ref v1.0.0`.

Depois da primeira execução, basta `alloyctl` (ou `alloyctl <comando>`). O
comando acima continua valendo: com o `alloyctl` instalado, ele o atualiza e
abre o menu.

## Documentação

| Assunto | Arquivo |
|---------|---------|
| `alloyctl`: atualização, versões e canais, comandos diretos | [docs/alloyctl.md](docs/alloyctl.md) |
| Antivírus (Bitdefender GravityZone): exclusões e recuperação | [docs/antivirus.md](docs/antivirus.md) |
| Perfil estação (Windows) e instalação pelo Tactical RMM | [docs/perfil-estacao.md](docs/perfil-estacao.md) |
| Leitura de backups (`integrations/backup`) | [docs/backups.md](docs/backups.md) |
| Módulos opcionais: Hyper-V, SQL Anywhere, MySQL, DB Connection Tester | [docs/modulos.md](docs/modulos.md) |
| Heartbeat (Uptime Kuma + Loki) | [docs/heartbeat.md](docs/heartbeat.md) |
| Publicar uma versão | [docs/release.md](docs/release.md) |
| Migração a partir do repositório `scripts` | [docs/migracao.md](docs/migracao.md) |

## Estrutura

```
alloy/
├── linux/
│   ├── alloy.sh          # ponto de entrada (alloyctl): menu e comandos
│   ├── lib/              # núcleo: common (constantes, download), state (estado, diagnóstico), ui
│   ├── ops/              # install.sh, uninstall.sh, setup-credentials.py
│   ├── heartbeat/        # heartbeat.py e heartbeat-setup.sh
│   └── modules/          # config.alloy (base), backup.alloy, docker.alloy
├── windows/
│   ├── alloy.ps1         # ponto de entrada (alloyctl)
│   ├── lib/              # Common, State, Ui
│   ├── ops/              # install.ps1 (+ install/: pacote, backup e um arquivo por módulo),
│   │                     # uninstall.ps1, setup-credentials.ps1
│   ├── heartbeat/        # heartbeat.ps1 e heartbeat-setup.ps1
│   ├── modules/          # config.alloy (servidor), desktop.alloy (estação), backup, hyperv,
│   │                     # sqlanywhere, mysql, dbct (.alloy)
│   ├── collectors/       # tarefas agendadas: hypervisor-inventory, sqlanywhere-collector, dbct-collector
│   └── rmm/              # tactical-estacao.ps1 (Tactical RMM, sem perguntas)
├── docs/
├── tests/                # bats (linux/), Pester (windows/), caminhos e contratos do Grafana
├── .github/              # ci.yml, release.yml e dependabot.yml (versão do Alloy)
├── alloy.Dockerfile      # versão fixa do Alloy instalada pelo alloyctl
└── CHANGELOG.md
```

O `alloyctl` guarda na máquina a mesma estrutura (`/opt/alloyctl/` ou
`C:\Program Files\AssessoriaTech\alloyctl\`): o núcleo (ponto de entrada +
`lib/`) a cada versão, o resto sob demanda. Executado a partir de um clone,
o ponto de entrada usa os arquivos locais e não instala nem atualiza o
`alloyctl`.

## Convenções

- Scripts idempotentes: executar de novo não deve causar alterações sem
  necessidade.
- Nenhuma credencial no repositório. Segredos são informados na execução e
  gravados apenas no servidor de destino.
- Arquivos `.ps1` em ASCII, para compatibilidade com o Windows PowerShell 5.1.
- Mudanças entram pela `main` com uma linha no `CHANGELOG.md` (seção
  *Não publicado*); chegam às máquinas só quando houver release.

## Licença

Uso permitido para estudo e desenvolvimento próprio. Links, IDs e
credenciais da infraestrutura da Assessoria Tech **não** podem ser usados por
terceiros sem autorização. Veja [LICENSE](LICENSE).
