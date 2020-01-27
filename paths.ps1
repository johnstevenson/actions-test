$ErrorActionPreference = 'Stop';

$workDir = Split-Path $MyInvocation.MyCommand.Definition
. $workDir\path-helpers.ps1

# Set global $IsWindows etc if we are in native powershell
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

$appIntro = Initialize-App $workDir $app

# Output intro
Write-Output "Generating PATH report for:"
$out = Get-OutputList $appIntro

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
$data = $pathData | Format-Table -Property Path, Status -AutoSize | Out-String
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
$cmdx = New-Object System.Collections.ArrayList

foreach ($path in $validPaths) {

    if (-not $IsWindows -and $app.UnixNoStat) {
        # Use ls to get file permissions and name
        $cmdx.Clear()
        $lines = ls -l $path

        foreach ($line in $lines) {
            if ($line -match '^[-l].{8}x') {
                $cmdx.Add(($line -split '\s+')[8]) | Out-Null
            }
        }
    }

    $fileList = Get-ChildItem -Path $path -File

    foreach ($file in $fileList) {

        if ($file.BaseName.StartsWith('.') -or $file.BaseName -match '\s') {
            continue
        }

        # We only test the file, rather than any links
        if ($IsWindows) {
            $executable = Test-IsExecutableOnWindows $file $pathExt $app.IsUnixy
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

        $command = $file.BaseName
        $entryAdded = $false

        # Links - only use soft links on Windows
        if ($IsWindows) {
            $followLinks = ($file.LinkType -eq 'SymbolicLink')
        } else {
            $followLinks = ($null -ne $file.LinkType)
        }

        if ($followLinks) {
            foreach ($target in $file.Target) {
                $linkTarget = Get-Item -LiteralPath $target -ErrorAction SilentlyContinue

                if ($linkTarget) {
                    $cmdStats.Duplicates += Add-DataEntry $table $command $linkTarget
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
    $title = "Duplicate commands ($($cmdStats.Duplicates))"

    $data = $table.GetEnumerator() | Sort-Object -Property key |
        Where-Object { $_.Value.Count -gt 1 } | ForEach-Object {
        Format-PathList } | Out-String

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
