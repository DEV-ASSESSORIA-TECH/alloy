# Carregado (". ") pelo ops\install.ps1: modulo SQL Anywhere (coletor agendado).
# Manter em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.

# Coletor SQL Anywhere: script, configuracao (com senha DPAPI), saida e logs.
$SqlCollectorName = 'sqlanywhere-collector.ps1'
$SqlCollectorScript = Join-Path $ScriptsDir $SqlCollectorName
$SqlConfigFile = Join-Path $SqlState 'config.json'
$SqlPasswordFile = Join-Path $SqlState 'password.dpapi'
$SqlOutputDir = Join-Path $TextfileDir 'sqlanywhere'
$SqlDriver = 'SQL Anywhere 17'
$SqlDefaultLinks = 'SharedMemory,TCPIP(HOST=127.0.0.1)'
# Mesma entropia do sqlanywhere-collector.ps1.
$SqlEntropy = [Text.Encoding]::UTF8.GetBytes('AssessoriaTech-Alloy-SQLAnywhere')

# Servico ou processo do servidor de rede (dbsrv17) ou pessoal (dbeng17).
function Test-SqlAnywhere {
    $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -match '(?i)\bdb(srv|eng)17\.exe\b'
    })
    if ($services.Count -gt 0) { return $true }
    return @(Get-Process -Name dbsrv17, dbeng17 -ErrorAction SilentlyContinue).Count -gt 0
}

# O coletor roda no PowerShell de 64 bits: precisa do driver de 64 bits.
function Test-SqlAnywhereDriver {
    if (-not (Get-Command Get-OdbcDriver -ErrorAction SilentlyContinue)) { return $false }
    return @(Get-OdbcDriver -Name $SqlDriver -Platform '64-bit' -ErrorAction SilentlyContinue).Count -gt 0
}

function Test-SqlAnywhereSettings {
    (Test-Path -LiteralPath $SqlConfigFile -PathType Leaf) -and (Test-Path -LiteralPath $SqlPasswordFile -PathType Leaf)
}

# Mesma conexao do coletor; devolve a versao do servidor.
function Test-SqlAnywhereConnection([hashtable]$Settings) {
    $builder = New-Object System.Data.Odbc.OdbcConnectionStringBuilder
    $builder['Driver'] = $SqlDriver
    $builder['ServerName'] = $Settings.server
    $builder['DatabaseName'] = $Settings.database
    $builder['UID'] = $Settings.user
    $builder['PWD'] = $Settings.password
    $builder['LINKS'] = $Settings.links
    $connection = New-Object System.Data.Odbc.OdbcConnection($builder.ConnectionString)
    try {
        $connection.ConnectionTimeout = 5
        $connection.Open()
        $cmd = $connection.CreateCommand()
        $cmd.CommandTimeout = 8
        $cmd.CommandText = "SELECT PROPERTY('ProductVersion')"
        return [string]$cmd.ExecuteScalar()
    } finally {
        $connection.Dispose()
    }
}

# Pede servidor, banco e usuario (padrao: valores gravados) e testa a conexao
# antes de aceitar. Nada e gravado aqui: Save-SqlAnywhereSettings grava
# depois da validacao do Alloy.
function Read-SqlAnywhereSettings {
    $current = $null
    if (Test-Path -LiteralPath $SqlConfigFile -PathType Leaf) {
        try { $current = [IO.File]::ReadAllText($SqlConfigFile) | ConvertFrom-Json } catch { }
    }
    Write-Host ''
    Write-Host '  Monitoramento do SQL Anywhere: informe um usuario SQL somente leitura.'
    Write-Host '  Ele so executa PROPERTY() e DB_PROPERTY(); nao precisa ler tabelas.'
    $settings = @{
        server   = Read-Value 'Nome do servidor SQL Anywhere (ENG)' ([string]$current.server)
        database = Read-Value 'Nome do banco (DBN)' ([string]$current.database)
        user     = Read-Value 'Usuario de monitoramento' ([string]$current.user)
        links    = if ($current -and $current.links) { [string]$current.links } else { $SqlDefaultLinks }
    }
    $secure = Read-Host 'Senha' -AsSecureString
    if ($secure.Length -eq 0) { throw 'Senha e obrigatoria.' }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $settings.password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    Write-Log 'Testando a conexao com o SQL Anywhere...'
    try {
        $version = Test-SqlAnywhereConnection $settings
    } catch {
        throw "Conexao ao SQL Anywhere falhou: $($_.Exception.Message)"
    }
    Write-Log "Conexao OK (SQL Anywhere $version)."
    return $settings
}

