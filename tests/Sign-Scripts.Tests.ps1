# Requires Pester

Describe 'Sign-Scripts.ps1' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\signing\Sign-Scripts.ps1')
    }

    Describe 'Get-CertFromThumb' {
        It 'returns null for an empty thumbprint' {
            Get-CertFromThumb -tp '' | Should -BeNullOrEmpty
        }

        It 'returns null for a whitespace-only thumbprint' {
            Get-CertFromThumb -tp '   ' | Should -BeNullOrEmpty
        }

        It 'returns null when the certificate is not found' {
            Mock Get-ChildItem { throw 'Certificate not found' } -ParameterFilter { $Path -like 'Cert:\*' }
            Get-CertFromThumb -tp 'DEADBEEF1234' | Should -BeNullOrEmpty
        }

        It 'returns the certificate when found in the store' {
            $fakeCert = [PSCustomObject]@{ Thumbprint = 'ABCDEF123456' }
            Mock Get-ChildItem { $fakeCert } -ParameterFilter { $Path -like 'Cert:\*' }
            $cert = Get-CertFromThumb -tp 'ABCDEF123456'
            $cert.Thumbprint | Should -Be 'ABCDEF123456'
        }
    }
}
