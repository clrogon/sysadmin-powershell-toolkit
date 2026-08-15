<#
.SYNOPSIS
    Finds empty directories and optionally cleans them up.

.DESCRIPTION
    Recursively scans a directory tree for empty folders, with optional smart
    filtering (hidden/system files, minimum age), CSV export, owner analysis,
    and recursive cleanup. When run with -RecursiveCleanup it keeps removing
    newly-emptied parent folders until no empty folder remains.

.EXAMPLE
    .\Find-EmptyFolders.ps1 -FolderPath "C:\TestDirectory" -RecursiveCleanup -WhatIf

.EXAMPLE
    .\Find-EmptyFolders.ps1 -FolderPath "C:\TestDirectory" -MinAgeDays 7 -OutputPath report.csv

.PARAMETER FolderPath
    Directory to scan for empty folders.

.PARAMETER IncludeSystemFiles
    Treat folders containing system files as empty.

.PARAMETER IncludeHiddenFiles
    Treat folders containing hidden files as empty.

.PARAMETER MinAgeDays
    Only consider a folder empty if its last write is at least this old.

.PARAMETER OutputPath
    Path of the CSV report of empty folders.

.PARAMETER RecursiveCleanup
    Remove empty folders (repeat until none remain).

.PARAMETER WhatIf
    Show what would be removed without removing anything.

.PARAMETER Force
    Remove read-only/empty protection as needed.

.PARAMETER ExcludedPaths
    Path fragments to never remove.

.NOTES
    Version: 3.0
    Author: Claudio Gonçalves
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({Test-Path $_ -PathType 'Container'})]
    [string]$FolderPath,

    [switch]$IncludeSystemFiles,
    [switch]$IncludeHiddenFiles,
    [int]$MinAgeDays = 0,
    [string]$OutputPath = ".\empty_folders.csv",
    [switch]$RecursiveCleanup,
    [switch]$WhatIf,
    [switch]$Force,
    [string[]]$ExcludedPaths = @()
)

Import-Module "$PSScriptRoot\..\modules\ErrorHandling.psm1" -Force

Initialize-ScriptConfiguration -DefaultConfig (Get-DefaultConfiguration)
Initialize-Logging -Component "FindEmptyFolders"

function Find-EmptyFolders {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_ -PathType 'Container'})]
        [string]$FolderPath,

        [ValidateSet('Error', 'Verbose')]
        [string]$LogLevel = 'Error'
    )

    $ErrorActionPreference = if ($LogLevel -eq 'Error') { 'Stop' } else { 'Continue' }

    $emptyFolders = @()
    $directories = Get-ChildItem -Path $FolderPath -Recurse -Directory -ErrorAction SilentlyContinue

    $i = 0
    foreach ($dir in $directories) {
        $i++
        Write-Progress -Activity "Scanning directories" -Status "$i of $($directories.Count)" -PercentComplete ($i / $directories.Count * 100)

        try {
            $files = Get-ChildItem -Path $dir.FullName -File -Recurse -ErrorAction SilentlyContinue
            if (-not $files) {
                $emptyFolders += $dir.FullName
                Write-ScriptLog -Level Info -Message "Empty folder: $($dir.FullName)"
            }
        }
        catch {
            Write-ScriptLog -Level Error -Message "Failed to access $($dir.FullName): $($_.Exception.Message)"
        }
    }

    Write-Progress -Activity "Scanning directories" -Completed
    return $emptyFolders
}