# Senha com DPAPI (escopo da maquina) alem da ACL de data\: uma copia do
# arquivo fora deste servidor nao revela a senha.
function Save-SqlAnywhereSettings([hashtable]$Settings) {
    Ensure-Directory $SqlState
    Add-Type -AssemblyName System.Security
    $blob = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($Settings.password), $SqlEntropy,
        [Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllBytes($SqlPasswordFile, $blob)
    $json = [ordered]@{ server = $Settings.server; database = $Settings.database; user = $Settings.user; links = $Settings.links } |
        ConvertTo-Json
    [IO.File]::WriteAllText($SqlConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Log "SQL Anywhere: configuracao gravada em $SqlState."
}

# Coletor: script em scripts\, tarefa a cada 30 s como SYSTEM (duas fases de
# 1 min defasadas em 30 s: o Agendador nao repete em menos de 1 min) e
# primeira execucao conferida. Desabilitado: remove tarefa, script, saida e
# logs; a configuracao fica para reativar (a limpeza completa a remove).
function Sync-SqlAnywhereCollector([bool]$Enabled, [string]$StagedScript) {
    $task = Get-ScheduledTask -TaskPath $SqlTaskPath -TaskName $SqlTaskName -ErrorAction SilentlyContinue
    if (-not $Enabled) {
        $hadFiles = (Test-Path -LiteralPath $SqlCollectorScript) -or (Test-Path -LiteralPath $SqlOutput)
        if ($task) { Unregister-ScheduledTask -TaskPath $SqlTaskPath -TaskName $SqlTaskName -Confirm:$false }
        foreach ($path in @($SqlCollectorScript, $SqlOutput, ($SqlOutput + '.tmp'), (Join-Path $SqlState 'missing-properties.txt'))) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $LogDir) {
            Get-ChildItem -LiteralPath $LogDir -Filter 'sqlanywhere-collector-*.log' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        if ($task -or $hadFiles) {
            Write-Log "Coletor SQL Anywhere removido (tarefa, script, saida e logs). Configuracao mantida em $SqlState."
        }
        return
    }

    if (-not (Same-File $StagedScript $SqlCollectorScript)) {
        Copy-Item -LiteralPath $StagedScript -Destination $SqlCollectorScript -Force
        Write-Log "Coletor SQL Anywhere: script instalado em $SqlCollectorScript."
    }

    $start = (Get-Date).Date
    $phaseA = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 1)
    $phaseB = New-ScheduledTaskTrigger -Once -At $start.AddSeconds(30) -RepetitionInterval (New-TimeSpan -Minutes 1)
    Register-CollectorTask $SqlTaskPath $SqlTaskName $SqlCollectorScript @($phaseA, $phaseB) (New-TimeSpan -Seconds 25) `
        'Metricas do SQL Anywhere para o Grafana Alloy (textfile\sqlanywhere\sqlanywhere.prom). Gerenciado pelo install.ps1.'

    $content = Invoke-FirstRun $SqlTaskPath $SqlTaskName $SqlOutput 40 'Coletor SQL Anywhere'
    $ok = @($content | Where-Object { $_ -match '^sqlanywhere_collection_success 1$' }).Count -gt 0
    if (-not $ok) { throw "Coletor SQL Anywhere falhou na primeira execucao. Veja os logs em $LogDir." }
    $missing = ($content | Where-Object { $_ -like 'sqlanywhere_collection_missing_properties *' } | Select-Object -First 1) -replace '^\S+\s+', ''
    $note = if ($missing -and $missing -ne '0') { " ($missing propriedade(s) sem valor; veja $LogDir)" } else { '' }
    Write-Log "Coletor SQL Anywhere ativo, atualizado a cada 30 s$note."
}
