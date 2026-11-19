# Pester 5: lib\Common.ps1 (versao fixada do Alloy, refs e downloads).
BeforeAll {
    $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $RepoRoot 'windows\lib\Common.ps1')
}

Describe 'Read-AlloyVersionFile' {
    It 'le a versao do alloy.Dockerfile do repositorio' {
        Read-AlloyVersionFile (Join-Path $RepoRoot 'alloy.Dockerfile') | Should -Match '^\d+\.\d+\.\d+$'
    }
    It 'recusa tag sem versao' {
        $file = Join-Path $TestDrive 'latest.Dockerfile'
        Set-Content -LiteralPath $file -Value 'FROM grafana/alloy:latest'
        { Read-AlloyVersionFile $file } | Should -Throw '*nao encontrada*'
    }
    It 'recusa arquivo ausente' {
        { Read-AlloyVersionFile (Join-Path $TestDrive 'nao-existe') } | Should -Throw '*ausente*'
    }
}

Describe 'Get-AlloyPinnedVersion' {
    AfterEach { $env:ALLOY_VERSION = $null }
    It 'devolve a versao repassada pelo alloy.ps1' {
        $env:ALLOY_VERSION = '1.19.2'
        Get-AlloyPinnedVersion | Should -Be '1.19.2'
    }
    It 'falha sem ALLOY_VERSION' {
        $env:ALLOY_VERSION = $null
        { Get-AlloyPinnedVersion } | Should -Throw '*alloyctl*'
    }
}

Describe 'Get-AlloyRef' {
    AfterEach { $env:ALLOY_REF = $null }
    It 'usa main sem ALLOY_REF' {
        $env:ALLOY_REF = $null
        Get-AlloyRef | Should -Be 'main'
    }
    It 'recusa ref com ..' {
        $env:ALLOY_REF = 'a/../b'
        { Get-AlloyRef } | Should -Throw
    }
}

Describe 'Save-RemoteFiles em clone local' {
    It 'nao faz nada quando o arquivo existe' {
        New-Item -ItemType Directory -Path (Join-Path $TestDrive 'ops') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $TestDrive 'ops\x.ps1') -Value '#'
        { Save-RemoteFiles $TestDrive @('ops/x.ps1') } | Should -Not -Throw
    }
}
