#Requires -RunAsAdministrator
#Requires -Version 5.1
# Instala ou reaplica o Alloy com validacao e rollback.
# -Modules: conjunto completo dos modulos opcionais.
#   auto (padrao)               mantem os ativos e oferece os detectados
#   hyperv, sqlanywhere, mysql, dbct
#                               ativa exatamente os listados (os demais saem)
#   none                        desativa todos
#   dbct (DB Connection Tester) tambem vale no perfil estacao e nunca e
#   oferecido automaticamente. mysql tambem vale no perfil estacao (sem
#   deteccao automatica nele).
# -ReconfigureSqlAnywhere: pede de novo servidor, banco e usuario do SQL Anywhere.
# -ReconfigureMysql: pede de novo porta, usuario e senha do MySQL e rele os logs.
# -ReconfigureDbct: pede de novo o dbct.exe e a pasta do banco do DBCT.
# -Perfil: servidor (config.alloy, job integrations/windows, com alertas) ou
#   estacao (desktop.alloy, job integrations/windows-desktop: maquina
#   descartavel, sem alertas e sem modulos opcionais). auto (padrao) mantem o
#   instalado; na primeira instalacao, estacao se o Windows for de cliente.
# Leitura dos backups (backup.alloy): sempre instalada no perfil servidor, sem
#   modulo opcional. Cria textfile\backup e o grupo local "Alloy Backup
#   Writers" (escrita); os .prom sao gravados por produtores externos.
[CmdletBinding()]
param(
    [switch]$Upgrade,
    [ValidateSet('auto','hyperv','sqlanywhere','mysql','dbct','none')]
    [string[]]$Modules = @('auto'),
    [switch]$ReconfigureSqlAnywhere,
    [switch]$ReconfigureMysql,
    [switch]$ReconfigureDbct,
    [ValidateSet('auto','servidor','estacao')]
    [string]$Perfil = 'auto'
)

$ErrorActionPreference = 'Stop'

# Constantes comuns (lib\Common.ps1) e partes da instalacao (ops\install\).
# A raiz e a pasta do alloyctl ou o clone: modules\ e collectors\ ficam nela.
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'lib\Common.ps1')
foreach ($part in @('Shared', 'Package', 'Backup', 'HyperV', 'SqlAnywhere', 'Mysql', 'Dbct')) {
    . (Join-Path $PSScriptRoot "install\$part.ps1")
}

# Sincroniza as tarefas dos modulos. Uma falha nao impede o outro modulo;
# as mensagens sao reunidas ao final.
function Sync-ModuleTasks {
    $failures = @()
    try { Sync-HypervisorInventory $hypervEnabled $stageInventory } catch { $failures += $_.Exception.Message }
    try { Sync-SqlAnywhereCollector $sqlEnabled $stageSqlCollector } catch { $failures += $_.Exception.Message }
    try { Sync-DbctModule $dbctEnabled $stageDbctCollector } catch { $failures += $_.Exception.Message }
    try { Sync-MysqlModule $mysqlEnabled } catch { $failures += $_.Exception.Message }
    if ($failures.Count -gt 0) { throw ($failures -join ' ') }
}

$HyperVModule = Join-Path $ConfigDir 'hyperv.alloy'
$SqlAnywhereModule = Join-Path $ConfigDir 'sqlanywhere.alloy'
$DbctModule = Join-Path $ConfigDir 'dbct.alloy'
$MysqlModule = Join-Path $ConfigDir 'mysql.alloy'
$BackupModule = Join-Path $ConfigDir 'backup.alloy'
$Modules = @($Modules | Select-Object -Unique)
if ($Modules.Count -gt 1 -and (($Modules -contains 'auto') -or ($Modules -contains 'none'))) {
    throw '-Modules: auto e none nao podem ser combinados com outros valores.'
}
$autoModules = $Modules -contains 'auto'

