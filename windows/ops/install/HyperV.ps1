# Carregado (". ") pelo ops\install.ps1: modulo Hyper-V (inventario de VMs).
# Manter em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.

# Inventario de VMs (modulo Hyper-V): script, saida do textfile, cache e logs.
$InventoryName = 'hypervisor-inventory.ps1'
$InventoryScript = Join-Path $ScriptsDir $InventoryName
$InventoryState = Join-Path $DataDir 'hypervisor'
$InventoryOutputDir = Join-Path $TextfileDir 'hypervisor'
# Versoes anteriores gravavam na raiz do textfile\.
$LegacyInventoryOutput = Join-Path $TextfileDir 'hypervisor.prom'

# Inventario de VMs: script em scripts\, tarefa agendada a cada minuto como
# SYSTEM e primeira execucao conferida. Desabilitado: remove tarefa, script,
# saida, cache e logs do inventario.
function Sync-HypervisorInventory([bool]$Enabled, [string]$StagedScript) {
    $task = Get-ScheduledTask -TaskPath $InventoryTaskPath -TaskName $InventoryTaskName -ErrorAction SilentlyContinue
    if (-not $Enabled) {
        $hadFiles = (Test-Path -LiteralPath $InventoryScript) -or (Test-Path -LiteralPath $InventoryOutput)
        if ($task) { Unregister-ScheduledTask -TaskPath $InventoryTaskPath -TaskName $InventoryTaskName -Confirm:$false }
        foreach ($path in @($InventoryScript, $InventoryOutput, ($InventoryOutput + '.tmp'))) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $InventoryState) { Remove-Item -LiteralPath $InventoryState -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $LogDir) {
            Get-ChildItem -LiteralPath $LogDir -Filter 'hypervisor-inventory-*.log' -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        if ($task -or $hadFiles) { Write-Log 'Inventario de VMs removido (tarefa, script, saida e logs).' }
        return
    }

    if (-not (Same-File $StagedScript $InventoryScript)) {
        Copy-Item -LiteralPath $StagedScript -Destination $InventoryScript -Force
        Write-Log "Inventario de VMs: script instalado em $InventoryScript."
    }

    $everyMinute = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes 1)
    Register-CollectorTask $InventoryTaskPath $InventoryTaskName $InventoryScript @($everyMinute) (New-TimeSpan -Minutes 5) `
        'Inventario de VMs para o Grafana Alloy (textfile\hypervisor\hypervisor.prom). Gerenciado pelo install.ps1.'

    $content = Invoke-FirstRun $InventoryTaskPath $InventoryTaskName $InventoryOutput 90 'Inventario de VMs'
    $ok = @($content | Where-Object { $_ -match '^hypervisor_inventory_success 1$' }).Count -gt 0
    $vmCount = @($content | Where-Object { $_ -like 'hypervisor_vm_info{*' }).Count
    $problems = ($content | Where-Object { $_ -like 'hypervisor_inventory_problems *' } | Select-Object -First 1) -replace '^\S+\s+', ''
    if (-not $ok) { throw "Inventario de VMs falhou na primeira execucao. Veja os logs em $LogDir." }
    $note = if ($problems -and $problems -ne '0') { " ($problems aviso(s); veja $LogDir)" } else { '' }
    Write-Log "Inventario de VMs ativo: $vmCount VM(s), atualizado a cada minuto$note."
}

# A presenca dos cmdlets nao confirma que o Hyper-V local esta ativo.
function Test-HyperV {
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') { return $false }
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return $false }
    try {
        $null = @(Get-VM -ErrorAction Stop)
        return $true
    } catch {
        Write-Log "Hyper-V presente, mas nao acessivel: $($_.Exception.Message)"
        return $false
    }
}
