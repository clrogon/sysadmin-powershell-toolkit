# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\ErrorHandling') -Force

Describe 'Find-DuplicateFiles.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\Find-DuplicateFiles\Find-DuplicateFiles.ps1')
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "FindDuplicateFiles_Tests_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
    }

    AfterAll {
        if (Test-Path $script:testRoot) {
            Remove-Item $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Describe 'Test-ValidPath' {
        It 'returns True for a valid path' {
            Test-ValidPath -Path 'C:\Temp' | Should -BeTrue
        }

        It 'returns True for a relative path' {
            Test-ValidPath -Path 'sub\folder' | Should -BeTrue
        }

        It 'returns False for directory traversal sequences' {
            Test-ValidPath -Path '..\evil' | Should -BeFalse
            Test-ValidPath -Path 'C:\Temp\..\..\..\evil' | Should -BeFalse
        }

        It 'returns False for empty or whitespace path' {
            Test-ValidPath -Path '' | Should -BeFalse
            Test-ValidPath -Path '   ' | Should -BeFalse
        }

        It 'returns False for an invalid path format' {
            Test-ValidPath -Path "invalid`0char" | Should -BeFalse
        }
    }

    Describe 'Test-ValidExtension' {
        It 'returns True for a valid extension' {
            Test-ValidExtension -Extension '.txt' | Should -BeTrue
            Test-ValidExtension -Extension '.zip' | Should -BeTrue
        }

        It 'returns False when the leading dot is missing' {
            Test-ValidExtension -Extension 'txt' | Should -BeFalse
        }

        It 'returns False for empty or whitespace extension' {
            Test-ValidExtension -Extension '' | Should -BeFalse
            Test-ValidExtension -Extension ' ' | Should -BeFalse
        }

        It 'returns False for an extension with invalid characters' {
            Test-ValidExtension -Extension '.t xt' | Should -BeFalse
            Test-ValidExtension -Extension '.t$xt' | Should -BeFalse
        }
    }

    Describe 'Get-FileHashValue' {
        It 'returns a SHA256 hash for an existing file' {
            $file = Join-Path $script:testRoot 'hashme.txt'
            Set-Content -Path $file -Value 'hash content'
            $hash = Get-FileHashValue -FilePath $file -Algorithm 'SHA256'
            $hash | Should -Not -BeNullOrEmpty
            $hash | Should -Match '^[0-9a-fA-F]{64}$'
        }

        It 'returns the expected known hash' {
            $file = Join-Path $script:testRoot 'known.txt'
            Set-Content -Path $file -Value 'abc' -NoNewline
            $hash = Get-FileHashValue -FilePath $file -Algorithm 'SHA256'
            $hash | Should -Be (Get-FileHash -Path $file -Algorithm SHA256).Hash
        }

        It 'returns $null for a nonexistent file' {
            Get-FileHashValue -FilePath (Join-Path $script:testRoot 'missing.txt') | Should -BeNullOrEmpty
        }
    }

    Describe 'ConvertTo-HtmlEncoded' {
        It 'encodes HTML-sensitive characters' {
            ConvertTo-HtmlEncoded -Value '<b>&"x"</b>' | Should -Be '&lt;b&gt;&amp;&quot;x&quot;&lt;/b&gt;'
        }

        It 'returns empty string for empty input' {
            ConvertTo-HtmlEncoded -Value '' | Should -Be ''
            ConvertTo-HtmlEncoded -Value $null | Should -Be ''
        }

        It 'leaves plain text unchanged' {
            ConvertTo-HtmlEncoded -Value 'plain text 123' | Should -Be 'plain text 123'
        }
    }

    Describe 'Find-DuplicateFiles' {
        It 'returns only duplicate objects (no log-entry pollution)' {
            $dir = Join-Path $script:testRoot 'dups'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir 'a.txt') -Value 'same content'
            Set-Content -Path (Join-Path $dir 'b.txt') -Value 'same content'

            $result = Find-DuplicateFiles -targetDir $dir -exportPath (Join-Path $script:testRoot 'dups.csv') 2>$null
            $result | Should -Not -BeNullOrEmpty
            @($result).Count | Should -Be 1
            $result.Original | Should -Not -BeNullOrEmpty
            $result.Duplicate | Should -Not -BeNullOrEmpty
            $result.Original | Should -BeLike "$dir*"
            $result.Duplicate | Should -BeLike "$dir*"
        }

        It 'returns no duplicates for unique files' {
            $dir = Join-Path $script:testRoot 'unique'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir 'a.txt') -Value 'alpha'
            Set-Content -Path (Join-Path $dir 'b.txt') -Value 'beta'

            $result = @(Find-DuplicateFiles -targetDir $dir -exportPath (Join-Path $script:testRoot 'unique.csv') 2>$null)
            $result.Count | Should -Be 0
        }

        It 'writes the CSV export file' {
            $dir = Join-Path $script:testRoot 'export'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -Path (Join-Path $dir 'a.txt') -Value 'same'
            Set-Content -Path (Join-Path $dir 'b.txt') -Value 'same'

            $csv = Join-Path $script:testRoot 'export.csv'
            Find-DuplicateFiles -targetDir $dir -exportPath $csv 2>$null | Out-Null
            Test-Path $csv | Should -BeTrue
            @(Import-Csv $csv).Count | Should -Be 1
        }
    }
}