# Perfil: define o arquivo base; o do outro perfil e removido ao aplicar.
$PerfilFiles = @{ servidor = 'config.alloy'; estacao = 'desktop.alloy' }
if ($Perfil -eq 'auto') {
    if (Test-Path -LiteralPath (Join-Path $ConfigDir 'desktop.alloy') -PathType Leaf) { $Perfil = 'estacao' }
    elseif (Test-Path -LiteralPath (Join-Path $ConfigDir 'config.alloy') -PathType Leaf) { $Perfil = 'servidor' }
    else {
        # ProductType 1 = Windows de cliente (10/11); 2 e 3 = Windows Server.
        $Perfil = 'servidor'
        try { if ((Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).ProductType -eq 1) { $Perfil = 'estacao' } } catch { }
        Write-Log "Perfil detectado: $Perfil (use -Perfil servidor|estacao para escolher)."
    }
}
$BaseName = $PerfilFiles[$Perfil]
$OtherName = if ($Perfil -eq 'estacao') { $PerfilFiles.servidor } else { $PerfilFiles.estacao }
if ($Perfil -eq 'estacao') {
    $optional = @($Modules | Where-Object { $_ -in @('hyperv', 'sqlanywhere') })
    if ($optional.Count -gt 0) { throw "Modulos opcionais ($($optional -join ', ')) nao se aplicam ao perfil estacao." }
    if (Test-Path -LiteralPath (Join-Path $Base 'heartbeat\kuma-url')) {
        Write-Warning 'Heartbeat configurado: estacoes nao usam heartbeat. Remova com "alloyctl heartbeat-remove" e exclua o monitor no Kuma.'
    }
    # Sem deteccao nem pergunta: Hyper-V e SQL Anywhere ativos sao desativados
    # abaixo. Os modulos dbct e mysql valem para estacoes e seguem -Modules
    # normalmente (auto so mantem os ativos).
    $autoModules = $false
}

$hypervEnabled = $false
if ($autoModules) {
    if (Test-Path -LiteralPath $HyperVModule -PathType Leaf) {
        if (-not (Test-HyperV)) {
            throw 'Hyper-V estava habilitado mas nao esta disponivel. Para desativar, informe -Modules sem hyperv (ex.: -Modules none).'
        }
        $hypervEnabled = $true
        Write-Log 'Modulo Hyper-V existente: preservando.'
    } elseif (Test-HyperV) {
        if ([Console]::IsInputRedirected) {
            Write-Log 'Hyper-V detectado sem terminal interativo. Use -Modules hyperv para habilitar.'
        } else {
            $answer = Read-Host 'Hyper-V detectado. Habilitar metricas, inventario de VMs e logs administrativos? [S/n]'
            if ($answer -match '^(|s|sim|y|yes)$') { $hypervEnabled = $true }
        }
    }
} elseif ($Modules -contains 'hyperv') {
    if (-not (Test-HyperV)) { throw 'Hyper-V solicitado, mas vmms/Get-VM nao estao disponiveis.' }
    $hypervEnabled = $true
} elseif (Test-Path -LiteralPath $HyperVModule -PathType Leaf) {
    Write-Log 'Modulo Hyper-V sera desativado.'
}

