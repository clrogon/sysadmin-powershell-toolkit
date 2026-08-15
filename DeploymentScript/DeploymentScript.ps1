<#
.SYNOPSIS
    Automated software deployment script (MSI over WinRM).

.DESCRIPTION
    Deploys an MSI installer to a list of computers or through a staged
    deployment pipeline (Pilot → Phase1 → Phase2 → Production). Includes
    prerequisite checks, HTTPS-only downloads with optional SHA256 verification,
    rollback, a deployment dashboard, and unified logging.

.PARAMETER msiFilePath
    Local path to the MSI installer. Either this or -installerUrl is required.

.PARAMETER installerUrl
    HTTPS URL to download the MSI installer when no local file is supplied.
    Only HTTPS is accepted.

.PARAMETER installerHash
    Optional SHA256 hash of the installer. When downloading, the file hash is
    verified against this value and the deployment is aborted on mismatch.

.PARAMETER installerPath
    Temporary path on the remote machines where the installer is copied.

.PARAMETER logPath
    Path for the deployment log.

.PARAMETER computers
    Array of target computer names for classic (non-staged) deployment.

.PARAMETER stagedDeployment
    Use the staged deployment pipeline (Pilot → Production). This is the
    default when no -computers list is supplied.

.PARAMETER Rollback
    Roll back a deployment by its -DeploymentID.

.PARAMETER DeploymentID
    Identifier of the deployment to roll back (used with -Rollback).

.PARAMETER Dashboard
    Show the deployment dashboard and exit.

.EXAMPLE
    .\DeploymentScript.ps1 -msiFilePath "C:\Temp\app.msi" -computers PC-01,PC-02

.EXAMPLE
    .\DeploymentScript.ps1 -installerUrl "https://example.com/app.msi" -installerHash "A1B2..." -stagedDeployment

.NOTES
    Prerequisites: PowerShell 5.1, administrative privileges, WinRM access to targets.
    Version: 3.0
    Author: Claudio Gonçalves
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$msiFilePath,
    [string]$installerUrl,
    [string]$installerHash,
    [string]$installerPath,
    [string]$logPath = "$env:ProgramData\PowerShellScripts\Logs\DeploymentScript.log",
    [array]$computers = @(),
    [switch]$stagedDeployment,
    [switch]$Rollback,
    [string]$DeploymentID,
    [switch]$Dashboard
)

Import-Module "$PSScriptRoot\..\modules\ErrorHandling.psm1" -Force

Initialize-ScriptConfiguration -DefaultConfig (Get-DefaultConfiguration)
Initialize-Logging -Component "DeploymentScript" -LogPath $logPath

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "This script requires PowerShell 5 or higher."
    exit 1
}

$script:credential = $null
$script:productCode = $null

function Get-MsiProductCode {
    [CmdletBinding()]
    param([string]$Path)

    try {
        $windowsInstaller = New-Object -ComObject WindowsInstaller.Installer
        $database = $windowsInstaller.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $null, $windowsInstaller, @($Path, 0))
        $view = $database.GetType().InvokeMember("OpenView", "InvokeMethod", $null, $database, @("SELECT `Value` FROM `Property` WHERE `Property` = 'ProductCode'"))
        $view.GetType().InvokeMember("Execute", "InvokeMethod", $null, $view, $null)

        $record = $view.GetType().InvokeMember("Fetch", "InvokeMethod", $null, $view, $null)
        $productCode = $record.GetType().InvokeMember("StringData", "GetProperty", $null, $record, 1)

        return $productCode
    }
    catch {
        Write-ScriptLog -Level Error -Message "Failed to read product code from '$Path': $($_.Exception.Message)"
        return $null
    }
}

