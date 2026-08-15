# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\ErrorHandling') -Force

Describe 'DeploymentScript.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\DeploymentScript\DeploymentScript.ps1')
    }

    Describe 'Validate-Url' {
        It 'returns True for a valid HTTPS URL' {
            Validate-Url -Url 'https://example.com/setup.exe' | Should -BeTrue
            Validate-Url -Url 'https://example.com/path/file.msi?ver=1.2' | Should -BeTrue
        }

        It 'returns False for an HTTP (non-HTTPS) URL' {
            Validate-Url -Url 'http://example.com/setup.exe' | Should -BeFalse
        }

        It 'returns False for empty or null URL' {
            Validate-Url -Url '' | Should -BeFalse
            Validate-Url -Url '   ' | Should -BeFalse
        }

        It 'returns False for a malformed URL' {
            Validate-Url -Url 'https://' | Should -BeFalse
            Validate-Url -Url 'https://exa mple.com/file' | Should -BeFalse
        }
    }
}
