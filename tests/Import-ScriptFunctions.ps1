# Helper for script-level tests: extracts every function definition from a
# script file into the current scope WITHOUT executing the script's top-level
# (Main) code. The scripts in this repo auto-run their main logic on dot-source,
# so this AST-based extraction is the only safe way to unit-test their functions.
#
# Usage (dot-source from a test file):
#   . (Join-Path $PSScriptRoot 'Import-ScriptFunctions.ps1') -ScriptPath (Join-Path $PSScriptRoot '..\FindEmptyFolders\Find-EmptyFolders.ps1')
#
# The script path may be absolute or relative to the tests\ directory.
# Existing framework imports (modules\ErrorHandling) remain untouched.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath
)

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    $candidate = Join-Path $PSScriptRoot $ScriptPath
    if (-not (Test-Path -LiteralPath $candidate)) {
        throw "Script file not found: '$ScriptPath' (also tried '$candidate')."
    }
    $ScriptPath = $candidate
}

$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $ScriptPath),
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "Failed to parse '$ScriptPath': $($parseErrors[0].Message)"
}

$functions = $scriptAst.FindAll(
    { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
    $true
)

if ($functions.Count -eq 0) {
    throw "No function definitions found in '$ScriptPath'."
}

foreach ($function in $functions) {
    . ([scriptblock]::Create($function.Extent.Text))
}
