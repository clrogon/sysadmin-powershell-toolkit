<#
.SYNOPSIS
    Identifies duplicate files in a directory (or across directories) and can
    delete or move the duplicates.

.DESCRIPTION
    Uses SHA256 hashing (configurable) to find duplicate files. Supports
    exclusion lists, CSV export, intelligent resolution strategies, HTML
    reports, and cross-directory comparison.

.EXAMPLE
    .\Find-DuplicateFiles.ps1 -targetDir 'C:\MyFiles' -resolutionStrategy Newest -generateReport

.EXAMPLE
    .\Find-DuplicateFiles.ps1 -targetDir 'C:\MyFiles' -userConfirm 'Delete' -Simulate

.PARAMETER targetDir
    Directory to scan for duplicate files.

.PARAMETER hashAlgorithm
    Hash algorithm used to identify duplicates (SHA256 default).

.PARAMETER exportPath
    Path to the CSV file where the duplicate list is saved.

.PARAMETER excludeDirs
    Directories to exclude from the scan.

.PARAMETER excludeFileTypes
    File extensions to exclude (e.g. @('.tmp', '.log')).

.PARAMETER userConfirm
    Action on duplicates: None, Delete, or Move.

.PARAMETER movePath
    Destination for moved duplicates.

.PARAMETER resolutionStrategy
    Strategy for Resolve-DuplicatesIntelligently: Newest, Largest, MostAccessed, KeepAll.

.PARAMETER reportPath
    Path for the HTML report.

.PARAMETER generateReport
    Generate an HTML report.

.PARAMETER Simulate
    Show what would happen without changing any files.

.NOTES
    Version: 3.0
    Author: Claudio Gonçalves
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$targetDir = (Get-Location).Path,
    [ValidateSet('SHA256', 'SHA1', 'SHA384', 'SHA512', 'MD5')]
    [string]$hashAlgorithm = 'SHA256',
    [string]$exportPath = '.\duplicate_files.csv',
    [array]$excludeDirs = @(),
    [array]$excludeFileTypes = @(),
    [ValidateSet('None', 'Delete', 'Move')]
    [string]$userConfirm = 'None',
    [string]$movePath = 'C:\DuplicateFiles',
    [ValidateSet('Newest', 'Largest', 'MostAccessed', 'KeepAll')]
    [string]$resolutionStrategy = 'Newest',
    [string]$reportPath = '.\DuplicateReport.html',
    [switch]$generateReport,
    [switch]$Simulate
)

Import-Module "$PSScriptRoot\..\modules\ErrorHandling.psm1" -Force

Initialize-ScriptConfiguration -DefaultConfig (Get-DefaultConfiguration)
Initialize-Logging -Component "Find-DuplicateFiles"

function Test-ValidPath {
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    if ($Path -match '\.\.') {
        Write-ScriptLog -Level Warning -Message "Path contains directory traversal sequences: $Path"
        return $false
    }

    try {
        [void][System.IO.Path]::GetFullPath($Path)
        return $true
    }
    catch {
        Write-ScriptLog -Level Warning -Message "Invalid path format: $Path"
        return $false
    }
}

function Test-ValidExtension {
    [CmdletBinding()]
    param([string]$Extension)

    if ([string]::IsNullOrWhiteSpace($Extension)) {
        return $false
    }

    if ($Extension -notmatch '^\.[a-zA-Z0-9]+$') {
        Write-ScriptLog -Level Warning -Message "Invalid file extension: $Extension"
        return $false
    }

    return $true
}

function Get-FileHashValue {
    [CmdletBinding()]
    param(
        [string]$FilePath,
        [string]$Algorithm = 'SHA256'
    )

    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm $Algorithm -ErrorAction Stop
        return $hash.Hash
    }
    catch {
        Write-ScriptLog -Level Warning -Message "Failed to hash $FilePath using ${Algorithm}: $($_.Exception.Message)"
        return $null
    }
}

