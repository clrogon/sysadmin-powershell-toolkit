# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Modules now have proper `.psd1` manifests (`modules/Configuration.psd1`, `modules/Logging.psd1`, `modules/ErrorHandling.psd1`) with `RootModule`, version 3.0.0, full `FunctionsToExport`
- Pester tests for the individual scripts via a new AST-extraction helper (`tests/Import-ScriptFunctions.ps1`): `Find-DuplicateFiles`, `Find-EmptyFolders`, `Measure-TransferSpeed`, `DeploymentScript`, `Show-Notification`, `RebootReminder`, `ClearTeamsCache` (45 tests added; suite now 65 tests, run on Ubuntu + Windows in CI)
- Test coverage extended to the remaining untested scripts: `RebootReminder-Detection`, `RebootReminder-Remediation`, `USBPortManagement`, `signing/Sign-Scripts` (44 tests added; suite now 109 tests). USB policy/schedule/whitelist decision logic and event/disk mapping are tested via mocked `Test-Path`/`Import-Clixml`/`Get-Date`/`Get-WinEvent`/`Get-CimInstance`, keeping the suite admin-free and cross-platform
- `RebootReminder-Detection.ps1` gained a `Test-RebootCompliance` function (pure uptime-vs-limit check extracted from the main block) so its decision logic is unit-testable; Intune exit-code behaviour is unchanged
- Removed superseded `CONTRIBUTING_OLD.md` (fully replaced by `CONTRIBUTING.md`)

### Fixed
- `Write-ScriptLog` no longer leaks its structured log entry into the caller's pipeline by default (use `-PassThru` to capture it). Bare `Write-ScriptLog` calls inside data-returning functions previously polluted return values - e.g. `Find-DuplicateFiles` returned log-entry objects mixed with real duplicates, which its own `Resolve-DuplicatesIntelligently` step then processed
- `Find-EmptyFolders.ps1`: `Remove-EmptyFolders` and the script param block collided on a manual `[switch]$WhatIf` plus `[CmdletBinding(SupportsShouldProcess)]` (`ParameterNameAlreadyExistsForCommand` at invocation); now a plain `[CmdletBinding()]` with the manual switch, matching the documented convention in `PSScriptAnalyzerSettings.psd1`
- Removed genuinely dead parameters flagged by `PSReviewUnusedParameter`: `TimeoutSeconds` (`Test-NetworkConnectivity`); `resolutionStrategy` and `MovePath` (function-level in `Find-DuplicateFiles.ps1`); `TargetDir` (`Generate-DuplicateReport`); `MSIPath` (`Deploy-SoftwareToComputer`); `software` (DeploymentScript toast scriptblock). Remaining analyzer findings in this rule are documented false positives (script-level params used across functions, `$using:` refs) - see `PSScriptAnalyzerSettings.psd1`

## [3.0.0] - 2026-08-14

### Changed
- Repository renamed to **sysadmin-powershell-toolkit**; remote updated to `github.com/clrogon/sysadmin-powershell-toolkit`, default branch `main`
- Framework contract simplified: scripts import only `ErrorHandling.psm1`, which re-exports Configuration + Logging + Error Handling
- Configuration state moved to `$global:ScriptConfiguration` so nested `Import-Module -Force` instances share state
- `Test-AdministrativePrivileges` now cross-platform via `RuntimeInformation` (was WindowsIdentity-only)
- `Register-EventLogSource` guards for the missing `System.Diagnostics.EventLog` type on Linux
- Encoding normalized: all `.ps1`/`.psm1` files re-encoded to UTF-8 with BOM; mojibake in `RebootReminder.ps1` repaired

### Added
- Pester test suite: `tests/Configuration.Tests.ps1`, `tests/Logging.Tests.ps1`, `tests/ErrorHandling.Tests.ps1` (18 tests)
- GitHub Actions CI (`.github/workflows/ci.yml`): parse check, PSScriptAnalyzer (Warning+ fails), Pester — matrix Ubuntu + Windows
- `PSScriptAnalyzerSettings.psd1`: rule whitelist with documented exclusions for repo-wide conventions
- `.gitignore` exception so `PSScriptAnalyzerSettings.psd1` is committed

### Security
- All analyzer findings fixed: empty catch blocks, auto-var renames, `$null -eq` comparisons, positional Write-Host

## [2.0] - 2026-01-07

### Security 🔒
- **Critical Security Fixes**: Comprehensive security audit and remediation across all scripts
- **DeploymentScript.ps1**:
  - Removed hardcoded personal paths, now parameterized
  - Fixed WMI injection vulnerability with proper sanitization
  - Implemented HTTPS-only URL validation
  - Enabled all previously disabled security checks
  - Switched to Get-CimInstance with parameterized queries
- **Find-DuplicateFiles.ps1**:
  - Changed default hash algorithm from MD5 to SHA256
  - Added path traversal protection
  - Implemented file extension validation
  - Added comprehensive input sanitization
- **RebootReminder.ps1**:
  - Added strict alphanumeric-only validation for registry operations
  - Implemented dangerous command pattern blocking
  - Added script content length limits
  - Enhanced ActionName sanitization
- **USBPortManagement.ps1**:
  - Made username logging optional via `-LogUserActions` parameter
  - Default privacy-first configuration (no username logging)
  - Enhanced parameter documentation
- **Show-Notification.ps1**:
  - Added XML entity escaping for all user inputs
  - Implemented image path validation
  - Added file extension whitelist validation
  - Enhanced XSS protection
- **Measure-TransferSpeed.ps1**:
  - Added Credential parameter for secure network access
  - Implemented PSDrive support for authenticated connections
  - Added server name validation
  - Enhanced network security

### Documentation 📚
- Added comprehensive **SECURITY.md** file with:
  - Security policy and guidelines
  - Reporting procedures for security issues
  - Best practices for contributors and users
  - Security audit history
- Updated **README.md** with:
  - Security section highlighting implemented features
  - Link to SECURITY.md
  - Security-first messaging
- Updated individual script READMEs with:
  - Security features documentation
  - Privacy controls information
  - Best practices guidance
- Created **CHANGELOG.md** for tracking all changes

### Added 🆕
- Security audit framework
- Input validation helper functions
- Path sanitization utilities
- XML escaping functions
- Security review checklist for contributors
- Digital signing recommendations

### Changed 🔄
- All scripts now use secure defaults
- Disabled all security bypass modes
- Enhanced error handling without information leakage
- Improved logging for security events

### Fixed 🐛
- WMI injection vulnerability (DeploymentScript.ps1)
- Registry injection vulnerability (RebootReminder.ps1)
- XML injection vulnerability (Show-Notification.ps1)
- Path traversal vulnerabilities (multiple scripts)
- Weak cryptography defaults (Find-DuplicateFiles.ps1)
- Disabled security checks (DeploymentScript.ps1)

## [1.0] - Previous Release

### Initial Scripts
- Reboot Reminder
- Show Balloon Tips
- Find Empty Folders
- Clear MS Teams Cache
- Find Duplicate Files
- Deployment Script
- USB Port and Storage Card Management Tool
- Show-Notification
- Measure Transfer Speed

[Unreleased]: https://github.com/clrogon/sysadmin-powershell-toolkit/compare/v3.0.0...HEAD
[3.0.0]: https://github.com/clrogon/sysadmin-powershell-toolkit/releases/tag/v3.0.0
[2.0]: https://github.com/clrogon/sysadmin-powershell-toolkit/releases/tag/v2.0
