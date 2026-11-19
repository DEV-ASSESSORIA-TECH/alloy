# Carregado (". ") pelo ops\install.ps1: funcoes comuns da instalacao (diretorios, ACL, servico, tarefas agendadas, arquivos de modulo).
# Manter em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.

$ReadyTimeoutSeconds = 60

function Same-File([string]$A, [string]$B) {
    if (-not (Test-Path -LiteralPath $B -PathType Leaf)) { return $false }
    return (Get-FileHash -LiteralPath $A -Algorithm SHA256).Hash -ceq (Get-FileHash -LiteralPath $B -Algorithm SHA256).Hash
}

# Ate $ReadyTimeoutSeconds: a primeira inicializacao numa estacao pode demorar
# (o antivirus examina o executavel novo). Volta assim que o Alloy responde.
function Ready {
    $deadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            try {
                $resp = (Get-LocalHttp).GetAsync($ReadyUrl).GetAwaiter().GetResult()
                try { if ([int]$resp.StatusCode -eq 200) { return $true } } finally { $resp.Dispose() }
            } catch { }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

# Ultimas mensagens do Alloy no Event Viewer desde $Since (para o erro).
function Get-AlloyEventSummary([datetime]$Since) {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Alloy'; StartTime = $Since } -MaxEvents 40 -ErrorAction Stop)
        $lines = @($events | Where-Object { $_.Message -match 'level=(warn|error)|level=(WARN|ERROR)|failed|error' } |
            Select-Object -First 4 | ForEach-Object { '  ' + (($_.Message -split "`r?`n")[0]).Trim() })
        if ($lines.Count -eq 0) { $lines = @($events | Select-Object -First 2 | ForEach-Object { '  ' + (($_.Message -split "`r?`n")[0]).Trim() }) }
        if ($lines.Count -gt 0) { return "`nUltimos eventos do Alloy (Event Viewer > Aplicativo):`n" + ($lines -join "`n") }
    } catch { }
    return ''
}

# Texto padrao quando o antivirus e o suspeito provavel.
function Get-AntivirusHint {
    return "`nProvavel bloqueio do antivirus (ex.: Bitdefender Advanced Threat Control): verifique a quarentena e as exclusoes " +
        "de $AlloyInstallerDir, $(Split-Path -Parent $Exe) e $Base (docs/antivirus.md)."
}

# Baixa o instalador oficial para $AlloyInstallerDir e confere SHA256 (SHA256SUMS

# Arquivo do modulo (modules\*.alloy) ou coletor (collectors\*.ps1): da pasta
# do alloyctl/clone local, ou baixado da mesma versao do alloy.ps1 (ALLOY_REF;
# padrao: main).
function Get-ModuleRelativePath([string]$Name) {
    if ($Name -like '*.alloy') { return "modules/$Name" }
    return "collectors/$Name"
}
function Copy-ModuleFile([string]$Name, [string]$Destination) {
    $relative = Get-ModuleRelativePath $Name
    $local = Join-Path $RepoRoot ($relative -replace '/', '\')
    if (Test-Path -LiteralPath $local -PathType Leaf) {
        Copy-Item -LiteralPath $local -Destination $Destination
        return
    }
    $ref = if ($env:ALLOY_REF) { $env:ALLOY_REF } else { 'main' }
    if ($ref -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $ref.Contains('..')) {
        throw "ALLOY_REF invalido: $ref"
    }
    Write-Log "Baixando $relative (ref $ref)..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $raw = "https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/$ref/windows/$relative"
    Invoke-WebRequest -Uri $raw -OutFile $Destination -UseBasicParsing -Headers @{ 'User-Agent' = $UserAgent }
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw "Download de $Name vazio."
    }
}

# Tarefa agendada de coletor textfile: SYSTEM (pelo SID: o nome muda com o
# idioma do Windows), sem execucoes simultaneas, tambem na inicializacao.
function Register-CollectorTask([string]$TaskPath, [string]$TaskName, [string]$Script, [object[]]$Triggers,
                                [TimeSpan]$TimeLimit, [string]$Description) {
    $system = ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')).Translate([System.Security.Principal.NTAccount]).Value
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $powershell -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $Script)
    $atStartup = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId $system -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit $TimeLimit `
        -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Action $action `
        -Trigger (@($Triggers) + $atStartup) -Principal $principal -Settings $settings -Force `
        -Description $Description | Out-Null
}

# Primeira execucao agora, para nao esperar o proximo ciclo. Devolve as
# linhas do .prom gerado.
function Invoke-FirstRun([string]$TaskPath, [string]$TaskName, [string]$Output, [int]$TimeoutSeconds, [string]$Label) {
    $before = if (Test-Path -LiteralPath $Output) { (Get-Item -LiteralPath $Output).LastWriteTimeUtc } else { [datetime]::MinValue }
    Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
    for ($i = 0; $i -lt [Math]::Ceiling($TimeoutSeconds / 2); $i++) {
        Start-Sleep -Seconds 2
        $state = (Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName).State
        if ((Test-Path -LiteralPath $Output) -and (Get-Item -LiteralPath $Output).LastWriteTimeUtc -gt $before -and $state -ne 'Running') {
            return [IO.File]::ReadAllLines($Output)
        }
    }
    throw "$Label nao gerou $Output em ${TimeoutSeconds}s. Veja os logs em $LogDir."
}

function Read-Value([string]$Prompt, [string]$Default) {
    $hint = if ($Default) { " [$Default]" } else { '' }
    $value = (Read-Host "$Prompt$hint").Trim()
    if (-not $value) { $value = $Default }
    if (-not $value) { throw "$Prompt e obrigatorio." }
    return $value
}