function Find-DuplicateFiles {
    [CmdletBinding()]
    param (
        [string]$targetDir = (Get-Location).Path,
        [ValidateSet('SHA256', 'SHA1', 'SHA384', 'SHA512', 'MD5')]
        [string]$hashAlgorithm = 'SHA256',
        [string]$exportPath = '.\duplicate_files.csv',
        [array]$excludeDirs = @(),
        [array]$excludeFileTypes = @(),
        [ValidateSet('None', 'Delete', 'Move')]
        [string]$userConfirm = 'None',
        [string]$movePath = 'C:\DuplicateFiles',
        [ValidateSet('Newest', 'Largest', 'MostAccessed', 'KeepAll')]
        [string]$resolutionStrategy = 'Newest',
        [string]$reportPath = '.\DuplicateReport.html',
        [switch]$generateReport,
        [switch]$Simulate
    )

    if (-not (Test-Path $targetDir)) {
        Write-ScriptLog -Level Error -Message "Target directory not found: $targetDir"
        return
    }

    if (-not (Test-ValidPath -Path $targetDir)) {
        Write-ScriptLog -Level Error -Message "Invalid target directory path: $targetDir"
        return
    }

    $targetDir = (Resolve-Path -Path $targetDir -ErrorAction Stop).Path

    if ($userConfirm -eq 'Move' -and -not (Test-Path $movePath)) {
        try {
            New-Item -ItemType Directory -Path $movePath -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-ScriptLog -Level Error -Message "Could not create move path '$movePath': $($_.Exception.Message)"
            return
        }
    }

    foreach ($ext in $excludeFileTypes) {
        if (-not (Test-ValidExtension -Extension $ext)) {
            Write-ScriptLog -Level Error -Message "Invalid file extension in exclusion list: $ext"
            return
        }
    }

    $confirmAll = $false
    $hashTable = @{}
    $duplicates = @()

    Write-ScriptLog -Level Info -Message "Scanning $targetDir with $hashAlgorithm"

    $files = Get-ChildItem -Path $targetDir -Recurse -File -ErrorAction SilentlyContinue

    foreach ($file in $files) {
        if ($excludeDirs -contains $file.DirectoryName -or $excludeFileTypes -contains $file.Extension) {
            continue
        }

        $hashValue = Get-FileHashValue -FilePath $file.FullName -Algorithm $hashAlgorithm
        if ($null -eq $hashValue) {
            continue
        }

        if ($hashTable.ContainsKey($hashValue)) {
            $original = $hashTable[$hashValue]
            $duplicateObject = [PSCustomObject]@{
                Original = $original
                Duplicate = $file.FullName
            }

            $duplicates += $duplicateObject
            Write-ScriptLog -Level Info -Message "Duplicate found: $($file.FullName) is a duplicate of $original"

            if ($userConfirm -eq 'Delete' -or $userConfirm -eq 'Move') {
                $confirm = if ($confirmAll) { 'y' } else {
                    do {
                        $confirm = Read-Host "Confirm action ($userConfirm) on duplicate $($file.FullName)? (y/n/a for all)"
                    } until ($confirm -eq 'y' -or $confirm -eq 'n' -or $confirm -eq 'a')

                    if ($confirm -eq 'a') { $confirmAll = $true }
                    $confirm
                }

                if ($confirm -eq 'y' -or $confirmAll) {
                    if ($Simulate) {
                        Write-ScriptLog -Level Info -Message "[SIMULATE] Would $userConfirm $($file.FullName)"
                    }
                    elseif ($userConfirm -eq 'Delete') {
                        Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
                        Write-ScriptLog -Level Info -Message "Duplicate deleted: $($file.FullName)"
                    }
                    elseif ($userConfirm -eq 'Move') {
                        Move-Item -Path $file.FullName -Destination $movePath -Force -ErrorAction SilentlyContinue
                        Write-ScriptLog -Level Info -Message "Duplicate moved: $($file.FullName) to $movePath"
                    }
                }
            }
        }
        else {
            $hashTable[$hashValue] = $file.FullName
        }
    }

    $exportDir = Split-Path -Parent $exportPath
    if ($exportDir -and -not (Test-Path $exportDir)) {
        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    }

    if ($duplicates.Count -gt 0) {
        $duplicates | Export-Csv -Path $exportPath -NoTypeInformation
        Write-ScriptLog -Level Info -Message "Exported $($duplicates.Count) duplicates to $exportPath"
    }
    else {
        Write-ScriptLog -Level Info -Message "No duplicates found in $targetDir"
    }

    if ($generateReport) {
        Generate-DuplicateReport -Duplicates $duplicates -ReportPath $reportPath -TargetDir $targetDir
    }

    return $duplicates
}