function Validate-Url {
    [CmdletBinding()]
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        Write-ScriptLog -Level Warning -Message "URL is empty or null."
        return $false
    }

    if ($Url -notmatch '^https://') {
        Write-ScriptLog -Level Warning -Message "URL must use HTTPS protocol: $Url"
        return $false
    }

    try {
        $uri = [System.Uri]$Url
        if (-not $uri.IsWellFormedOriginalString()) {
            Write-ScriptLog -Level Warning -Message "URL format is invalid: $Url"
            return $false
        }
    }
    catch {
        Write-ScriptLog -Level Warning -Message "URL validation failed: $($_.Exception.Message)"
        return $false
    }

    return $true
}

function Get-InstallerFile {
    [CmdletBinding()]
    param(
        [string]$MsiFilePath,
        [string]$InstallerUrl,
        [string]$ExpectedHash
    )

    if ($MsiFilePath -and (Test-Path $MsiFilePath)) {
        return $MsiFilePath
    }

    if (-not $InstallerUrl) {
        throw "No MSI file was found at '$MsiFilePath' and no -installerUrl was provided."
    }

    if (-not (Validate-Url $InstallerUrl)) {
        throw "Installer URL is not valid or secure: $InstallerUrl"
    }

    $downloadPath = Join-Path $env:TEMP 'DeploymentScript-installer.msi'
    Write-ScriptLog -Level Info -Message "Downloading installer from $InstallerUrl"

    Invoke-WebRequest -Uri $InstallerUrl -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop

    if ($ExpectedHash) {
        $actualHash = (Get-FileHash -Path $downloadPath -Algorithm SHA256).Hash
        if ($actualHash -ne $ExpectedHash.ToUpper()) {
            Remove-Item $downloadPath -Force -ErrorAction SilentlyContinue
            throw "Downloaded file hash ($actualHash) does not match expected hash ($ExpectedHash). Aborting."
        }
        Write-ScriptLog -Level Info -Message "Downloaded file verified (SHA256 match)."
    }
    else {
        Write-ScriptLog -Level Warning -Message "No -installerHash provided; downloaded installer was not verified."
    }

    return $downloadPath
}

function Invoke-RemoteOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$ComputerName,
        [PSCredential]$Credential,
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList
    )

    $params = @{
        ComputerName = $ComputerName
        ScriptBlock  = $ScriptBlock
    }

    if ($Credential) { $params.Credential = $Credential }
    if ($ArgumentList) { $params.ArgumentList = $ArgumentList }

    Invoke-Command @params
}

function Test-SoftwareInstalled {
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [string]$ProductCode
    )

    try {
        $sanitizedCode = $ProductCode -replace '[^\{\}0-9A-Fa-f\-]', ''

        $installed = Invoke-RemoteOperation -ComputerName $ComputerName -Credential $script:credential -ScriptBlock {
            param($code)
            Get-CimInstance -ClassName Win32_Product -Filter "IdentifyingNumber = '$code'" -ErrorAction SilentlyContinue
        } -ArgumentList @($sanitizedCode) -ErrorAction Stop

        return ($null -ne $installed)
    }
    catch {
        return $false
    }
}

function Install-SoftwareOnComputer {
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [string]$InstallerUrl,
        [string]$InstallerPath
    )

    Invoke-RemoteOperation -ComputerName $ComputerName -Credential $script:credential -ScriptBlock {
        param($url, $path)
        Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing -ErrorAction Stop
        Start-Process "msiexec.exe" -ArgumentList "/i `"$path`" /qn /L*v `"$env:TEMP\deployment-install.log`"" -Wait -ErrorAction Stop
    } -ArgumentList @($InstallerUrl, $InstallerPath) -ErrorAction Stop
}

