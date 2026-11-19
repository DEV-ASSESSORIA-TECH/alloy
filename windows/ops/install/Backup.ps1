# Carregado (". ") pelo ops\install.ps1: leitura dos backups (pasta textfile\backup e grupo de escrita).
# Manter em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.

# Leitura dos backups (perfil servidor, sempre instalada): produtores externos
# gravam textfile\backup\<service>__<backup_id>.prom (contrato backup.yml do
# repositorio grafana). Escrita para SYSTEM, Administradores e o grupo local.
$BackupWritersDescription = 'Gravam o estado dos backups lido pelo Grafana Alloy'

# Grupo local dos produtores de backup: SID do grupo, criado se ausente (ADSI
# WinNT: funciona no Windows PowerShell 5.1 de qualquer versao do Windows).
function Get-BackupWritersSid {
    $account = [System.Security.Principal.NTAccount]::new($env:COMPUTERNAME, $BackupWritersGroup)
    try { return $account.Translate([System.Security.Principal.SecurityIdentifier]) } catch { }
    Write-Log "Criando o grupo local '$BackupWritersGroup'..."
    $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
    # Os metodos ADSI devolvem $null pelo adaptador do PowerShell; sem o
    # descarte, esses nulos saem da funcao junto com o SID.
    $group = $computer.Create('group', $BackupWritersGroup)
    $null = $group.SetInfo()
    $null = $group.Put('Description', $BackupWritersDescription)
    $null = $group.SetInfo()
    return $account.Translate([System.Security.Principal.SecurityIdentifier])
}

# Pasta lida pelo backup.alloy. Sem o grupo (ex.: controlador de dominio, sem
# grupos locais), a pasta fica so com SYSTEM e Administradores e a leitura
# continua valendo; o aviso indica o motivo.
function Sync-BackupTextfile {
    Ensure-Directory $BackupTextfileDir
    $writers = @()
    try {
        $writers = @(Get-BackupWritersSid | Where-Object { $_ -is [System.Security.Principal.SecurityIdentifier] })
    } catch {
        Write-Warning "Grupo local '$BackupWritersGroup' indisponivel ($($_.Exception.Message)). $BackupTextfileDir aceita escrita so de SYSTEM e Administradores."
    }
    Set-PrivateDirectoryAcl $BackupTextfileDir $writers
}