function Get-FileAccessCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Security'
            ID = 4663, 4656, 4658
            StartTime = (Get-Date).AddDays(-30)
        } -ErrorAction SilentlyContinue | Where-Object {
            $_.Message -like "*$FilePath*"
        }

        return @($events).Count
    }
    catch {
        return 0
    }
}

function Resolve-DuplicatesIntelligently {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject[]]$Duplicates,
        [ValidateSet('Newest', 'Largest', 'MostAccessed', 'KeepAll')]
        [string]$ResolutionStrategy = 'Newest',
        [switch]$Simulate,
        [string]$MovePath = 'C:\DuplicateFiles'
    )

    $resolvedCount = 0
    $skippedCount = 0

    if ($ResolutionStrategy -eq 'KeepAll') {
        Write-ScriptLog -Level Info -Message "KeepAll strategy selected; no files will be removed."
        return
    }

    foreach ($dup in $Duplicates) {
        try {
            $originalInfo = Get-Item $dup.Original -ErrorAction Stop
            $duplicateInfo = Get-Item $dup.Duplicate -ErrorAction Stop

            $keep = $null
            $remove = $null

            switch ($ResolutionStrategy) {
                'Newest' {
                    if ($duplicateInfo.LastWriteTime -gt $originalInfo.LastWriteTime) {
                        $keep = $dup.Duplicate
                        $remove = $dup.Original
                    } else {
                        $keep = $dup.Original
                        $remove = $dup.Duplicate
                    }
                }
                'Largest' {
                    if ($duplicateInfo.Length -gt $originalInfo.Length) {
                        $keep = $dup.Duplicate
                        $remove = $dup.Original
                    } else {
                        $keep = $dup.Original
                        $remove = $dup.Duplicate
                    }
                }
                'MostAccessed' {
                    $origAccessed = Get-FileAccessCount -FilePath $dup.Original
                    $dupAccessed = Get-FileAccessCount -FilePath $dup.Duplicate

                    if ($dupAccessed -gt $origAccessed) {
                        $keep = $dup.Duplicate
                        $remove = $dup.Original
                    } else {
                        $keep = $dup.Original
                        $remove = $dup.Duplicate
                    }
                }
            }

            $action = if ($Simulate) { "[SIMULATE] " } else { "" }
            Write-Host "$($action)Keeping: $keep"
            Write-Host "$($action)Removing: $remove"

            if (-not $Simulate) {
                Remove-Item $remove -Force -ErrorAction Stop
                Write-ScriptLog -Level Info -Message "Removed duplicate: $remove (kept: $keep) - Strategy: $ResolutionStrategy"
            }
            $resolvedCount++
        }
        catch {
            Write-ScriptLog -Level Warning -Message "Failed to process duplicate pair: $($_.Exception.Message)"
            $skippedCount++
        }
    }

    Write-Host "`nResolution Summary:"
    Write-Host "  Resolved: $resolvedCount files"
    Write-Host "  Skipped: $skippedCount files"
}

function ConvertTo-HtmlEncoded {
    [CmdletBinding()]
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) {
        return ''
    }

    return $Value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
}

