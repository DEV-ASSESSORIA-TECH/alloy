# Carregado (". ") pelo ops\install.ps1: modulo MySQL (exportador embutido do Alloy).
# Manter em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.

# MySQL: exportador embutido do Alloy (sem tarefa agendada). Em data\mysql\:
# dsn (usuario:senha@tcp(host:porta)/, lido pelo Alloy como segredo) e
# config.json (host, porta, usuario, cliente mysql.exe e logs lidos).
$MysqlConfigFile = Join-Path $MysqlState 'config.json'
$MysqlDsnFile = Join-Path $MysqlState 'dsn'
$MysqlDefaultUser = 'alloy'
$MysqlDefaultPort = 3306

# Servico do MySQL/MariaDB (o caminho pode vir sem .exe, com ou sem aspas).
function Get-MysqlServices {
    @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.PathName -match '(?i)\\(mysqld(-nt)?|mariadbd)(\.exe)?("|\s|$)'
    })
}

function Test-Mysql {
    if (@(Get-MysqlServices).Count -gt 0) { return $true }
    return @(Get-Process -Name mysqld, mysqld-nt, mariadbd -ErrorAction SilentlyContinue).Count -gt 0
}

function Test-MysqlSettings {
    (Test-Path -LiteralPath $MysqlConfigFile -PathType Leaf) -and (Test-Path -LiteralPath $MysqlDsnFile -PathType Leaf)
}

# Executavel de um PathName de servico: "C:\...\mysqld" --defaults-file=... MySQL
function Get-ServiceExecutable([string]$PathName) {
    if ($PathName -match '^\s*"([^"]+)"') { return $Matches[1] }
    if ($PathName -match '^\s*(\S+)') { return $Matches[1] }
    return $null
}

# Cliente mysql.exe: ao lado do mysqld do servico ou do processo, no PATH ou
# nas pastas padrao do instalador. O primeiro e a sugestao.
function Find-MysqlClients {
    $dirs = @()
    foreach ($svc in Get-MysqlServices) {
        $exe = Get-ServiceExecutable ([string]$svc.PathName)
        if ($exe) { $dirs += (Split-Path -Parent $exe) }
    }
    foreach ($proc in @(Get-Process -Name mysqld, mysqld-nt, mariadbd -ErrorAction SilentlyContinue)) {
        try { if ($proc.Path) { $dirs += (Split-Path -Parent $proc.Path) } } catch { }
    }
    $found = @()
    foreach ($dir in $dirs) {
        foreach ($name in @('mysql.exe', 'mariadb.exe')) {
            $candidate = Join-Path $dir $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found += $candidate }
        }
    }
    $command = Get-Command mysql.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $found += $command.Source }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\mysql', 'C:\xampp')) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $found += @(Get-ChildItem -Path (Join-Path $root 'MySQL\*\bin\mysql.exe'), (Join-Path $root 'MariaDB*\bin\mysql.exe'),
            (Join-Path $root 'bin\mysql.exe'), (Join-Path $root 'mysql\bin\mysql.exe') -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
    }
    return @($found | Where-Object { $_ } | Select-Object -Unique)
}

