# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\ErrorHandling') -Force

Describe 'Show-Notification.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\Show-Notification\Show-Notification.ps1')
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ShowNotification_Tests_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
        $script:validPng = Join-Path $script:testRoot 'icon.png'
        Set-Content -Path $script:validPng -Value 'png'
    }

    AfterAll {
        if (Test-Path $script:testRoot) {
            Remove-Item $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Describe 'Test-ValidImagePath' {
        It 'returns True for an existing image with a valid extension' {
            Test-ValidImagePath -Path $script:validPng | Should -BeTrue
        }

        It 'returns False for empty or whitespace path' {
            Test-ValidImagePath -Path '' | Should -BeFalse
            Test-ValidImagePath -Path ' ' | Should -BeFalse
        }

        It 'throws on directory traversal sequences' {
            { Test-ValidImagePath -Path '..\evil.png' } | Should -Throw
        }

        It 'throws when the file does not exist' {
            { Test-ValidImagePath -Path (Join-Path $script:testRoot 'missing.png') } | Should -Throw
        }

        It 'throws for a valid file with a disallowed extension' {
            $txt = Join-Path $script:testRoot 'note.txt'
            Set-Content -Path $txt -Value 'text'
            { Test-ValidImagePath -Path $txt } | Should -Throw
        }
    }
}
