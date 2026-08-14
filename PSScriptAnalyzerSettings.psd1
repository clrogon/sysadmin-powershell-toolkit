@{
    # PSScriptAnalyzer settings for sysadmin-powershell-toolkit.
    #
    # CI runs `Invoke-ScriptAnalyzer -Path . -Recurse -Settings PSScriptAnalyzerSettings.psd1`
    # and fails on any finding at Warning severity or above.
    #
    # Whitelist approach: only the rules in IncludeRules are evaluated. Rules that fire
    # thousands of times or encode a deliberate convention are not listed, so CI stays
    # focused on findings that indicate real defects. Each omission is documented below.
    #
    # Deliberately not enforced (with rationale):
    # - PSAvoidUsingWriteHost: the logging framework (Logging.psm1) deliberately writes
    #   console output via Write-Host so every script shares one console renderer.
    #   Forcing each call site through Write-Output would break the shared framework.
    # - PSUseOutputTypeCorrectly: fires at Information severity only. The framework
    #   functions return [PSCustomObject] instances that vary per runtime path, so
    #   declaring a single OutputType is not accurate and adds churn without signal.
    # - PSProvideCommentHelp: Information severity only. Internal helpers in scripts are
    #   self-documenting via parameter names; only exported module functions get help.
    # - PSReviewUnusedParameter: false positives. Script-level parameters (e.g.
    #   RebootReminder -DaysLimit, -NotifyThreshold) are consumed by functions declared
    #   later in the same file, but the analyzer cannot see the cross-function use and
    #   reports them as unused.
    # - PSUseSingularNouns: the tool names are the public surface of this repo
    #   (Find-DuplicateFiles, Remove-EmptyFolders, Clear-TeamsCacheFiles). Renaming them
    #   to satisfy the noun rule would break every documented invocation and scheduled
    #   task that calls them.
    # - PSUseApprovedVerbs: same reason. Established names (Validate-Url,
    #   Ensure-LogFileHeader, Check-LogRotation, Clean-OldLogs, Monitor-USBDeviceEvents)
    #   predate this rule; renaming is a breaking change, not a fix.
    # - PSAvoidGlobalVars: exactly one global exists, $global:ScriptConfiguration in
    #   Configuration.psm1. It is deliberate: Logging.psm1 imports Configuration.psm1
    #   with -Force, which creates a second module instance with empty $script: state, so
    #   the rotation/summary settings would never reach the logging functions. A single
    #   global is the minimal shared-state mechanism across the two instances; all other
    #   state stays module-scoped.
    # - PSUseShouldProcessForStateChangingFunctions / PSUseSupportsShouldProcess: the
    #   repo convention is explicit dry-run/opt-in switches (-Simulate, -Force, manual
    #   [switch]$WhatIf) instead of ShouldProcess. Remove-EmptyFolders deliberately
    #   declares a manual WhatIf switch because it needs a real switch semantic, not the
    #   ShouldProcess machinery. Adding SupportsShouldProcess would require rewriting the
    #   parameter contract.
    # - PSAvoidUsingWMICmdlet: the one finding is Register-WmiEvent in
    #   Monitor-USBDeviceEvents, subscribed to Win32_VolumeChangeEvent. CIM has no
    #   equivalent registration for that event class with the same source-identifier and
    #   action semantics; converting would change monitoring behavior.
    #
    # Enforced rules are the ones that catch genuine defects when violated:
    IncludeRules = @(
        'PSAvoidUsingCmdletAliases',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingEmptyCatchBlock',
        'PSAvoidUsingPositionalParameters',
        'PSAvoidAssignmentToAutomaticVariable',
        'PSPossibleIncorrectComparisonWithNull',
        'PSUseUsingScopeModifierInNewRunspaces',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSUseBOMForUnicodeEncodedFile'
    )
    ExcludeRules = @(
    )
}
