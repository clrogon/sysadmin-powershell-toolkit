# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\ErrorHandling') -Force

Describe 'ClearTeamsCache.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\ClearTeamsCache\ClearTeamsCache.ps1')
    }

    Describe 'Test-DiskSpace' {
        It 'returns a boolean' {
            Test-DiskSpace | Should -BeOfType [bool]
        }
    }

    Describe 'Test-AdminRights' {
        It 'returns a boolean' {
            Test-AdminRights | Should -BeOfType [bool]
        }
    }
}
