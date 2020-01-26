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
    HasFileStat = $false;
    Powershell = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
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

if ($IsWindows) {
    Set-Alias -Name Test-IsExecutable -Value Test-IsExecutableOnWindows
} else {

    if (-not $app.HasFileStat) {
        $title = 'Commands found in PATH entries'
        $data = "None (Unix file stats not available in Powershell $($app.Powershell))"
        $out = Get-OutputString $data $title
        Write-Output $out
        Add-Content -Path $app.Report -Value $out
        exit 0
    }

    Set-Alias -Name Test-IsExecutable -Value Test-IsExecutableOnUnixy
}

# Get command entries
$cmdStats = [ordered]@{
    Commands = 0;
    Duplicates = 0;
}

$table = @{}
$pathExt = @('.COM', '.EXE', '.BAT', '.CMD')

foreach ($path in $validPaths) {

    $fileList = Get-ChildItem -Path $path -File

    foreach ($file in $fileList) {

        if ($file.BaseName.StartsWith('.') -or $file.BaseName -match '\s') {
            continue
        }

        if (Test-IsExecutable $file $pathExt $app) {
            $cmdStats.Duplicates += Add-DataEntry $table $file
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
$out = $out = Get-OutputString $data $title
Add-Content -Path $app.Report -Value $out
