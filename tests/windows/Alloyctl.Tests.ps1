# Pester 5: resolucao de canais do alloyctl (windows\alloy.ps1). As funcoes
# sao extraidas do script pelo parser, sem executar o fluxo principal.
BeforeAll {
    $path = Resolve-Path (Join-Path $PSScriptRoot '..\..\windows\alloy.ps1')
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    $names = @('Test-ToolRef', 'Test-ToolSha', 'Test-ToolTag', 'Get-ToolShort', 'Get-ToolHttpErrorText',
        'Get-ToolErrorText', 'Resolve-ToolLatest', 'Resolve-ToolVersion', 'Get-WindowsPowerShellModulePath')
    $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) |
        Where-Object { $_.Name -in $names }
    foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
    $ToolRepo = 'DEV-ASSESSORIA-TECH/alloy'
}

Describe 'Funcoes extraidas do alloy.ps1' {
    It 'encontra todas' {
        foreach ($name in $names) { Get-Command $name -CommandType Function | Should -Not -BeNullOrEmpty }
    }
}

Describe 'Resolve-ToolVersion' {
    It 'stable usa a ultima release' {
        Mock Resolve-ToolLatest { 'v1.2.3' }
        Resolve-ToolVersion 'stable' | Should -Be 'v1.2.3'
        Should -Invoke Resolve-ToolLatest -Times 1 -Exactly
    }
    It 'tag fixa nao consulta a rede' {
        Mock Resolve-ToolLatest { throw 'nao deveria consultar' }
        Resolve-ToolVersion 'v1.4.0' | Should -Be 'v1.4.0'
        Should -Invoke Resolve-ToolLatest -Times 0 -Exactly
    }
}

Describe 'Validacoes' {
    It 'Test-ToolTag' {
        Test-ToolTag 'v1.0.0' | Should -BeTrue
        Test-ToolTag 'v1.2.0-rc.1' | Should -BeTrue
        Test-ToolTag '1.0.0' | Should -BeFalse
        Test-ToolTag 'stable' | Should -BeFalse
    }
    It 'Test-ToolRef' {
        Test-ToolRef 'feature/x-1.2' | Should -BeTrue
        Test-ToolRef '../x' | Should -BeFalse
        Test-ToolRef '-x' | Should -BeFalse
    }
    It 'Get-ToolShort: commit encurtado, tag inteira' {
        Get-ToolShort '0123456789abcdef0123456789abcdef01234567' | Should -Be '0123456'
        Get-ToolShort 'v1.10.12' | Should -Be 'v1.10.12'
        Get-ToolShort '' | Should -Be '?'
    }
    It 'Get-ToolHttpErrorText explica o limite da API' {
        Get-ToolHttpErrorText 403 'main' | Should -BeLike '*limite da API*'
        Get-ToolHttpErrorText 404 'nope' | Should -BeLike "*'nope' nao existe*"
    }
}

Describe 'Get-WindowsPowerShellModulePath' {
    It 'tira as pastas do PowerShell 7 e mantem as do Windows PowerShell' {
        $inherited = @(
            'C:\Users\adm\Documents\PowerShell\Modules',
            'C:\Program Files\PowerShell\Modules',
            'c:\program files\powershell\7\Modules',
            'C:\Users\adm\Documents\WindowsPowerShell\Modules',
            'C:\Program Files\WindowsPowerShell\Modules',
            'C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules',
            'D:\Modulos'
        ) -join ';'
        Get-WindowsPowerShellModulePath $inherited | Should -Be (@(
            'C:\Users\adm\Documents\WindowsPowerShell\Modules',
            'C:\Program Files\WindowsPowerShell\Modules',
            'C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules',
            'D:\Modulos'
        ) -join ';')
    }
    It 'mantem um PSModulePath limpo como esta' {
        $clean = 'C:\Program Files\WindowsPowerShell\Modules;C:\WINDOWS\system32\WindowsPowerShell\v1.0\Modules'
        Get-WindowsPowerShellModulePath $clean | Should -Be $clean
    }
}
