# Carregado (". ") pelo ops\install.ps1: instalador oficial do Grafana Alloy (versao fixada, SHA256 e assinatura).
# Manter em ASCII: o Windows PowerShell 5.1 le arquivos sem BOM como ANSI.

# Instalador oficial: baixado para uma pasta FIXA (nunca %TEMP%\<aleatorio>, que
# antivirus com analise de comportamento, como o Bitdefender ATC, tratam como
# "script baixou e executou binario desconhecido"), conferido pelo SHA256SUMS
# da release e pela assinatura da Grafana Labs antes de executar. A pasta fixa
# permite exclusao por caminho no antivirus (docs/antivirus.md).
$InstallerZipName = 'alloy-installer-windows-amd64.exe.zip'
$InstallerExeName = 'alloy-installer-windows-amd64.exe'
# Assinante esperado (Microsoft Trusted Signing: o certificado muda a cada
# poucos dias, entao a conferencia e pelo nome, nunca pela impressao digital).
$InstallerSigner = 'Grafana Labs'

# Baixa o instalador oficial para $AlloyInstallerDir e confere SHA256 (SHA256SUMS
# da mesma release) e assinatura (Grafana Labs). Devolve o caminho do .exe.
function Get-VerifiedInstaller {
    # ProgramData permite que qualquer usuario crie pastas: a pasta-mae tambem
    # fica so para SYSTEM e Administradores (dono incluso), para ninguem trocar
    # o instalador entre a conferencia e a execucao.
    $installerParent = Split-Path -Parent $AlloyInstallerDir
    Ensure-Directory $installerParent
    Set-PrivateDirectoryAcl $installerParent
    Ensure-Directory $AlloyInstallerDir
    Set-PrivateDirectoryAcl $AlloyInstallerDir
    Get-ChildItem -LiteralPath $AlloyInstallerDir -Force | Remove-Item -Recurse -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Add-Type -AssemblyName System.Net.Http
    # Versao fixada nesta versao do alloyctl (alloy.Dockerfile, lido pelo
    # alloy.ps1 e repassado em ALLOY_VERSION).
    $release = 'v' + (Get-AlloyPinnedVersion)
    $releaseBase = "https://github.com/grafana/alloy/releases/download/$release"

    $http = [System.Net.Http.HttpClient]::new()
    try {
        $http.Timeout = [TimeSpan]::FromMinutes(5)
        $http.DefaultRequestHeaders.UserAgent.ParseAdd($UserAgent)
        Write-Log "Baixando instalador oficial do Grafana Alloy ($release)..."
        $zip = Join-Path $AlloyInstallerDir $InstallerZipName
        $response = $http.GetAsync("$releaseBase/$InstallerZipName").GetAwaiter().GetResult()
        try {
            if (-not $response.IsSuccessStatusCode) { throw "Download do instalador falhou (HTTP $([int]$response.StatusCode))." }
            [IO.File]::WriteAllBytes($zip, $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
        } finally { $response.Dispose() }
        $sums = $http.GetStringAsync("$releaseBase/SHA256SUMS").GetAwaiter().GetResult()
    } finally { $http.Dispose() }

    $expected = @{}
    foreach ($line in ($sums -split "`n")) {
        if ($line.Trim() -match '^([0-9a-fA-F]{64})\s+\*?(\S+)$') { $expected[$Matches[2]] = $Matches[1].ToLowerInvariant() }
    }
    if (-not $expected.ContainsKey($InstallerZipName)) { throw "SHA256SUMS da release $release nao lista $InstallerZipName." }
    $zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($zipHash -ne $expected[$InstallerZipName]) { throw "SHA256 do instalador nao confere com a release $release. Download descartado." }

    $unpack = Join-Path $AlloyInstallerDir 'package'
    Ensure-Directory $unpack
    Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
    $installer = Join-Path $unpack $InstallerExeName
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw ("Executavel do instalador ausente depois de extrair (removido logo apos a extracao?)." + (Get-AntivirusHint))
    }
    if ($expected.ContainsKey($InstallerExeName) -and
        (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected[$InstallerExeName]) {
        throw "SHA256 de $InstallerExeName nao confere com a release $release."
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
    if ([string]$signature.Status -in @('NotSigned', 'HashMismatch', 'NotSupportedFileFormat')) {
        throw "Instalador sem assinatura valida ($($signature.Status)). Execucao cancelada."
    }
    if ($subject -notmatch ('(^|,\s*)CN=' + [regex]::Escape($InstallerSigner) + '(,|$)') -or
        $subject -notmatch ('(^|,\s*)O=' + [regex]::Escape($InstallerSigner) + '(,|$)')) {
        throw "Instalador assinado por '$subject', esperado $InstallerSigner. Execucao cancelada."
    }
    if ([string]$signature.Status -ne 'Valid') {
        # Ex.: raiz da Microsoft ausente num Windows sem atualizacoes. O SHA256
        # ja confere com a release; o assinante tambem.
        Write-Warning "Cadeia do certificado nao validada neste Windows ($($signature.Status)); SHA256 e assinante conferem. Atualize os certificados raiz."
    }
    Write-Log "Instalador $release conferido (SHA256 da release e assinatura $InstallerSigner)."
    return $installer
}

# Executa o instalador oficial (silencioso) e confere o resultado.
function Install-AlloyPackage {
    $installer = Get-VerifiedInstaller
    try {
        $p = Start-Process -FilePath $installer -ArgumentList @('/S', '/DISABLEREPORTING=yes') -Wait -PassThru
    } catch {
        throw ("Nao foi possivel executar o instalador: $($_.Exception.Message)" + (Get-AntivirusHint))
    }
    if ($p.ExitCode -ne 0) {
        throw ("Instalador interrompido ou com erro (codigo $($p.ExitCode))." + (Get-AntivirusHint))
    }
    $missing = @()
    if (-not (Test-Path -LiteralPath $Exe -PathType Leaf)) { $missing += 'executavel' }
    if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { $missing += 'servico' }
    if (-not (Test-Path -LiteralPath $Registry)) { $missing += 'registro' }
    if ($missing.Count -gt 0) {
        throw ("Alloy nao foi instalado corretamente (ausente: $($missing -join ', '))." + (Get-AntivirusHint))
    }
    # A pasta fica (para a exclusao do antivirus); o conteudo sai.
    Get-ChildItem -LiteralPath $AlloyInstallerDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