function Deploy-SoftwareToComputer {
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [string]$ProductCode,
        [string]$InstallerUrl,
        [string]$InstallerPath
    )

    $result = [PSCustomObject]@{
        ComputerName = $ComputerName
        Success = $false
        Error = $null
        Installed = $false
    }

    try {
        if (-not (Test-SoftwareInstalled -ComputerName $ComputerName -ProductCode $ProductCode)) {
            Install-SoftwareOnComputer -ComputerName $ComputerName -InstallerUrl $InstallerUrl -InstallerPath $InstallerPath
            $result.Installed = $true
        }

        $result.Success = $true
        Write-ScriptLog -Level Info -Message "Deployment completed on ${ComputerName}"
    }
    catch {
        $result.Error = $_.Exception.Message
        Write-ScriptLog -Level Error -Message "Error on ${ComputerName}: $($_.Exception.Message)"
    }

    return $result
}

function Test-DeploymentPrerequisites {
    [CmdletBinding()]
    param(
        [string[]]$Computers,
        [string]$MSIPath,
        [int]$RequiredDiskSpaceGB = 1
    )

    $productCode = Get-MsiProductCode -Path $MSIPath
    $validationResults = @()

    foreach ($computer in $Computers) {
        $validation = [PSCustomObject]@{
            ComputerName       = $computer
            Online             = $false
            HasAdminAccess     = $false
            EnoughDiskSpace    = $false
            SoftwareNotInstalled = $true
            Valid              = $false
        }

        if (Test-Connection -ComputerName $computer -Count 1 -Quiet) {
            $validation.Online = $true

            try {
                Invoke-RemoteOperation -ComputerName $computer -Credential $script:credential -ScriptBlock {
                    [Security.Principal.WindowsIdentity]::GetCurrent() | Out-Null
                    $true
                } -ErrorAction Stop | Out-Null
                $validation.HasAdminAccess = $true
            }
            catch {
                Write-Debug "Admin access probe failed for '$computer': $($_.Exception.Message)"
            }

            try {
                $freeSpace = Invoke-RemoteOperation -ComputerName $computer -Credential $script:credential -ScriptBlock {
                    (Get-PSDrive C).Free / 1GB
                } -ErrorAction Stop

                if ($freeSpace -ge $RequiredDiskSpaceGB) {
                    $validation.EnoughDiskSpace = $true
                }
            }
            catch {
                Write-Debug "Disk space probe failed for '$computer': $($_.Exception.Message)"
            }

            try {
                if ($productCode -and (Test-SoftwareInstalled -ComputerName $computer -ProductCode $productCode)) {
                    $validation.SoftwareNotInstalled = $false
                }
            }
            catch {
                Write-Debug "Software check failed for '$computer': $($_.Exception.Message)"
            }
        }

        $validation.Valid = $validation.Online -and $validation.HasAdminAccess -and $validation.EnoughDiskSpace -and $validation.SoftwareNotInstalled
        $validationResults += $validation
    }

    return $validationResults
}

#region Staged Deployment

$deploymentStages = @(
    @{ Stage = "Pilot";      Computers = @(); Percentage = 5  },
    @{ Stage = "Phase1";     Computers = @(); Percentage = 20 },
    @{ Stage = "Phase2";     Computers = @(); Percentage = 50 },
    @{ Stage = "Production"; Computers = @(); Percentage = 100 }
)

