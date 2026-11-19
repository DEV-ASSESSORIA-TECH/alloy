# Pester 5: partes do ops\install.ps1 carregam juntas (constantes e funcoes
# vem do lib\Common.ps1 e de ops\install\*.ps1) e acham os arquivos do clone.
BeforeAll {
    $WindowsRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\windows')
    $RepoRoot = $WindowsRoot.Path
    . (Join-Path $RepoRoot 'lib\Common.ps1')
    # Mesma ordem do install.ps1.
    $installText = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'ops\install.ps1')
    $partList = [regex]::Match($installText, "foreach \(\`$part in @\(([^)]*)\)\)").Groups[1].Value
    $Parts = @([regex]::Matches($partList, "'(\w+)'") | ForEach-Object { $_.Groups[1].Value })
    foreach ($part in $Parts) { . (Join-Path $RepoRoot "ops\install\$part.ps1") }
}

Describe 'Partes do instalador' {
    It 'install.ps1 lista as partes' {
        $Parts.Count | Should -BeGreaterThan 5
    }
    It 'cada arquivo em ops\install e carregado' {
        $onDisk = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'ops\install') -Filter *.ps1 | ForEach-Object { $_.BaseName })
        @($onDisk | Where-Object { $_ -notin $Parts }) | Should -BeNullOrEmpty
    }
    It 'define <_>' -ForEach @(
        'Install-AlloyPackage', 'Get-VerifiedInstaller', 'Sync-BackupTextfile', 'Sync-HypervisorInventory',
        'Test-HyperV', 'Sync-SqlAnywhereCollector', 'Sync-MysqlModule', 'Sync-DbctModule',
        'Copy-ModuleFile', 'Register-CollectorTask', 'Invoke-FirstRun', 'Read-Value'
    ) {
        Get-Command $_ -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'constantes dos modulos usam as pastas do Common' {
        $InventoryScript | Should -BeLike "$ScriptsDir*"
        $SqlOutputDir | Should -BeLike "$TextfileDir*"
        $MysqlConfigFile | Should -BeLike "$MysqlState*"
        $DbctCollectorScript | Should -BeLike "$ScriptsDir*"
    }
}

Describe 'Copy-ModuleFile' {
    It 'mapeia .alloy para modules e .ps1 para collectors' {
        Get-ModuleRelativePath 'hyperv.alloy' | Should -Be 'modules/hyperv.alloy'
        Get-ModuleRelativePath 'dbct-collector.ps1' | Should -Be 'collectors/dbct-collector.ps1'
    }
    It 'copia do clone sem baixar' {
        Mock Invoke-WebRequest { throw 'nao deveria baixar' }
        foreach ($name in @('hyperv.alloy', 'backup.alloy', 'hypervisor-inventory.ps1', 'sqlanywhere-collector.ps1', 'dbct-collector.ps1')) {
            $target = Join-Path $TestDrive $name
            Copy-ModuleFile $name $target
            (Get-Item -LiteralPath $target).Length | Should -BeGreaterThan 0
        }
    }
    It 'baixa da mesma versao quando o arquivo nao esta na pasta' {
        $RepoRoot = Join-Path $TestDrive 'vazio'
        $env:ALLOY_REF = 'v1.0.0'
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'x' } -ParameterFilter {
            $Uri -eq 'https://raw.githubusercontent.com/DEV-ASSESSORIA-TECH/alloy/v1.0.0/windows/modules/mysql.alloy'
        }
        Copy-ModuleFile 'mysql.alloy' (Join-Path $TestDrive 'mysql.alloy')
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        $env:ALLOY_REF = $null
    }
}