$sqlEnabled = $false
$sqlPending = $null
if ($autoModules) {
    if (Test-Path -LiteralPath $SqlAnywhereModule -PathType Leaf) {
        if (-not (Test-SqlAnywhere)) {
            throw 'SQL Anywhere estava habilitado mas nao foi detectado. Para desativar, informe -Modules sem sqlanywhere (ex.: -Modules none).'
        }
        $sqlEnabled = $true
        Write-Log 'Modulo SQL Anywhere existente: preservando.'
    } elseif (Test-SqlAnywhere) {
        if ([Console]::IsInputRedirected) {
            Write-Log 'SQL Anywhere 17 detectado sem terminal interativo. Use -Modules sqlanywhere para habilitar.'
        } else {
            $answer = Read-Host 'SQL Anywhere 17 detectado. Habilitar metricas do servidor e do banco? [S/n]'
            if ($answer -match '^(|s|sim|y|yes)$') { $sqlEnabled = $true }
        }
    }
} elseif ($Modules -contains 'sqlanywhere') {
    if (-not (Test-SqlAnywhere)) { throw 'SQL Anywhere solicitado, mas dbsrv17/dbeng17 nao foram encontrados.' }
    $sqlEnabled = $true
} elseif (Test-Path -LiteralPath $SqlAnywhereModule -PathType Leaf) {
    Write-Log 'Modulo SQL Anywhere sera desativado.'
}
if ($sqlEnabled) {
    if (-not (Test-SqlAnywhereDriver)) {
        throw "Driver ODBC '$SqlDriver' de 64 bits nao encontrado. Instale o cliente SQL Anywhere 17 (64 bits)."
    }
    if ($ReconfigureSqlAnywhere -or -not (Test-SqlAnywhereSettings)) {
        if ([Console]::IsInputRedirected) {
            throw 'SQL Anywhere sem configuracao: execute a instalacao em um terminal interativo.'
        }
        $sqlPending = Read-SqlAnywhereSettings
    }
} elseif ($ReconfigureSqlAnywhere) {
    throw '-ReconfigureSqlAnywhere requer o modulo SQL Anywhere ativo.'
}

# MySQL: como o SQL Anywhere no perfil servidor (oferecido quando detectado);
# na estacao, auto so mantem o modulo ativo.
$mysqlEnabled = $false
$mysqlPending = $null
if ($Modules -contains 'mysql') {
    if (-not (Test-Mysql)) { throw 'MySQL solicitado, mas nenhum servico ou processo mysqld/mariadbd foi encontrado.' }
    $mysqlEnabled = $true
} elseif ($Modules -contains 'auto') {
    if (Test-Path -LiteralPath $MysqlModule -PathType Leaf) {
        if (-not (Test-Mysql)) {
            throw 'MySQL estava habilitado mas nao foi detectado. Para desativar, informe -Modules sem mysql (ex.: -Modules none).'
        }
        $mysqlEnabled = $true
        Write-Log 'Modulo MySQL existente: preservando.'
    } elseif ($Perfil -eq 'servidor' -and (Test-Mysql)) {
        if ([Console]::IsInputRedirected) {
            Write-Log 'MySQL detectado sem terminal interativo. Use -Modules mysql para habilitar.'
        } else {
            $answer = Read-Host 'MySQL detectado. Habilitar metricas, error log e slow query log? [S/n]'
            if ($answer -match '^(|s|sim|y|yes)$') { $mysqlEnabled = $true }
        }
    }
} elseif (Test-Path -LiteralPath $MysqlModule -PathType Leaf) {
    Write-Log 'Modulo MySQL sera desativado.'
}
if ($mysqlEnabled) {
    if ($ReconfigureMysql -or -not (Test-MysqlSettings)) {
        if ([Console]::IsInputRedirected) {
            throw 'MySQL sem configuracao: execute a instalacao em um terminal interativo.'
        }
        $mysqlPending = Read-MysqlSettings
    }
} elseif ($ReconfigureMysql) {
    throw '-ReconfigureMysql requer o modulo MySQL ativo.'
}

# DBCT: nunca oferecido automaticamente (necessidade pontual); auto mantem o
# modulo ativo, em qualquer perfil.
$dbctEnabled = $false
$dbctPending = $null
if ($Modules -contains 'dbct') {
    $dbctEnabled = $true
} elseif (($Modules -contains 'auto') -and (Test-Path -LiteralPath $DbctModule -PathType Leaf)) {
    $dbctEnabled = $true
    Write-Log 'Modulo DBCT existente: preservando.'
} elseif (Test-Path -LiteralPath $DbctModule -PathType Leaf) {
    Write-Log 'Modulo DBCT sera desativado.'
}
if ($dbctEnabled) {
    if ($ReconfigureDbct -or -not (Test-DbctSettings)) {
        if ([Console]::IsInputRedirected) {
            throw 'DBCT sem configuracao: execute a instalacao em um terminal interativo.'
        }
        $dbctPending = Read-DbctSettings
    }
} elseif ($ReconfigureDbct) {
    throw '-ReconfigureDbct requer o modulo DBCT ativo.'
}