function Invoke-StagedDeployment {
    [CmdletBinding()]
    param(
        [string]$MSIPath,
        [string]$ProductCode,
        [string]$InstallerUrl,
        [string]$InstallerPath,
        [string]$DeploymentID = [Guid]::NewGuid().ToString(),
        [ValidateSet('Pilot', 'Phase1', 'Phase2', 'Production')]
        [string]$StartStage = 'Pilot'
    )

    Start-LogTransaction -TransactionName "Deployment $DeploymentID" -InitialData @{
        MSIPath     = $MSIPath
        ProductCode = $ProductCode
        StartStage  = $StartStage
    }

    $deployment = [PSCustomObject]@{
        DeploymentID = $DeploymentID
        MSIPath = $MSIPath
        ProductCode = $ProductCode
        StartTime = Get-Date
        CurrentStage = $StartStage
        Status = 'InProgress'
        Results = @()
    }

    $stageNames = @($deploymentStages | ForEach-Object { $_.Stage })
    $currentStageIndex = [array]::IndexOf($stageNames, $StartStage)
    if ($currentStageIndex -lt 0) { $currentStageIndex = 0 }

    $allComputers = @()
    if (Get-Command Get-ADComputer -ErrorAction SilentlyContinue) {
        $allComputers = @(Get-ADComputer -Filter { Enabled -eq $true } -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    }

    for ($i = $currentStageIndex; $i -lt $deploymentStages.Count; $i++) {
        $stage = $deploymentStages[$i]

        Add-LogTransactionStep -StepName "Stage: $($stage.Stage)" -StepType "Info"

        $stageComputers = if ($stage.Computers.Count -gt 0) {
            @($stage.Computers)
        } elseif ($allComputers.Count -gt 0) {
            $count = [math]::Floor($allComputers.Count * $stage.Percentage / 100)
            @($allComputers | Get-Random -Count $count)
        } else {
            Write-ScriptLog -Level Warning -Message "No computers available for stage $($stage.Stage); AD module not present or no computers found."
            @()
        }

        $index = 0
        foreach ($computer in $stageComputers) {
            $index++
            Write-Progress -Activity "Stage: $($stage.Stage)" -Status "Deploying to: $computer" `
                -PercentComplete (($index / $stageComputers.Count) * 100)

            $result = Deploy-SoftwareToComputer -ComputerName $computer -ProductCode $ProductCode `
                -InstallerUrl $InstallerUrl -InstallerPath $InstallerPath
            $deployment.Results += $result

            Add-LogTransactionStep -StepName "Deploy to $computer" -StepType $(if ($result.Success) { "Info" } else { "Error" }) `
                -StepData @{ Success = $result.Success; Error = $result.Error }
        }

        if ($deployment.Results.Count -gt 0) {
            $successCount = @($deployment.Results | Where-Object Success).Count
            $successRate = $successCount / $deployment.Results.Count
            $threshold = Get-LoggingConfigValue -Section 'Deployment' -Key 'SuccessThreshold' -Default 0.9

            if ($successRate -lt $threshold) {
                Write-ScriptLog -Level Warning -Message "Success rate below threshold in stage $($stage.Stage). Pausing deployment."
                $deployment.Status = 'Paused'
                break
            }

            if ($i -lt $deploymentStages.Count - 1) {
                $approval = Read-Host "Stage $($stage.Stage) completed ($([math]::Round($successRate*100,1))% success). Approve next stage? (Y/N)"
                if ($approval -ne 'Y') {
                    Write-ScriptLog -Level Info -Message "Deployment paused for approval."
                    $deployment.Status = 'PendingApproval'
                    break
                }
            }
        }
    }

    $deployment.EndTime = Get-Date

    $deploymentPath = "$env:ProgramData\PowerShellScripts\Deployments\$($deployment.DeploymentID).xml"
    $deploymentDir = Split-Path -Parent $deploymentPath
    if (-not (Test-Path $deploymentDir)) {
        New-Item -ItemType Directory -Path $deploymentDir -Force | Out-Null
    }
    $deployment | Export-Clixml $deploymentPath -Force

    Complete-LogTransaction -Status $deployment.Status

    return $deployment
}

function Uninstall-SoftwareFromComputer {
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [string]$ProductCode
    )

    $result = [PSCustomObject]@{
        ComputerName = $ComputerName
        Success = $false
        Error = $null
    }

    try {
        Invoke-RemoteOperation -ComputerName $ComputerName -Credential $script:credential -ScriptBlock {
            param($code)
            $sanitizedCode = $code -replace '[^\{\}0-9A-Fa-f\-]', ''
            $product = Get-CimInstance Win32_Product -Filter "IdentifyingNumber = '$sanitizedCode'" -ErrorAction SilentlyContinue
            if ($product) {
                Start-Process "msiexec.exe" -ArgumentList "/x `"$sanitizedCode`" /qn REBOOT=ReallySuppress" -Wait -ErrorAction Stop
            }
        } -ArgumentList @($ProductCode) -ErrorAction Stop

        $result.Success = $true
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Invoke-Rollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DeploymentID,
        [string]$Reason = "Deployment failed"
    )

    $deploymentPath = "$env:ProgramData\PowerShellScripts\Deployments\$DeploymentID.xml"

    if (-not (Test-Path $deploymentPath)) {
        Write-ScriptLog -Level Error -Message "Deployment not found: $DeploymentID"
        return
    }

    $deployment = Import-Clixml $deploymentPath

    Write-ScriptLog -Level Warning -Message "Rolling back deployment: $DeploymentID ($Reason)"

    foreach ($result in @($deployment.Results | Where-Object Success)) {
        try {
            $uninstallResult = Uninstall-SoftwareFromComputer -ComputerName $result.ComputerName -ProductCode $deployment.ProductCode

            $rollbackEntry = [PSCustomObject]@{
                ComputerName = $result.ComputerName
                RollbackTime = Get-Date
                Success = $uninstallResult.Success
                Error = $uninstallResult.Error
            }

            $rollbackCsv = "$env:ProgramData\PowerShellScripts\Rollback_$DeploymentID.csv"
            $rollbackEntry | Export-Csv $rollbackCsv -Append -NoTypeInformation -ErrorAction SilentlyContinue
        }
        catch {
            Write-ScriptLog -Level Error -Message "Failed to rollback on $($result.ComputerName): $($_.Exception.Message)"
        }
    }

    $deployment.Status = 'RolledBack'
    $deployment.RollbackTime = Get-Date
    $deployment.RollbackReason = $Reason
    $deployment | Export-Clixml $deploymentPath -Force

    Write-ScriptLog -Level Info -Message "Rollback completed"
}