# Consulta pelo mysql.exe com a mesma conexao do exportador (TCP, sem os
# arquivos de opcoes da maquina). Senha pelo ambiente (MYSQL_PWD), nunca na
# linha de comando. Devolve as colunas da primeira linha (--raw: caminhos do
# Windows sem escape).
function Invoke-MysqlQuery([hashtable]$Settings, [string]$Query) {
    $arguments = @('--no-defaults', '--protocol=TCP', "--host=$($Settings.host)", "--port=$($Settings.port)",
        "--user=$($Settings.user)", '--connect-timeout=5', '--batch', '--raw', '--skip-column-names', "--execute=$Query")
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Settings.client
    $info.Arguments = (@($arguments | ForEach-Object { ConvertTo-DbctArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['MYSQL_PWD'] = $Settings.password
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) {
            try { $process.Kill() } catch { }
            throw 'mysql.exe nao respondeu em 20 s.'
        }
        $process.WaitForExit()
        $errorText = ($stderr.GetAwaiter().GetResult()).Trim()
        if ($process.ExitCode -ne 0) {
            if (-not $errorText) { $errorText = "mysql.exe retornou $($process.ExitCode)." }
            throw $errorText
        }
        $line = @(($stdout.GetAwaiter().GetResult()) -split "`r?`n" | Where-Object { $_ }) | Select-Object -First 1
        if (-not $line) { throw 'mysql.exe nao devolveu resultado.' }
        return @($line -split "`t")
    } finally { $process.Dispose() }
}

# Caminho de log informado pelo servidor: relativo ao datadir quando nao for
# absoluto (o 5.5 no Windows usa ".\HOST.err"); barras normalizadas.
function Resolve-MysqlPath([string]$Path, [string]$DataDirPath) {
    if (-not $Path -or $Path -eq 'NULL' -or $Path -eq 'stderr') { return $null }
    $Path = $Path -replace '/', '\'
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = Join-Path ($DataDirPath -replace '/', '\') $Path }
    return [IO.Path]::GetFullPath($Path)
}

# Testa a conexao e le do proprio servidor a versao e os logs. Os logs vao
# para o Loki so se o arquivo existir (error log) ou se o slow log estiver
# ligado e em arquivo; o modulo nunca altera a configuracao do MySQL.
function Test-MysqlConnection([hashtable]$Settings) {
    $row = Invoke-MysqlQuery $Settings ('SELECT VERSION(), @@datadir, @@log_error, @@slow_query_log, ' +
        '@@slow_query_log_file, @@log_output, @@long_query_time')
    if ($row.Count -lt 7) { throw "Resposta inesperada do MySQL: $($row -join ' | ')" }
    $result = @{ version = $row[0]; logs = @(); notes = @() }
    $errorLog = Resolve-MysqlPath $row[2] $row[1]
    if (-not $errorLog) {
        $result.notes += 'Error log desligado no servidor (log_error vazio): nada a enviar ao Loki.'
    } elseif (Test-Path -LiteralPath $errorLog -PathType Leaf) {
        $result.logs += [ordered]@{ '__path__' = $errorLog; log_type = 'error' }
    } else {
        $result.notes += "Error log $errorLog nao encontrado: nao sera lido."
    }
    $slowOn = $row[3] -match '^(1|ON)$'
    $toFile = $row[5] -match '(?i)FILE'
    $slowLog = Resolve-MysqlPath $row[4] $row[1]
    if ($slowOn -and $toFile -and $slowLog) {
        $result.logs += [ordered]@{ '__path__' = $slowLog; log_type = 'slow' }
        $result.notes += "Slow query log ligado (long_query_time = $($row[6]) s)."
    } elseif (-not $slowOn) {
        $result.notes += 'Slow query log desligado: sem consultas lentas no Loki (veja docs/modulos.md, Modulo MySQL).'
    } else {
        $result.notes += "Slow query log gravado em tabela (log_output = $($row[5])): so arquivo e lido."
    }
    return $result
}

# Pede porta, usuario, senha e o mysql.exe (padrao: valores gravados) e testa
# a conexao antes de aceitar. Nada e gravado aqui: Save-MysqlSettings grava
# depois da validacao do Alloy.
function Read-MysqlSettings {
    $current = $null
    if (Test-Path -LiteralPath $MysqlConfigFile -PathType Leaf) {
        try { $current = [IO.File]::ReadAllText($MysqlConfigFile) | ConvertFrom-Json } catch { }
    }
    $clients = @(Find-MysqlClients)
    $client = if ($current -and $current.client -and (Test-Path -LiteralPath ([string]$current.client) -PathType Leaf)) {
        [string]$current.client
    } elseif ($clients.Count -gt 0) { $clients[0] } else { '' }
    Write-Host ''
    Write-Host '  Monitoramento do MySQL: informe o usuario de monitoramento (padrao alloy).'
    Write-Host '  Ele so precisa do privilegio PROCESS; docs/modulos.md mostra como criar.'
    $settings = @{
        host = if ($current -and $current.host) { [string]$current.host } else { '127.0.0.1' }
        port = 0
        user = Read-Value 'Usuario de monitoramento' $(if ($current -and $current.user) { [string]$current.user } else { $MysqlDefaultUser })
    }
    $portText = Read-Value 'Porta do MySQL' $(if ($current -and $current.port) { [string]$current.port } else { [string]$MysqlDefaultPort })
    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw "Porta invalida: $portText" }
    $settings.port = $port
    if ($settings.user -notmatch '^[A-Za-z0-9_.$-]{1,32}$') { throw "Usuario invalido: $($settings.user)" }
    $settings.client = Read-Value 'Cliente mysql.exe (para testar a conexao)' $client
    if (-not (Test-Path -LiteralPath $settings.client -PathType Leaf)) { throw "mysql.exe nao encontrado: $($settings.client)" }
    $secure = Read-Host 'Senha' -AsSecureString
    if ($secure.Length -eq 0) { throw 'Senha e obrigatoria.' }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $settings.password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    if ($settings.password -match '[\r\n]') { throw 'Senha com quebra de linha nao e suportada.' }
    Write-Log 'Testando a conexao com o MySQL...'
    try {
        $probe = Test-MysqlConnection $settings
    } catch {
        throw "Conexao ao MySQL falhou: $($_.Exception.Message)"
    }
    Write-Log "Conexao OK (MySQL $($probe.version))."
    foreach ($entry in $probe.logs) { Write-Log "Log enviado ao Loki ($($entry.log_type)): $($entry['__path__'])" }
    foreach ($note in $probe.notes) { Write-Log $note }
    $settings.logs = $probe.logs
    return $settings
}

# Sem DPAPI: quem le a senha e o proprio Alloy (local.file com is_secret). O
# arquivo fica so com a ACL de data\ (SYSTEM e Administradores) e nunca aparece
# na configuracao, na interface do Alloy ou nos logs.
function Save-MysqlSettings([hashtable]$Settings) {
    Ensure-Directory $MysqlState
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $dsn = '{0}:{1}@tcp({2}:{3})/' -f $Settings.user, $Settings.password, $Settings.host, $Settings.port
    [IO.File]::WriteAllText($MysqlDsnFile, $dsn, $utf8)
    $json = [ordered]@{
        host   = $Settings.host
        port   = $Settings.port
        user   = $Settings.user
        client = $Settings.client
        logs   = @($Settings.logs)
    } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($MysqlConfigFile, $json, $utf8)
    Write-Log "MySQL: configuracao gravada em $MysqlState."
}

# Sem tarefa: so confere, pelo proprio Alloy, que o exportador conectou
# (mysql_up 1). O Alloy rele dsn e config.json sozinho, entao uma
# reconfiguracao sem outras mudancas tambem passa por aqui.
function Sync-MysqlModule([bool]$Enabled) {
    if (-not $Enabled) { return }
    $deadline = (Get-Date).AddSeconds(75)
    $up = $null
    do {
        try {
            $text = (Get-LocalHttp).GetStringAsync($MysqlMetricsUrl).GetAwaiter().GetResult()
            if ($text -match '(?m)^mysql_up (\d)') { $up = $Matches[1] }
            if ($up -eq '1') { break }
        } catch { }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    if ($up -ne '1') {
        throw "MySQL: o Alloy nao conectou ao banco (mysql_up = $(if ($up) { $up } else { 'sem valor' })). Confira o usuario e use Reconfigurar MySQL."
    }
    Write-Log 'MySQL: exportador conectado (mysql_up 1); metricas a cada 30 s.'
}
