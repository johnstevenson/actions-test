$ErrorActionPreference = 'Stop';

$workDir = Split-Path $MyInvocation.MyCommand.Definition
. $workDir\path-helpers.ps1

# Set global $IsWindows if we are in native powershell
if ($null -eq $IsWindows) {
    $global:IsWindows = $true;
    $global:IsLinux = $global:IsMacOs = $false
}

$app = @{
    Module = '';
    IsUnixy = $false;
    Powershell = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    UnixHasStat = $false
    UnixNoStat = $false
    Report = '';
}

$appInfo = Initialize-App $workDir $app

# Output intro
Write-Output $app.Report
Write-Output "Generating PATH report for:"
$out = Get-OutputList $appInfo
Set-Content -Path $app.Report -Value $out
Write-Output $out

# Get path entries
$pathStats = [ordered]@{
    Entries = 0;
    Valid = 0
    Missing = 0;
    Duplicates = 0;
}

$pathData = New-Object System.Collections.ArrayList
$validPaths = Get-ValidPaths $pathData $pathStats

# Output path entries
$title = 'Entries in PATH environment'
$out = Get-OutputList $pathStats $title
$data = ($pathData | Format-Table -Property Path, Status -AutoSize | Out-String)
$out += Get-OutputString $data
Add-Content -Path $app.Report -Value $out
Write-Output $out

# Get command entries
$cmdStats = [ordered]@{
    Commands = 0;
    Duplicates = 0;
}

$table = @{}
$pathExt = @('.COM', '.EXE', '.BAT', '.CMD')

foreach ($path in $validPaths) {

    if (-not $IsWindows -and $app.UnixNoStat) {
        $cmdx = @()
        $lines = ls -l $path

        foreach ($line in $lines) {
            if ($line -match '^[-l].{8}x') {
                $cmdx += ($line -split '\s+')[8]
            }
        }
    }

    $fileList = Get-ChildItem -Path $path -File

    foreach ($file in $fileList) {

        if ($file.BaseName.StartsWith('.') -or $file.BaseName -match '\s') {
            continue
        }

        $command = $file.BaseName

        # We only test the file, rather than any links
        if ($IsWindows) {
            $executable = Test-IsExecutableOnWindows $file $pathExt $app
        } else {
            if ($app.UnixHasStat) {
                $executable = $file.UnixMode.EndsWith('x')
            } else {
                $executable = $cmdx.Contains($file.Name)
            }
        }

        if (-not $executable) {
            continue
        }

        # Links - only use soft links if we have any
        $entryAdded = $false

        if ($IsWindows) {
            $followLinks = ($file.LinkType -eq 'SymbolicLink')
        } else {
            $followLinks = ($null -ne $file.LinkType)
        }

        #if ($file.LinkType -eq 'SymbolicLink') {
        if ($followLinks) {
            foreach ($target in $file.Target) {
                $targetFile = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue

                if ($targetFile) {
                    $cmdStats.Duplicates += Add-DataEntry $table $command $targetFile
                    $entryAdded = $true
                }
            }
        }

        if (-not $entryAdded) {
            $cmdStats.Duplicates += Add-DataEntry $table $command $file
        }
    }
}

$cmdStats.Commands = $table.Keys.Count

# Output command entries
$title = 'Commands found in PATH entries'
$out = Get-OutputList $cmdStats $title
Add-Content -Path $app.Report -Value $out
Write-Output $out

# Output command duplicates
if ($cmdStats.Duplicates) {
    $title = $title = "Duplicate commands ($($cmdStats.Duplicates))"
    $data = ($table.GetEnumerator() | Sort-Object -Property key |
        Where-Object { $_.Value.Count -gt 1 } | ForEach-Object {
        Format-PathList } | Out-String)

    $out = Get-OutputString $data $title
    Add-Content -Path $app.Report -Value $out
    Write-Output $out
}

$title = "All commands ($($cmdStats.Commands))"
Write-Output (Get-OutputString "See: $($app.Report)" $title)

# Output all commands to report file
$data = $table.GetEnumerator() | Sort-Object -Property key | ForEach-Object { Format-PathList} | Out-String
$out = Get-OutputString $data $title
Add-Content -Path $app.Report -Value $out
