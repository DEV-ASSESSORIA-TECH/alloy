# Funcoes compartilhadas por alloy.ps1, install.ps1, uninstall.ps1 e
# heartbeat-setup.ps1 (carregar com ". ").
# Constantes, saida, confirmacoes e download via raw.
# Manter os .ps1 em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.

$RepoRaw     = 'https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy'
$RemoteDir   = 'windows'
$Base        = Join-Path $env:ProgramData 'GrafanaLabs\Alloy'
$Secret      = Join-Path $Base 'oauth-client-secret'
$ConfigDir   = Join-Path $Base 'config'
$DataDir     = Join-Path $Base 'data'
$BackupDir   = Join-Path $Base 'backups'
$BookmarkDir = Join-Path $DataDir 'bookmarks'
# Modulos com tarefa agendada: scripts\, textfile\<modulo>\ e logs\ sao
# compartilhados; cada modulo le apenas o proprio subdiretorio do textfile.
$ScriptsDir  = Join-Path $Base 'scripts'
$TextfileDir = Join-Path $Base 'textfile'
$InstallDir  = Join-Path $env:ProgramFiles 'GrafanaLabs\Alloy'
$Exe         = Join-Path $InstallDir 'alloy-windows-amd64.exe'
$Registry    = 'HKLM:\SOFTWARE\GrafanaLabs\Alloy'
$ServiceName = 'Alloy'
$ReadyUrl    = 'http://127.0.0.1:12345/-/ready'
# Assinatura propria nas chamadas HTTP (auth/mon ficam atras da Cloudflare).
$UserAgent   = 'AssessoriaTech-Alloy-Installer/1.0'
# Comando alloyctl (mesmo valor do alloy.ps1, que roda antes desta lib).
$AlloyCtlDir = Join-Path $env:ProgramFiles 'AssessoriaTech\alloyctl'
# Pasta fixa do instalador oficial (ops\install\Package.ps1, docs/antivirus.md).
$AlloyInstallerDir = Join-Path $env:ProgramData 'AssessoriaTech\alloy-installer'
$HyperVFile  = Join-Path $ConfigDir 'hyperv.alloy'
$SqlAnywhereFile = Join-Path $ConfigDir 'sqlanywhere.alloy'
$MysqlFile   = Join-Path $ConfigDir 'mysql.alloy'
$DbctFile    = Join-Path $ConfigDir 'dbct.alloy'
# Leitura dos backups: sempre instalada no perfil servidor (ver install.ps1).
$BackupFile         = Join-Path $ConfigDir 'backup.alloy'
$BackupTextfileDir  = Join-Path $Base 'textfile\backup'
$BackupWritersGroup = 'Alloy Backup Writers'
# Arquivo base de cada perfil (ver install.ps1 -Perfil).
$ServerFile  = Join-Path $ConfigDir 'config.alloy'
$DesktopFile = Join-Path $ConfigDir 'desktop.alloy'
# Inventario de VMs do modulo Hyper-V (ver install.ps1).
$LogDir            = Join-Path $Base 'logs'
$InventoryOutput   = Join-Path $Base 'textfile\hypervisor\hypervisor.prom'
$InventoryTaskPath = '\GrafanaLabs\'
$InventoryTaskName = 'Alloy Hypervisor Inventory'
# Coletor do modulo SQL Anywhere (ver install.ps1).
$SqlState          = Join-Path $DataDir 'sqlanywhere'
$SqlOutput         = Join-Path $Base 'textfile\sqlanywhere\sqlanywhere.prom'
$SqlTaskPath       = '\GrafanaLabs\'
$SqlTaskName       = 'Alloy SQL Anywhere'
# Modulo MySQL: exportador embutido do Alloy, sem tarefa (ver install.ps1).
$MysqlState        = Join-Path $DataDir 'mysql'
$MysqlMetricsUrl   = 'http://127.0.0.1:12345/api/v0/component/prometheus.exporter.mysql.mysql/metrics'
# Modulo DB Connection Tester: so o coletor (ver install.ps1).
$DbctState         = Join-Path $DataDir 'dbct'
$DbctOutput        = Join-Path $Base 'textfile\dbct\dbct.prom'
$DbctTaskPath      = '\GrafanaLabs\'
$DbctCollectorTask = 'Alloy DBCT Collector'
# Heartbeat opcional (Uptime Kuma + Loki), ver heartbeat-setup.ps1.
$HeartbeatDir      = Join-Path $Base 'heartbeat'
$HeartbeatUrlFile  = Join-Path $HeartbeatDir 'kuma-url'
$HeartbeatScript   = Join-Path $HeartbeatDir 'heartbeat.ps1'
$HeartbeatLast     = Join-Path $HeartbeatDir 'last.json'
$HeartbeatLogDir   = Join-Path $HeartbeatDir 'logs'
$HeartbeatTaskPath = '\GrafanaLabs\'
$HeartbeatTaskName = 'Alloy Heartbeat'
$UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
# Links do diagnostico. Datasource por nome ou UID, como cadastrado no Grafana.
$GrafanaUrl        = 'https://mon.assessoriatech.com/grafana'
$GrafanaDsMetrics  = 'Prometheus'
$GrafanaDsLogs     = 'Loki'