function Find-EmptyFoldersSmart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_ -PathType 'Container'})]
        [string]$FolderPath,
        [switch]$IncludeSystemFiles,
        [switch]$IncludeHiddenFiles,
        [int]$MinAgeDays = 0,
        [string]$OutputPath = ".\empty_folders.csv"
    )

    $emptyFolders = @()
    $directories = Get-ChildItem -Path $FolderPath -Recurse -Directory -Force -ErrorAction SilentlyContinue

    $i = 0
    foreach ($dir in $directories) {
        $i++
        Write-Progress -Activity "Scanning directories" -Status "Processing: $($dir.FullName)" `
            -PercentComplete (($i / $directories.Count) * 100)

        $files = Get-ChildItem -Path $dir.FullName -File -Force -ErrorAction SilentlyContinue

        if (-not $IncludeHiddenFiles) {
            $files = @($files) | Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::Hidden) }
        }

        if (-not $IncludeSystemFiles) {
            $files = @($files) | Where-Object { -not $_.Attributes.HasFlag([System.IO.FileAttributes]::System) }
        }

        if ($MinAgeDays -gt 0) {
            $files = @($files) | Where-Object { (Get-Date) - $_.LastWriteTime -gt [TimeSpan]::FromDays($MinAgeDays) }
        }

        if (@($files).Count -eq 0) {
            $emptyFolders += [PSCustomObject]@{
                Path = $dir.FullName
                Created = $dir.CreationTime
                LastModified = $dir.LastWriteTime
                AgeDays = [math]::Round(((Get-Date) - $dir.LastWriteTime).TotalDays, 1)
                Depth = ($dir.FullName -split '\\').Count
            }
        }
    }

    Write-Progress -Activity "Scanning directories" -Completed

    $exportDir = Split-Path -Parent $OutputPath
    if ($exportDir -and -not (Test-Path $exportDir)) {
        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    }

    @($emptyFolders) | Export-Csv -Path $OutputPath -NoTypeInformation
    Write-ScriptLog -Level Info -Message "Found $(@($emptyFolders).Count) empty folders. Report: $OutputPath"

    return @($emptyFolders)
}

function Remove-EmptyFolders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateScript({Test-Path $_ -PathType 'Container'})]
        [string]$FolderPath,
        [switch]$WhatIf,
        [switch]$Force,
        [string[]]$ExcludedPaths = @()
    )

    $totalRemoved = 0
    $skippedCount = 0

    do {
        $changed = $false
        $emptyFolders = Find-EmptyFoldersSmart -FolderPath $FolderPath -IncludeHiddenFiles:$IncludeHiddenFiles -IncludeSystemFiles:$IncludeSystemFiles -MinAgeDays $MinAgeDays

        foreach ($folder in $emptyFolders) {
            $excluded = $false
            foreach ($exclusion in $ExcludedPaths) {
                if ($folder.Path -like "*$exclusion*") {
                    $excluded = $true
                    break
                }
            }

            if ($excluded) {
                $skippedCount++
                Write-ScriptLog -Level Info -Message "Skipping excluded folder: $($folder.Path)"
                continue
            }

            if (-not $WhatIf) {
                try {
                    Remove-Item -Path $folder.Path -Force:$Force -ErrorAction Stop
                    Write-ScriptLog -Level Info -Message "Removed: $($folder.Path)"
                    $totalRemoved++
                    $changed = $true
                }
                catch {
                    Write-ScriptLog -Level Error -Message "Failed to remove $($folder.Path): $($_.Exception.Message)"
                }
            }
        }
    } while ($changed)

    Write-Host "`nCleanup Summary:"
    Write-Host "  Removed: $totalRemoved folders"
    Write-Host "  Skipped: $skippedCount folders"
}

function Get-EmptyFolderOwners {
    [CmdletBinding()]
    param(
        [string]$FolderPath
    )

    $emptyFolders = Find-EmptyFoldersSmart -FolderPath $FolderPath
    $ownerStats = @{}

    foreach ($folder in $emptyFolders) {
        try {
            $acl = Get-Acl $folder.Path
            $owner = $acl.Owner

            if (-not $ownerStats.ContainsKey($owner)) {
                $ownerStats[$owner] = @{
                    Count = 0
                    Folders = @()
                }
            }

            $ownerStats[$owner].Count++
            $ownerStats[$owner].Folders += $folder.Path
        }
        catch {
            Write-ScriptLog -Level Warning -Message "Could not get owner for $($folder.Path)"
        }
    }

    $ownerStats.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{
            Owner = $_.Key
            FolderCount = $_.Value.Count
            Folders = $_.Value.Folders
        }
    } | Sort-Object FolderCount -Descending | Format-Table -AutoSize
}

function Schedule-EmptyFolderCleanup {
    [CmdletBinding()]
    param(
        [string]$FolderPath,
        [TimeSpan]$ScheduleTime = "02:00",
        [ValidateSet('Daily', 'Weekly')]
        [string]$Frequency = 'Weekly'
    )

    $scriptPath = $PSCommandPath

    $trigger = if ($Frequency -eq 'Daily') {
        New-ScheduledTaskTrigger -Daily -At $ScheduleTime
    } else {
        New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $ScheduleTime
    }

    $action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
        -Argument "-ExecutionPolicy Bypass -File `"$scriptPath`" -FolderPath `"$FolderPath`" -RecursiveCleanup"

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd

    Register-ScheduledTask -TaskName "EmptyFolderCleanup" -Trigger $trigger -Action $action -Settings $settings `
        -Description "Clean up empty directories in $FolderPath" -Force | Out-Null

    Write-ScriptLog -Level Info -Message "Scheduled empty folder cleanup: $Frequency at $ScheduleTime"
}

# ---- Main ----

Find-EmptyFoldersSmart -FolderPath $FolderPath -IncludeSystemFiles:$IncludeSystemFiles `
    -IncludeHiddenFiles:$IncludeHiddenFiles -MinAgeDays $MinAgeDays -OutputPath $OutputPath | Out-Null

if ($RecursiveCleanup) {
    Remove-EmptyFolders -FolderPath $FolderPath -WhatIf:$WhatIf -Force:$Force -ExcludedPaths $ExcludedPaths
}