function Show-DeploymentDashboard {
    [CmdletBinding()]
    param(
        [DateTime]$StartDate = (Get-Date).AddDays(-7)
    )

    $deployments = Get-ChildItem "$env:ProgramData\PowerShellScripts\Deployments\*.xml" -ErrorAction SilentlyContinue |
        ForEach-Object { Import-Clixml $_.FullName } |
        Where-Object { $_.StartTime -ge $StartDate }

    Write-Host "=== Deployment Dashboard ===`n"

    foreach ($deployment in $deployments) {
        Write-Host "Deployment: $($deployment.DeploymentID)"
        Write-Host "  Started: $($deployment.StartTime)"
        Write-Host "  Status: $($deployment.Status)"

        if (@($deployment.Results).Count -gt 0) {
            $successCount = @($deployment.Results | Where-Object Success).Count
            $totalComputers = @($deployment.Results).Count
            $successRate = [math]::Round($successCount / $totalComputers * 100, 1)

            Write-Host "  Computers: $totalComputers"
            Write-Host "  Success Rate: $successRate%"
        }

        Write-Host ""
    }

    $totalDeployments = @($deployments).Count
    $successfulDeployments = @($deployments | Where-Object Status -eq 'Completed').Count
    $totalComputers = (($deployments | ForEach-Object { @($_.Results).Count }) | Measure-Object -Sum).Sum

    Write-Host "Summary:"
    Write-Host "  Total Deployments: $totalDeployments"
    Write-Host "  Successful: $successfulDeployments"
    Write-Host "  Total Computers: $totalComputers"
}

function Get-LoggedOnUser {
    [CmdletBinding()]
    param([string]$ComputerName)

    try {
        $computerSystem = Get-CimInstance -ComputerName $ComputerName -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($computerSystem.UserName) {
            return $computerSystem.UserName
        }
    }
    catch {
        Write-Debug "Could not read logged-on user for '$ComputerName': $($_.Exception.Message)"
    }
    return $null
}