function Write-Log([string]$Text) { Write-Host "[Alloy] $Text" }
function Write-Ok([string]$Text) { Write-Host "[Alloy] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "[Alloy] AVISO: $Text" -ForegroundColor Yellow }

function Confirm-Choice([string]$Prompt, [bool]$DefaultYes = $true) {
    $hint = if ($DefaultYes) { '[S/n]' } else { '[s/N]' }
    $answer = (Read-Host "$Prompt $hint").Trim()
    if (-not $answer) { return $DefaultYes }
    return $answer -match '^(s|sim|y|yes)$'
}

function Get-AlloyRef {
    $ref = if ($env:ALLOY_REF) { $env:ALLOY_REF } else { 'main' }
    if ($ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $ref.Contains('..')) {
        throw "Referencia invalida: $ref"
    }
    return $ref
}

# Versao do Alloy fixada nesta versao do alloyctl. Fonte unica: o
# alloy.Dockerfile na raiz do repositorio ("FROM grafana/alloy:vX.Y.Z"), no
# formato que o Dependabot atualiza. O alloy.ps1 le o arquivo e repassa a versao
# em ALLOY_VERSION para os scripts filhos.
function Read-AlloyVersionFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Arquivo de versao do Alloy ausente: $Path" }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*FROM\s+grafana/alloy:v([0-9]+\.[0-9]+\.[0-9]+)\s*$') { return $Matches[1] }
    }
    throw "Versao do Alloy nao encontrada em $Path (esperado: FROM grafana/alloy:vX.Y.Z)."
}
function Get-AlloyPinnedVersion {
    $version = [string]$env:ALLOY_VERSION
    if ($version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "Versao do Alloy ausente ou invalida (ALLOY_VERSION='$version'). Execute pelo alloyctl."
    }
    return $version
}

# Cliente HTTP unico: as requisicoes reutilizam a mesma conexao TLS.
function Get-HttpClient {
    if (-not $script:HttpClient) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Add-Type -AssemblyName System.Net.Http
        $script:HttpClient = [System.Net.Http.HttpClient]::new()
        $script:HttpClient.Timeout = [TimeSpan]::FromSeconds(30)
        $script:HttpClient.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)
    }
    return $script:HttpClient
}

# Cliente HTTP sem proxy para 127.0.0.1: o Invoke-WebRequest do 5.1 tenta
# descobrir proxy (WPAD) e pode levar segundos por tentativa.
function Get-LocalHttp {
    if (-not $script:LocalHttp) {
        Add-Type -AssemblyName System.Net.Http
        $handler = [System.Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $script:LocalHttp = [System.Net.Http.HttpClient]::new($handler)
        $script:LocalHttp.Timeout = [TimeSpan]::FromSeconds(2)
    }
    return $script:LocalHttp
}

# Baixa do raw somente os arquivos ausentes em $Destination.
# Em modo local (clone do repositorio), um arquivo ausente e erro.
function Save-RemoteFiles([string]$Destination, [string[]]$Names) {
    $missing = @($Names | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $Destination $_) -PathType Leaf)
    })
    if ($missing.Count -eq 0) { return }
    if ($script:LocalMode) { throw "Arquivo ausente no repositorio local: $($missing -join ', ')" }
    $ref = Get-AlloyRef
    $http = Get-HttpClient
    foreach ($name in $missing) {
        $target = Join-Path $Destination ($name -replace '/', '\')
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $response = $http.GetAsync("$RepoRaw/$ref/$RemoteDir/$name").GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) {
                throw "Falha ao baixar $name (HTTP $([int]$response.StatusCode), ref $ref)."
            }
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -eq 0) { throw "Download vazio: $name" }
            [IO.File]::WriteAllBytes($target, $bytes)
        } finally {
            $response.Dispose()
        }
    }
}

function Ensure-Directory([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Diretorio invalido: $Path"
        }
    } else {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

# SYSTEM e Administradores com controle total; -Writers recebe Modify (gravar,
# substituir e apagar arquivos, sem alterar permissoes).
function Set-PrivateDirectoryAcl([string]$Path, [System.Security.Principal.SecurityIdentifier[]]$Writers = @()) {
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $admin = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $acl.SetOwner($admin)
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $id = [System.Security.Principal.SecurityIdentifier]::new($sid)
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($id, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    foreach ($id in @($Writers | Where-Object { $null -ne $_ })) {
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($id, [System.Security.AccessControl.FileSystemRights]::Modify, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

# O script roda como SYSTEM: so e instalado se o parser do PowerShell aceitar.
function Assert-ScriptSyntax([string]$Path) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $first = $errors[0]
        throw "$(Split-Path -Leaf $Path) com erro de sintaxe (linha $($first.Extent.StartLineNumber)): $($first.Message)"
    }
}

# Versao instalada (Programas e Recursos), sem o "v"; vazio se nao houver.
function Get-InstalledAlloyVersion {
    $entry = Get-AlloyUninstallEntry
    if ($entry -and $entry.DisplayVersion) { return (([string]$entry.DisplayVersion).Trim() -replace '^v', '') }
    return ''
}

# Entrada do Alloy em "Programas e Recursos" (versao e desinstalador).
function Get-AlloyUninstallEntry {
    Get-ItemProperty -Path $UninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*Alloy*' -and $_.Publisher -like '*Grafana*' } |
        Select-Object -First 1
}
