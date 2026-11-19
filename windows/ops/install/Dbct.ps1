# Carregado (". ") pelo ops\install.ps1: modulo DB Connection Tester (coletor agendado).
# Manter em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.

# DB Connection Tester: so o coletor (a cada 30 s). A execucao continua e do
# proprio DBCT (dbct run ... --autostart); o modulo apenas le o banco.
$DbctCollectorName = 'dbct-collector.ps1'
$DbctCollectorScript = Join-Path $ScriptsDir $DbctCollectorName
$DbctConfigFile = Join-Path $DbctState 'config.json'
$DbctOutputDir = Join-Path $TextfileDir 'dbct'

# Regras do Windows para argumentos (mesmas do dbct-collector.ps1).
function ConvertTo-DbctArgument([string]$Value) {
    if ($Value -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

# Executa o dbct e devolve codigo, stdout e stderr. StdIn opcional (senha).
function Invoke-DbctCommand([string]$Dbct, [string[]]$Arguments, [string]$StdIn = $null, [int]$TimeoutSeconds = 60) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Dbct
    $info.Arguments = (@($Arguments | ForEach-Object { ConvertTo-DbctArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($null -ne $StdIn) { $process.StandardInput.WriteLine($StdIn) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "dbct $($Arguments[0]) excedeu ${TimeoutSeconds}s."
        }
        $process.WaitForExit()
        return @{ ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult(); Error = ($stderr.GetAwaiter().GetResult()).Trim() }
    } finally { $process.Dispose() }
}

function Invoke-DbctJson([string]$Dbct, [string[]]$Arguments) {
    $result = Invoke-DbctCommand $Dbct $Arguments
    if ($result.ExitCode -ne 0) { throw "dbct $($Arguments[0]) $($Arguments[1]) retornou $($result.ExitCode): $($result.Error)" }
    return ($result.Output | ConvertFrom-Json).data
}

# dbct.exe instalado (MSI por maquina ou por usuario), no PATH ou portatil.
function Find-DbctExecutables {
    $found = @()
    $command = Get-Command dbct.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $found += $command.Source }
    $found += Join-Path $env:ProgramFiles 'DBConnectionTester\dbct.exe'
    $users = Join-Path $env:SystemDrive 'Users'
    $found += @(Get-ChildItem -Path (Join-Path $users '*\AppData\Local\Programs\DBConnectionTester\dbct.exe') -File -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
    return @($found | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -Unique)
}

# Pastas com data.db, na ordem em que sao sugeridas: as das execucoes
# automaticas do DBCT (tarefas "\DB Connection Tester\...", o caso tipico de
# monitoramento), as de ProgramData\DBConnectionTester\Monitor\<nome>, a
# compartilhada, as locais de cada usuario e a portatil (Data ao lado do dbct.exe).
function Find-DbctDataDirs([string]$Dbct) {
    $found = @()
    foreach ($task in @(Get-ScheduledTask -TaskPath '\DB Connection Tester\' -ErrorAction SilentlyContinue)) {
        foreach ($action in @($task.Actions)) {
            if ([string]$action.Arguments -match '--data-dir\s+(?:"([^"]+)"|(\S+))') {
                $found += $(if ($Matches[1]) { $Matches[1] } else { $Matches[2] }).TrimEnd('\')
            }
        }
    }
    $monitor = Join-Path $env:ProgramData 'DBConnectionTester\Monitor'
    $found += @(Get-ChildItem -LiteralPath $monitor -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $found += Join-Path $env:ProgramData 'DBConnectionTester'
    $users = Join-Path $env:SystemDrive 'Users'
    $found += @(Get-ChildItem -Path (Join-Path $users '*\AppData\Local\DBConnectionTester') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $_.FullName })
    if ($Dbct) { $found += Join-Path (Split-Path -Parent $Dbct) 'Data' }
    return @($found | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'data.db') -PathType Leaf } | Select-Object -Unique)
}

function Test-DbctSettings { Test-Path -LiteralPath $DbctConfigFile -PathType Leaf }

function Select-DbctValue([string]$Title, [string[]]$Options, [string]$Current) {
    $default = if ($Current) { $Current } elseif ($Options.Count -gt 0) { $Options[0] } else { '' }
    if ($Options.Count -gt 0) {
        Write-Host "  $Title encontrados:"
        foreach ($option in $Options) { Write-Host "    $option" }
    }
    return (Read-Value $Title $default).Trim().Trim('"').TrimEnd('\')
}

# Pede o dbct.exe e a pasta do banco e valida os dois com a propria CLI. A
# execucao continua nao e configurada aqui: e do DBCT (dbct run ... --autostart).
# Nada e gravado aqui: Save-DbctSettings grava depois da validacao do Alloy.
function Read-DbctSettings {
    $current = $null
    if (Test-Path -LiteralPath $DbctConfigFile -PathType Leaf) {
        try { $current = [IO.File]::ReadAllText($DbctConfigFile) | ConvertFrom-Json } catch { }
    }
    Write-Host ''
    Write-Host '  Monitoramento do DB Connection Tester: o coletor le, a cada 30 s, a execucao'
    Write-Host '  ativa no banco do DBCT (data.db) e publica falhas e lentidoes no Prometheus.'
    $dbct = Select-DbctValue 'dbct.exe' (Find-DbctExecutables) ([string]$current.dbct)
    if (-not (Test-Path -LiteralPath $dbct -PathType Leaf)) { throw "dbct.exe nao encontrado: $dbct" }
    foreach ($required in @(@('history', 'cycles', '--help'), @('run', 'status', '--help'))) {
        if ((Invoke-DbctCommand $dbct $required).ExitCode -ne 0) {
            throw "Este dbct.exe nao oferece ""$($required[0]) $($required[1])"": atualize o DB Connection Tester."
        }
    }
    $dataDir = Select-DbctValue 'Pasta do banco do DBCT (com data.db)' (Find-DbctDataDirs $dbct) ([string]$current.dataDir)
    if (-not (Test-Path -LiteralPath (Join-Path $dataDir 'data.db') -PathType Leaf)) { throw "data.db nao encontrado em $dataDir" }
    $common = @('--data-dir', $dataDir, '--format', 'json')
    $status = Invoke-DbctJson $dbct (@('run', 'status') + $common)
    Write-Log "Banco do DBCT OK: $dataDir"
    $autostart = Invoke-DbctJson $dbct (@('autostart', 'show') + $common)
    if ($autostart.enabled) {
        Write-Log "Execucao automatica do DBCT configurada neste banco ($($autostart.scope))."
    } elseif (-not $status.active) {
        Write-Warning ('Nenhuma execucao ativa e nenhuma execucao automatica neste banco. O coletor so publica enquanto houver ' +
            'execucao. Para manter uma, iniciada com o Windows: dbct run <parametros> --data-dir "' + $dataDir + '" --autostart')
    }
    return @{ dbct = $dbct; dataDir = $dataDir }
}

function Save-DbctSettings([hashtable]$Settings) {
    Ensure-Directory $DbctState
    $json = [ordered]@{ dbct = $Settings.dbct; dataDir = $Settings.dataDir } | ConvertTo-Json
    [IO.File]::WriteAllText($DbctConfigFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    # Posicao da coleta anterior nao vale para outro banco.
    Remove-Item -LiteralPath (Join-Path $DbctState 'state.json') -Force -ErrorAction SilentlyContinue
    Write-Log "DBCT: configuracao gravada em $DbctState."
}

# Coletor a cada 30 s, como o do SQL Anywhere. Desabilitado: remove tarefa,
# script, saida, estado e logs; a configuracao fica para reativar (a limpeza
# completa a remove). Nada no DBCT e alterado.
function Sync-DbctModule([bool]$Enabled, [string]$StagedCollector) {
    $collectorTask = Get-ScheduledTask -TaskPath $DbctTaskPath -TaskName $DbctCollectorTask -ErrorAction SilentlyContinue
    if (-not $Enabled) {
        $hadFiles = (Test-Path -LiteralPath $DbctCollectorScript) -or (Test-Path -LiteralPath $DbctOutput)
        if ($collectorTask) { Unregister-ScheduledTask -TaskPath $DbctTaskPath -TaskName $DbctCollectorTask -Confirm:$false }
        foreach ($path in @($DbctCollectorScript, $DbctOutput, ($DbctOutput + '.tmp'), (Join-Path $DbctState 'state.json'))) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $LogDir) {
            Get-ChildItem -LiteralPath $LogDir -Filter 'dbct-collector-*.log' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        if ($collectorTask -or $hadFiles) {
            Write-Log "Coletor DBCT removido (tarefa, script, saida e logs). Configuracao mantida em $DbctState."
        }
        return
    }

    if (-not (Same-File $StagedCollector $DbctCollectorScript)) {
        Copy-Item -LiteralPath $StagedCollector -Destination $DbctCollectorScript -Force
        Write-Log "DBCT: coletor instalado em $DbctCollectorScript."
    }
    $start = (Get-Date).Date
    $phaseA = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 1)
    $phaseB = New-ScheduledTaskTrigger -Once -At $start.AddSeconds(30) -RepetitionInterval (New-TimeSpan -Minutes 1)
    Register-CollectorTask $DbctTaskPath $DbctCollectorTask $DbctCollectorScript @($phaseA, $phaseB) (New-TimeSpan -Seconds 25) `
        'Metricas do DB Connection Tester para o Grafana Alloy (textfile\dbct\dbct.prom). Gerenciado pelo install.ps1.'
    $content = Invoke-FirstRun $DbctTaskPath $DbctCollectorTask $DbctOutput 40 'Coletor DBCT'
    $ok = @($content | Where-Object { $_ -match '^dbct_collection_success 1$' }).Count -gt 0
    if (-not $ok) { throw "Coletor DBCT falhou na primeira execucao. Veja os logs em $LogDir." }
    $active = @($content | Where-Object { $_ -match '^dbct_run_active 1$' }).Count -gt 0
    $note = if ($active) { 'execucao ativa encontrada' } else { 'nenhuma execucao ativa no momento' }
    Write-Log "Coletor DBCT ativo, atualizado a cada 30 s ($note)."
}
