# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\Configuration.psm1') -Force

Describe 'Configuration module' {
    BeforeAll {
        $script:tempConfig = Join-Path $env:TEMP 'PowerShellScripts_Test_Config.xml'
        if (Test-Path $script:tempConfig) { Remove-Item -Path $script:tempConfig -Force -ErrorAction SilentlyContinue }
    }

    It 'Initializes configuration with defaults and persists to disk' {
        $config = Initialize-ScriptConfiguration -ConfigPath $script:tempConfig -DefaultConfig (Get-DefaultConfiguration)
        $config | Should -Not -BeNullOrEmpty
        (Test-Path $script:tempConfig) | Should -BeTrue
    }

    It 'Get-DefaultConfiguration contains expected sections' {
        $defaults = Get-DefaultConfiguration
        $defaults.Logging | Should -Not -BeNullOrEmpty
        $defaults.Notifications | Should -Not -BeNullOrEmpty
        $defaults.Deployment | Should -Not -BeNullOrEmpty
        $defaults.Security | Should -Not -BeNullOrEmpty
        $defaults.Performance | Should -Not -BeNullOrEmpty
    }

    It 'Sets and gets a simple configuration value' {
        Set-ScriptConfiguration -Key 'TestKey' -Value 'TestValue' -ConfigPath $script:tempConfig
        $val = Get-ScriptConfiguration -Key 'TestKey' -DefaultValue $null
        $val | Should -Be 'TestValue'
    }

    It 'Returns default value for unknown key' {
        $val = Get-ScriptConfiguration -Key 'DoesNotExist' -DefaultValue 'fallback'
        $val | Should -Be 'fallback'
    }

    It 'Returns the whole configuration when no key is given' {
        $config = Get-ScriptConfiguration
        $config | Should -BeOfType [System.Collections.Hashtable]
        $config.ContainsKey('TestKey') | Should -BeTrue
    }

    It 'Persisted configuration can be read back' {
        $loaded = Import-Clixml $script:tempConfig
        $loaded.ContainsKey('TestKey') | Should -BeTrue
        $loaded['TestKey'] | Should -Be 'TestValue'
    }
}