function Notify-UsersOfDeployment {
    [CmdletBinding()]
    param(
        [string[]]$ComputerNames,
        [string]$SoftwareName
    )

    foreach ($computer in $ComputerNames) {
        $user = Get-LoggedOnUser -ComputerName $computer

        if (-not $user) {
            Write-ScriptLog -Level Info -Message "No interactive user on ${computer}; skipping notification."
            continue
        }

        Write-ScriptLog -Level Info -Message "Notifying $user on ${computer} about $SoftwareName deployment"

        try {
            Invoke-RemoteOperation -ComputerName $computer -Credential $script:credential -ScriptBlock {
                Add-Type -AssemblyName Windows.UI.Notifications -ErrorAction SilentlyContinue
                $xml = @"
<toast>
    <visual>
        <binding template="ToastGeneric">
            <text>Software Update</text>
            <text>Software will be installed on your computer shortly.</text>
        </binding>
    </visual>
</toast>
"@
                $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
                $doc.LoadXml($xml)
                [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Software Deployment").Show($doc)
            } -ErrorAction SilentlyContinue
        }
        catch {
            Write-ScriptLog -Level Warning -Message "Could not notify $user on ${computer}: $($_.Exception.Message)"
        }
    }
}

#endregion

# ---- Main ----

if ($Rollback) {
    if (-not $DeploymentID) {
        Write-ScriptLog -Level Error -Message "-Rollback requires -DeploymentID."
        exit 1
    }
    Invoke-Rollback -DeploymentID $DeploymentID
    exit 0
}

if ($Dashboard) {
    Show-DeploymentDashboard
    exit 0
}

if (-not (Test-AdministrativePrivileges)) {
    Write-ScriptLog -Level Error -Message "This script requires administrative privileges."
    exit 1
}

try {
    $msiFilePath = Get-InstallerFile -MsiFilePath $msiFilePath -InstallerUrl $installerUrl -ExpectedHash $installerHash
}
catch {
    Write-ScriptLog -Level Error -Message $_.Exception.Message
    exit 1
}

if (-not $installerPath) {
    $installerPath = "C:\Windows\Temp\$(Split-Path $msiFilePath -Leaf)"
}

$script:productCode = Get-MsiProductCode -Path $msiFilePath
if (-not $script:productCode) {
    Write-ScriptLog -Level Error -Message "Failed to retrieve the product code from the MSI file."
    exit 1
}

$useStaged = $stagedDeployment -or $computers.Count -eq 0

if ($useStaged) {
    Write-ScriptLog -Level Info -Message "Starting staged deployment for product $($script:productCode)"
    Invoke-StagedDeployment -MSIPath $msiFilePath -ProductCode $script:productCode `
        -InstallerUrl $installerUrl -InstallerPath $installerPath | Out-Null
    exit 0
}

$script:credential = Get-Credential -Message "Enter credentials for accessing remote machines"

foreach ($computer in $computers) {
    if (-not (Test-Connection -ComputerName $computer -Count 1 -Quiet)) {
        Write-ScriptLog -Level Error -Message "Unable to reach ${computer}. Please check network connectivity."
        continue
    }

    try {
$result = Deploy-SoftwareToComputer -ComputerName $computer `
-ProductCode $script:productCode -InstallerUrl $installerUrl -InstallerPath $installerPath

        if ($result.Success) {
            Write-ScriptLog -Level Info -Message "Installation completed on ${computer}"
        }
        else {
            Write-ScriptLog -Level Error -Message "Installation failed on ${computer}: $($result.Error)"
        }
    }
    catch {
        Write-ScriptLog -Level Error -Message "Error encountered on ${computer}: $($_.Exception.Message)"
    }
}

Write-ScriptLog -Level Info -Message "Deployment run finished for $($computers.Count) computer(s)."
exit 0