# Leitura dos backups: parte do perfil servidor, sem pergunta nem -Modules.
# Pasta vazia nao publica nada; estacoes nao reportam backups.
$backupEnabled = $Perfil -eq 'servidor'

$Source = Join-Path $RepoRoot "modules\$BaseName"
if (-not (Test-Path -LiteralPath $Secret -PathType Leaf) -or (Get-Item -LiteralPath $Secret).Length -eq 0) {
    throw 'Credencial ausente. Execute alloy.ps1 (ou setup-credentials.ps1) primeiro.'
}
if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
    throw "$BaseName nao encontrado em modules\."
}
$stage = Join-Path $env:TEMP ('alloy-stage-' + [guid]::NewGuid().ToString('N'))
Ensure-Directory $stage
$applied = $false
$backup = $null
$priorArgsExist = $false
$priorArgs = @()
$priorRunning = $false
# O servico ja usava a nossa configuracao antes desta execucao? Se nao (primeira
# instalacao, ou o Alloy rodando com o exemplo do instalador oficial), uma falha
# deixa o servico parado, em vez de "ativo e pronto" sem coletar nada.
$priorOurs = $false
try { $priorOurs = @([string[]](Get-ItemProperty -LiteralPath $Registry -ErrorAction Stop).Arguments) -contains $ConfigDir } catch { }
$configConfirmed = $false
$startedAt = Get-Date
$priorAuto = $false
$target = Join-Path $ConfigDir $BaseName
# Arquivo base do outro perfil: removido ao aplicar (os dois nao convivem).
$otherTarget = Join-Path $ConfigDir $OtherName
try {
    Copy-Item -LiteralPath $Source -Destination (Join-Path $stage $BaseName)
    $stageInventory = $null
    if ($hypervEnabled) {
        Copy-ModuleFile 'hyperv.alloy' (Join-Path $stage 'hyperv.alloy')
        # O alloy validate do diretorio de stage so le *.alloy.
        $stageInventory = Join-Path $stage $InventoryName
        Copy-ModuleFile $InventoryName $stageInventory
        Assert-ScriptSyntax $stageInventory
    }
    $stageSqlCollector = $null
    if ($sqlEnabled) {
        Copy-ModuleFile 'sqlanywhere.alloy' (Join-Path $stage 'sqlanywhere.alloy')
        $stageSqlCollector = Join-Path $stage $SqlCollectorName
        Copy-ModuleFile $SqlCollectorName $stageSqlCollector
        Assert-ScriptSyntax $stageSqlCollector
    }
    if ($mysqlEnabled) {
        Copy-ModuleFile 'mysql.alloy' (Join-Path $stage 'mysql.alloy')
    }
    $stageDbctCollector = $null
    if ($dbctEnabled) {
        Copy-ModuleFile 'dbct.alloy' (Join-Path $stage 'dbct.alloy')
        $stageDbctCollector = Join-Path $stage $DbctCollectorName
        Copy-ModuleFile $DbctCollectorName $stageDbctCollector
        Assert-ScriptSyntax $stageDbctCollector
    }
    if ($backupEnabled) {
        Copy-ModuleFile 'backup.alloy' (Join-Path $stage 'backup.alloy')
    }
    if (Test-Path -LiteralPath $ConfigDir -PathType Container) {
        Get-ChildItem -LiteralPath $ConfigDir -Filter '*.alloy' -File | ForEach-Object {
            if ($_.Name -notin @('config.alloy', 'desktop.alloy', 'hyperv.alloy', 'sqlanywhere.alloy', 'mysql.alloy', 'dbct.alloy', 'backup.alloy')) {
                Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $stage $_.Name)
            }
        }
    }

    # Instalacao completa = executavel + servico + chave do registro (onde o
    # servico le os argumentos). Uma parte faltando (antivirus que removeu o
    # executavel ou desfez o registro, desinstalacao interrompida) e reinstalada.
    $hasExe = Test-Path -LiteralPath $Exe -PathType Leaf
    $hasService = $null -ne (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)
    $hasRegistry = Test-Path -LiteralPath $Registry
    $existing = $hasExe -and $hasService -and $hasRegistry
    if (-not $existing -and ($hasExe -or $hasService -or $hasRegistry)) {
        $absent = @()
        if (-not $hasExe) { $absent += "executavel ($Exe)" }
        if (-not $hasService) { $absent += 'servico' }
        if (-not $hasRegistry) { $absent += "registro ($Registry)" }
        Write-Warning ("Instalacao do Alloy incompleta (ausente: $($absent -join ', ')); reinstalando com o instalador oficial." +
            $(if (-not $hasExe -or -not $hasRegistry) { Get-AntivirusHint } else { '' }))
    }
    # Versao do Alloy: a fixada nesta versao do alloyctl (alloy.Dockerfile).
    # Sem -Upgrade, um Alloy ja instalado nunca muda de versao.
    $installedVersion = if ($existing) { Get-InstalledAlloyVersion } else { '' }
    if (-not $existing) {
        Install-AlloyPackage
    } elseif ($Upgrade) {
        $pinnedVersion = Get-AlloyPinnedVersion
        $installedParsed = $null
        if ($installedVersion -eq $pinnedVersion) {
            Write-Log "Alloy ja esta na versao fixada ($pinnedVersion)."
        } elseif ([version]::TryParse(($installedVersion -replace '[-+].*$', ''), [ref]$installedParsed) -and
                  $installedParsed -gt [version]$pinnedVersion) {
            # Atualizar nunca rebaixa: versao mais nova instalada a mao fica.
            Write-Warning "Alloy $installedVersion e mais novo que a versao fixada ($pinnedVersion); mantido."
        } else {
            Write-Log "Alloy $(if ($installedVersion) { $installedVersion } else { '?' }) -> $pinnedVersion (versao fixada nesta versao do alloyctl)."
            Install-AlloyPackage
        }
    } else {
        Write-Log "Alloy instalado ($(if ($installedVersion) { $installedVersion } else { 'versao desconhecida' })): download e upgrade ignorados."
    }

    Write-Log 'Validando a configuracao completa antes de alterar o servico...'
    & $Exe validate $stage
    if ($LASTEXITCODE -ne 0) {
        $hint = if ($hypervEnabled -or $sqlEnabled -or $mysqlEnabled -or $dbctEnabled -or $backupEnabled) { ' A leitura de backups e os modulos Hyper-V, SQL Anywhere, MySQL e DBCT requerem Alloy v1.11+ (use Atualizar Alloy).' } else { '' }
        throw "Configuracao invalida. Instalacao ativa preservada.$hint"
    }

    Ensure-Directory $Base
    Ensure-Directory $ConfigDir
    Ensure-Directory $DataDir
    Ensure-Directory $BookmarkDir
    Ensure-Directory $BackupDir
    Set-PrivateDirectoryAcl $ConfigDir
    Set-PrivateDirectoryAcl $DataDir
    Set-PrivateDirectoryAcl $BackupDir
    if ($hypervEnabled -or $sqlEnabled -or $dbctEnabled) {
        # scripts\ guarda codigo executado como SYSTEM: so SYSTEM e Administradores.
        foreach ($dir in @($ScriptsDir, $LogDir)) {
            Ensure-Directory $dir
            Set-PrivateDirectoryAcl $dir
        }
    }
    if ($hypervEnabled -or $sqlEnabled -or $dbctEnabled -or $backupEnabled) {
        # Os subdiretorios de textfile\ herdam a ACL, exceto textfile\backup
        # (ACL propria, com o grupo dos produtores).
        Ensure-Directory $TextfileDir
        Set-PrivateDirectoryAcl $TextfileDir
    }
    if ($backupEnabled) { Sync-BackupTextfile }
    if ($hypervEnabled) {
        Ensure-Directory $InventoryOutputDir
        Ensure-Directory $InventoryState
    }
    if ($sqlEnabled) {
        Ensure-Directory $SqlOutputDir
        Ensure-Directory $SqlState
        if ($sqlPending) { Save-SqlAnywhereSettings $sqlPending }
    }
    if ($mysqlEnabled) {
        Ensure-Directory $MysqlState
        if ($mysqlPending) { Save-MysqlSettings $mysqlPending }
    }
    if ($dbctEnabled) {
        Ensure-Directory $DbctOutputDir
        Ensure-Directory $DbctState
        if ($dbctPending) { Save-DbctSettings $dbctPending }
    }
    # Saida do inventario na raiz do textfile\ (versoes anteriores): nenhum
    # modulo le mais esse caminho.
    foreach ($legacy in @($LegacyInventoryOutput, ($LegacyInventoryOutput + '.tmp'))) {
        Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $Registry)) { throw 'Registro do servico Alloy ausente.' }
    $reg = Get-ItemProperty -LiteralPath $Registry
    if ($reg.ALLOY_OTEL_MODE -match '^(1|true)$') { throw 'OTel Engine ativo: modo nao suportado por este instalador.' }
    $priorArgsExist = $null -ne $reg.PSObject.Properties['Arguments']
    if ($priorArgsExist) { $priorArgs = [string[]]$reg.Arguments }
    $extras = @()
    foreach ($arg in @($priorArgs)) {
        if (-not $arg -or $arg -eq 'run' -or $arg -like '--storage.path=*' -or
            $arg -like '--server.http.listen-addr=*' -or $arg -like '*.alloy' -or $arg -eq $ConfigDir) {
            continue
        }
        if ($arg.StartsWith('-')) { $extras += $arg }
    }
    $argsNew = @('run', $ConfigDir, ('--storage.path=' + $DataDir), '--server.http.listen-addr=127.0.0.1:12345') + $extras
    $svc = Get-Service -Name $ServiceName
    $priorRunning = $svc.Status -eq 'Running'
    $priorAuto = $svc.StartType -eq 'Automatic'
    $configChanged = (-not (Same-File $Source $target)) -or (Test-Path -LiteralPath $otherTarget)
    $moduleSource = Join-Path $stage 'hyperv.alloy'
    $moduleChanged = if ($hypervEnabled) {
        -not (Same-File $moduleSource $HyperVModule)
    } else {
        Test-Path -LiteralPath $HyperVModule
    }
    $sqlSource = Join-Path $stage 'sqlanywhere.alloy'
    $sqlChanged = if ($sqlEnabled) {
        -not (Same-File $sqlSource $SqlAnywhereModule)
    } else {
        Test-Path -LiteralPath $SqlAnywhereModule
    }
    $mysqlSource = Join-Path $stage 'mysql.alloy'
    $mysqlChanged = if ($mysqlEnabled) {
        -not (Same-File $mysqlSource $MysqlModule)
    } else {
        Test-Path -LiteralPath $MysqlModule
    }
    $dbctSource = Join-Path $stage 'dbct.alloy'
    $dbctChanged = if ($dbctEnabled) {
        -not (Same-File $dbctSource $DbctModule)
    } else {
        Test-Path -LiteralPath $DbctModule
    }
    $backupSource = Join-Path $stage 'backup.alloy'
    $backupChanged = if ($backupEnabled) {
        -not (Same-File $backupSource $BackupModule)
    } else {
        Test-Path -LiteralPath $BackupModule
    }
    $argsChanged = ($priorArgs -join [char]10) -cne ($argsNew -join [char]10)
    $mustApply = $configChanged -or $moduleChanged -or $sqlChanged -or $mysqlChanged -or $dbctChanged -or $backupChanged -or $argsChanged -or $Upgrade -or -not $priorRunning -or -not $priorAuto
    if (-not $mustApply) {
        Write-Log 'Nenhuma alteracao na configuracao; servico mantido em execucao.'
        Sync-ModuleTasks
        return
    }

    $backup = Join-Path $BackupDir ('apply-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    Ensure-Directory $backup
    foreach ($path in @($target, $otherTarget)) {
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $backup (Split-Path -Leaf $path)) }
    }
    if (Test-Path -LiteralPath $HyperVModule) { Copy-Item -LiteralPath $HyperVModule -Destination (Join-Path $backup 'hyperv.alloy') }
    if (Test-Path -LiteralPath $SqlAnywhereModule) { Copy-Item -LiteralPath $SqlAnywhereModule -Destination (Join-Path $backup 'sqlanywhere.alloy') }
    if (Test-Path -LiteralPath $MysqlModule) { Copy-Item -LiteralPath $MysqlModule -Destination (Join-Path $backup 'mysql.alloy') }
    if (Test-Path -LiteralPath $DbctModule) { Copy-Item -LiteralPath $DbctModule -Destination (Join-Path $backup 'dbct.alloy') }
    if (Test-Path -LiteralPath $BackupModule) { Copy-Item -LiteralPath $BackupModule -Destination (Join-Path $backup 'backup.alloy') }
    if ($priorArgsExist) { [IO.File]::WriteAllLines((Join-Path $backup 'Arguments.txt'), $priorArgs) }

    foreach ($name in @('application','system')) {
        $oldBookmark = Join-Path $Base ('bookmark-' + $name + '.xml')
        $newBookmark = Join-Path $BookmarkDir ($name + '.xml')
        if ((Test-Path -LiteralPath $oldBookmark) -and -not (Test-Path -LiteralPath $newBookmark)) {
            Copy-Item -LiteralPath $oldBookmark -Destination $newBookmark
        }
    }

    Write-Log 'Aplicando configuracao em ProgramData e atualizando argumentos do servico...'
    if ($priorRunning) { Stop-Service -Name $ServiceName -ErrorAction Stop }
    $applied = $true
    if ($configChanged) {
        Copy-Item -LiteralPath $Source -Destination $target -Force
        if (Test-Path -LiteralPath $otherTarget) { Remove-Item -LiteralPath $otherTarget -Force -ErrorAction Stop }
    }
    if ($moduleChanged) {
        if ($hypervEnabled) {
            Copy-Item -LiteralPath $moduleSource -Destination $HyperVModule -Force
        } else {
            Remove-Item -LiteralPath $HyperVModule -Force -ErrorAction Stop
        }
    }
    if ($sqlChanged) {
        if ($sqlEnabled) {
            Copy-Item -LiteralPath $sqlSource -Destination $SqlAnywhereModule -Force
        } else {
            Remove-Item -LiteralPath $SqlAnywhereModule -Force -ErrorAction Stop
        }
    }
    if ($mysqlChanged) {
        if ($mysqlEnabled) {
            Copy-Item -LiteralPath $mysqlSource -Destination $MysqlModule -Force
        } else {
            Remove-Item -LiteralPath $MysqlModule -Force -ErrorAction Stop
        }
    }
    if ($dbctChanged) {
        if ($dbctEnabled) {
            Copy-Item -LiteralPath $dbctSource -Destination $DbctModule -Force
        } else {
            Remove-Item -LiteralPath $DbctModule -Force -ErrorAction Stop
        }
    }
    if ($backupChanged) {
        if ($backupEnabled) {
            Copy-Item -LiteralPath $backupSource -Destination $BackupModule -Force
        } else {
            Remove-Item -LiteralPath $BackupModule -Force -ErrorAction Stop
        }
    }
    New-ItemProperty -LiteralPath $Registry -Name 'Arguments' -PropertyType MultiString -Value ([string[]]$argsNew) -Force | Out-Null
    Set-Service -Name $ServiceName -StartupType Automatic
    $startedAt = Get-Date
    Start-Service -Name $ServiceName -ErrorAction Stop
    if (-not (Ready)) {
        throw ("Alloy nao ficou pronto em ${ReadyTimeoutSeconds}s (127.0.0.1:12345)." + (Get-AlloyEventSummary $startedAt))
    }
    $active = @('Windows')
    if ($hypervEnabled) { $active += 'Hyper-V' }
    if ($sqlEnabled) { $active += 'SQL Anywhere' }
    if ($mysqlEnabled) { $active += 'MySQL' }
    if ($dbctEnabled) { $active += 'DBCT' }
    if ($backupEnabled) { $active += 'leitura de backups' }
    Write-Log "Alloy ativo e pronto. Perfil: $Perfil. Modulos: $($active -join ' + ')."
    $configConfirmed = $true
    # Configuracao confirmada: uma falha das tarefas dos modulos daqui em
    # diante e reportada, mas nao desfaz o Alloy que ja esta funcionando.
    $applied = $false
    Sync-ModuleTasks
} catch {
    $original = $_
    if ($applied -and $backup) {
        Write-Warning 'Falha apos aplicar a configuracao. Iniciando rollback...'
        try {
            Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
            foreach ($path in @($target, $otherTarget)) {
                $saved = Join-Path $backup (Split-Path -Leaf $path)
                if (Test-Path -LiteralPath $saved) {
                    Copy-Item -LiteralPath $saved -Destination $path -Force
                } else {
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                }
            }
            $savedModule = Join-Path $backup 'hyperv.alloy'
            if (Test-Path -LiteralPath $savedModule) {
                Copy-Item -LiteralPath $savedModule -Destination $HyperVModule -Force
            } else {
                Remove-Item -LiteralPath $HyperVModule -Force -ErrorAction SilentlyContinue
            }
            $savedSql = Join-Path $backup 'sqlanywhere.alloy'
            if (Test-Path -LiteralPath $savedSql) {
                Copy-Item -LiteralPath $savedSql -Destination $SqlAnywhereModule -Force
            } else {
                Remove-Item -LiteralPath $SqlAnywhereModule -Force -ErrorAction SilentlyContinue
            }
            $savedMysql = Join-Path $backup 'mysql.alloy'
            if (Test-Path -LiteralPath $savedMysql) {
                Copy-Item -LiteralPath $savedMysql -Destination $MysqlModule -Force
            } else {
                Remove-Item -LiteralPath $MysqlModule -Force -ErrorAction SilentlyContinue
            }
            $savedDbct = Join-Path $backup 'dbct.alloy'
            if (Test-Path -LiteralPath $savedDbct) {
                Copy-Item -LiteralPath $savedDbct -Destination $DbctModule -Force
            } else {
                Remove-Item -LiteralPath $DbctModule -Force -ErrorAction SilentlyContinue
            }
            $savedBackup = Join-Path $backup 'backup.alloy'
            if (Test-Path -LiteralPath $savedBackup) {
                Copy-Item -LiteralPath $savedBackup -Destination $BackupModule -Force
            } else {
                Remove-Item -LiteralPath $BackupModule -Force -ErrorAction SilentlyContinue
            }
            if ($priorArgsExist) {
                New-ItemProperty -LiteralPath $Registry -Name 'Arguments' -PropertyType MultiString -Value ([string[]]$priorArgs) -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $Registry -Name 'Arguments' -ErrorAction SilentlyContinue
            }
            if ($priorOurs) {
                if ($priorAuto) { Set-Service -Name $ServiceName -StartupType Automatic }
                else { Set-Service -Name $ServiceName -StartupType Manual }
                if ($priorRunning) {
                    Start-Service -Name $ServiceName
                    if (-not (Ready)) { Write-Warning 'Alloy anterior nao ficou pronto apos rollback.' }
                }
            }
        } catch { Write-Warning "Rollback incompleto. Verifique $backup." }
    }
    if (-not $priorOurs -and -not $configConfirmed -and (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        # Nada nosso a preservar: sem configuracao valida o Alloy so pareceria
        # saudavel. Fica parado ate uma instalacao concluir.
        Stop-Service -Name $ServiceName -ErrorAction SilentlyContinue
        Set-Service -Name $ServiceName -StartupType Manual -ErrorAction SilentlyContinue
        Write-Warning 'Alloy parado (inicio manual): a instalacao nao foi concluida. Corrija o erro abaixo e execute [1] de novo.'
    }
    throw $original
} finally {
    if ($script:LocalHttp) { $script:LocalHttp.Dispose() }
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