function Generate-DuplicateReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject[]]$Duplicates,
        [Parameter(Mandatory=$true)]
        [string]$ReportPath,
        [string]$TargetDir
    )

    $totalDuplicates = @($Duplicates).Count
    $totalSizeSaved = (@($Duplicates) | ForEach-Object {
        try {
            (Get-Item $_.Duplicate -ErrorAction SilentlyContinue).Length
        } catch { 0 }
    } | Measure-Object -Sum).Sum

    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Duplicate Files Report</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background: #f5f5f5; }
        .container { background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); max-width: 1200px; margin: 0 auto; }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 20px; border-radius: 8px 8px 0 0; margin: -30px -30px 30px -30px; }
        .summary { background: #f8f9fa; padding: 20px; border-radius: 8px; margin: 20px 0; }
        .summary-card { display: inline-block; margin: 10px 20px; padding: 15px; background: white; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .summary-value { font-size: 28px; font-weight: bold; color: #667eea; }
        .summary-label { font-size: 14px; color: #666; margin-top: 5px; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 12px; text-align: left; }
        th { background: #667eea; color: white; font-weight: 600; }
        tr:nth-child(even) { background: #f9f9f9; }
        tr:hover { background: #f0f0f0; }
        .badge { padding: 4px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; }
        .badge-danger { background: #dc3545; color: white; }
        .badge-warning { background: #ffc107; color: black; }
        .timestamp { color: #666; font-size: 12px; font-style: italic; }
        .highlight { background: #fff3cd; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Duplicate Files Report</h1>
            <p class="timestamp">Generated: $(Get-Date)</p>
        </div>

        <div class="summary">
            <div class="summary-card">
                <div class="summary-value">$totalDuplicates</div>
                <div class="summary-label">Total Duplicates</div>
            </div>
            <div class="summary-card">
                <div class="summary-value">$([math]::Round($totalSizeSaved/1GB, 2)) GB</div>
                <div class="summary-label">Potential Space Saved</div>
            </div>
            <div class="summary-card">
                <div class="summary-value">$([math]::Round($totalSizeSaved/1MB, 2)) MB</div>
                <div class="summary-label">Total Size (MB)</div>
            </div>
        </div>

        <h2>Duplicate Files (Top 100)</h2>
        <table>
            <tr>
                <th>Original File</th>
                <th>Duplicate File</th>
                <th>Size (MB)</th>
                <th>Hash Preview</th>
            </tr>
"@

    $displayDuplicates = @($Duplicates | Select-Object -First 100)

    foreach ($dup in $displayDuplicates) {
        try {
            $sizeMB = [math]::Round((Get-Item $dup.Duplicate -ErrorAction SilentlyContinue).Length/1MB, 2)
            $hash = Get-FileHashValue -FilePath $dup.Original -Algorithm 'SHA256'
            $hashPreview = if ($hash) { $hash.Substring(0, [math]::Min(16, $hash.Length)) } else { "N/A" }

            $badgeClass = if ($sizeMB -gt 100) { 'badge-danger' } elseif ($sizeMB -gt 10) { 'badge-warning' } else { '' }
            $badge = if ($badgeClass) { "<span class='badge $badgeClass'>Large</span>" } else { '' }

            $origEncoded = ConvertTo-HtmlEncoded -Value $dup.Original
            $dupEncoded = ConvertTo-HtmlEncoded -Value $dup.Duplicate
            $hashEncoded = ConvertTo-HtmlEncoded -Value $hashPreview

            $html += @"
            <tr class="highlight">
                <td style="word-break: break-all;">$origEncoded</td>
                <td style="word-break: break-all;">$dupEncoded</td>
                <td>$sizeMB $badge</td>
                <td style="font-family: monospace;">$hashEncoded...</td>
            </tr>
"@
        }
        catch {
            $html += @"
            <tr>
                <td colspan="4" style="color: red;">Error processing file: $(ConvertTo-HtmlEncoded -Value $_.Exception.Message)</td>
            </tr>
"@
        }
    }

    $html += @"
        </table>
        <p class="timestamp"><em>Showing first 100 duplicates of $totalDuplicates total</em></p>
    </div>
</body>
</html>
"@

    $html | Out-File -FilePath $ReportPath -Force -Encoding UTF8
    Write-ScriptLog -Level Info -Message "Report generated: $ReportPath"
}

function Compare-MultipleDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$Directories,
        [string]$ExportPath = ".\cross_directory_duplicates.csv"
    )

    $hashTable = @{}
    $crossDirectoryDuplicates = @()

    $index = 0
    foreach ($dir in $Directories) {
        $index++
        Write-Progress -Activity "Scanning directories" -Status "Processing: $dir" `
            -PercentComplete (($index / $Directories.Count) * 100)

        if (-not (Test-Path $dir)) {
            Write-ScriptLog -Level Warning -Message "Directory not found, skipping: $dir"
            continue
        }

        $files = Get-ChildItem -Path $dir -Recurse -File -ErrorAction SilentlyContinue

        foreach ($file in $files) {
            try {
                $hash = Get-FileHashValue -FilePath $file.FullName -Algorithm 'SHA256'

                if ($hash -and $hashTable.ContainsKey($hash)) {
                    $existing = $hashTable[$hash]
                    if ($existing.Directory -ne $dir) {
                        $crossDirectoryDuplicates += [PSCustomObject]@{
                            Original = $existing.FullPath
                            Duplicate = $file.FullName
                            OriginalDir = $existing.Directory
                            DuplicateDir = $dir
                            Hash = $hash
                            SizeMB = [math]::Round($file.Length/1MB, 2)
                        }
                    }
                }
                elseif ($hash) {
                    $hashTable[$hash] = @{
                        FullPath = $file.FullName
                        Directory = $dir
                    }
                }
            }
            catch {
                Write-ScriptLog -Level Warning -Message "Failed to hash $($file.FullName): $($_.Exception.Message)"
            }
        }
    }

    Write-Progress -Activity "Scanning directories" -Completed

    $crossDirectoryDuplicates | Export-Csv -Path $ExportPath -NoTypeInformation
    Write-Host "Found $($crossDirectoryDuplicates.Count) cross-directory duplicates"
    Write-Host "Report saved to: $ExportPath"

    return $crossDirectoryDuplicates
}

function Analyze-DuplicatesByFileType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject[]]$Duplicates
    )

    $fileTypeStats = @{}

    foreach ($dup in $Duplicates) {
        try {
            $ext = [System.IO.Path]::GetExtension($dup.Duplicate)
            $size = (Get-Item $dup.Duplicate -ErrorAction SilentlyContinue).Length

            if (-not $fileTypeStats.ContainsKey($ext)) {
                $fileTypeStats[$ext] = @{
                    Count = 0
                    TotalSize = 0
                }
            }

            $fileTypeStats[$ext].Count++
            $fileTypeStats[$ext].TotalSize += $size
        }
        catch {
            Write-Debug "Could not inspect file '$($file.FullName)': $($_.Exception.Message)"
        }
    }

    $fileTypeStats.GetEnumerator() | ForEach-Object {
        [PSCustomObject]@{
            FileType = $_.Key
            Count = $_.Value.Count
            TotalSizeMB = [math]::Round($_.Value.TotalSize/1MB, 2)
            AvgSizeMB = if ($_.Value.Count -gt 0) { [math]::Round($_.Value.TotalSize/1MB/$_.Value.Count, 2) } else { 0 }
        }
    } | Sort-Object TotalSizeMB -Descending | Format-Table -AutoSize
}

# ---- Main ----

$duplicates = Find-DuplicateFiles -targetDir $targetDir -hashAlgorithm $hashAlgorithm `
    -exportPath $exportPath -excludeDirs $excludeDirs -excludeFileTypes $excludeFileTypes `
    -userConfirm $userConfirm -movePath $movePath -resolutionStrategy $resolutionStrategy `
    -reportPath $reportPath -generateReport:$generateReport -Simulate:$Simulate

if ($duplicates.Count -gt 0 -and $PSBoundParameters.ContainsKey('resolutionStrategy')) {
    Resolve-DuplicatesIntelligently -Duplicates $duplicates -ResolutionStrategy $resolutionStrategy -Simulate:$Simulate
}
