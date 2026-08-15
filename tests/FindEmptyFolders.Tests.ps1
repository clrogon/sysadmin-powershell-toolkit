# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\ErrorHandling') -Force

Describe 'Find-EmptyFolders.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\FindEmptyFolders\Find-EmptyFolders.ps1')
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "FindEmptyFolders_Tests_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null

        $script:IncludeHiddenFiles = $false
        $script:IncludeSystemFiles = $false
        $script:MinAgeDays = 0
    }

    AfterAll {
        if (Test-Path $script:testRoot) {
            Remove-Item $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Describe 'Find-EmptyFolders' {
        It 'returns only empty directories' {
            New-Item -ItemType Directory -Path (Join-Path $script:testRoot 'empty1') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:testRoot 'filled') -Force | Out-Null
            Set-Content -Path (Join-Path (Join-Path $script:testRoot 'filled') 'keep.txt') -Value 'content'

            $result = @(Find-EmptyFolders -FolderPath $script:testRoot -LogLevel Verbose 2>$null)
            $result | Where-Object { $_ -like '*empty1' } | Should -Not -BeNullOrEmpty
            $result | Where-Object { $_ -like '*filled' } | Should -BeNullOrEmpty
        }
    }

    Describe 'Find-EmptyFoldersSmart' {
        It 'returns structured objects with a Path property' {
            New-Item -ItemType Directory -Path (Join-Path $script:testRoot 'smart_empty') -Force | Out-Null

            $result = @(Find-EmptyFoldersSmart -FolderPath $script:testRoot -OutputPath (Join-Path $script:testRoot 'smart.csv'))
            $result | Should -Not -BeNullOrEmpty
            $result[0] | Should -BeOfType PSCustomObject
            $result[0].Path | Should -Not -BeNullOrEmpty
        }

        It 'does not list directories containing files' {
            New-Item -ItemType Directory -Path (Join-Path $script:testRoot 'smart_filled') -Force | Out-Null
            Set-Content -Path (Join-Path (Join-Path $script:testRoot 'smart_filled') 'file.txt') -Value 'x'

            $result = @(Find-EmptyFoldersSmart -FolderPath $script:testRoot -OutputPath (Join-Path $script:testRoot 'smart2.csv'))
            $result | Where-Object { $_.Path -like '*smart_filled' } | Should -BeNullOrEmpty
        }

        It 'writes the CSV report' {
            $csv = Join-Path $script:testRoot 'report.csv'
            Find-EmptyFoldersSmart -FolderPath $script:testRoot -OutputPath $csv | Out-Null
            Test-Path $csv | Should -BeTrue
        }
    }

    Describe 'Remove-EmptyFolders' {
        It 'removes empty directories with -Force' {
            $target = Join-Path $script:testRoot 'remove_target'
            New-Item -ItemType Directory -Path (Join-Path $target 'gone') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $target 'kept') -Force | Out-Null
            Set-Content -Path (Join-Path (Join-Path $target 'kept') 'file.txt') -Value 'x'

            Remove-EmptyFolders -FolderPath $target -Force 2>$null | Out-Null

            Test-Path (Join-Path $target 'gone') | Should -BeFalse
            Test-Path (Join-Path (Join-Path $target 'kept') 'file.txt') | Should -BeTrue
        }

        It 'does not remove directories with -WhatIf' {
            $target = Join-Path $script:testRoot 'whatif_target'
            New-Item -ItemType Directory -Path (Join-Path $target 'untouched') -Force | Out-Null

            Remove-EmptyFolders -FolderPath $target -Force -WhatIf 2>$null | Out-Null

            Test-Path (Join-Path $target 'untouched') | Should -BeTrue
        }

        It 'respects ExcludedPaths' {
            $target = Join-Path $script:testRoot 'excluded_target'
            $protected = Join-Path $target 'protected'
            New-Item -ItemType Directory -Path $protected -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $target 'free') -Force | Out-Null

            Remove-EmptyFolders -FolderPath $target -Force -ExcludedPaths @('protected') 2>$null | Out-Null

            Test-Path $protected | Should -BeTrue
            Test-Path (Join-Path $target 'free') | Should -BeFalse
        }
    }
}
