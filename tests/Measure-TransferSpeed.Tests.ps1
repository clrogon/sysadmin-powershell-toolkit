# Requires Pester
Import-Module (Join-Path $PSScriptRoot '..\modules\ErrorHandling') -Force

$script:isWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

Describe 'Measure-TransferSpeed.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\Measure-TransferSpeed\Measure-TransferSpeed.ps1')
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "MeasureTransferSpeed_Tests_$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $script:testRoot -Force | Out-Null
    }

    AfterAll {
        if (Test-Path $script:testRoot) {
            Remove-Item $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Describe 'ConvertTo-HtmlEncoded' {
        It 'encodes HTML-sensitive characters' {
            ConvertTo-HtmlEncoded -Value '<a href="x">&</a>' | Should -Be '&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;'
        }

        It 'returns empty string for empty input' {
            ConvertTo-HtmlEncoded -Value '' | Should -Be ''
            ConvertTo-HtmlEncoded -Value $null | Should -Be ''
        }

        It 'leaves plain text unchanged' {
            ConvertTo-HtmlEncoded -Value 'plain 42' | Should -Be 'plain 42'
        }
    }

    Describe 'New-TestFile' {
        BeforeAll {
            $script:testFile = Join-Path $script:testRoot 'speed_test.bin'
        }

        It 'creates a file of the requested size' -Skip:(-not $script:isWindows) {
            New-TestFile -Path $script:testFile -SizeBytes 1048576
            Test-Path $script:testFile | Should -BeTrue
            (Get-Item $script:testFile).Length | Should -Be 1048576
        }

        It 'removes an existing file before creating a new one' -Skip:(-not $script:isWindows) {
            Set-Content -Path $script:testFile -Value 'stale'
            New-TestFile -Path $script:testFile -SizeBytes 2048
            (Get-Item $script:testFile).Length | Should -Be 2048
        }
    }
}
