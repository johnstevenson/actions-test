$ErrorActionPreference = 'Stop';

$workDir = Split-Path $MyInvocation.MyCommand.Definition
. $workDir\path-helpers.ps1

# Set global $IsWindows etc if we are in native powershell
if ($null -eq $IsWindows) {
    $global:IsWindows = $true;
    $global:IsLinux = $global:IsMacOs = $false
}

$app = @{
    pathExt = @('.COM', '.EXE', '.BAT', '.CMD');
    isUnixy = $false;
    unixHasStat = $false
    unixNoStat = $false
    report = '';
}

$appIntro = Initialize-App $workDir $app

# Output intro
Write-Output "Generating PATH report for:"
$out = Get-OutputList $appIntro

Set-Content -Path $app.report -Value $out
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

Add-Content -Path $app.report -Value $out
Write-Output $out

# Get command entries
$cmdStats = [ordered]@{
    Commands = 0;
    Duplicates = 0;
}

$cmdData = Get-PathCommands $validPaths $cmdStats $app

# Output command entries
$title = 'Commands found in PATH entries'
$out = Get-OutputList $cmdStats $title

Add-Content -Path $app.report -Value $out
Write-Output $out

# Output command duplicates
if ($cmdStats.Duplicates) {
    $title = "Duplicate commands ($($cmdStats.Duplicates))"

    $data = $cmdData.GetEnumerator() | Sort-Object -Property key |
        Where-Object { $_.Value.Count -gt 1 } | ForEach-Object {
        Format-PathList } | Out-String

    $out = Get-OutputString $data $title

    Add-Content -Path $app.report -Value $out
    Write-Output $out
}

$title = "All commands ($($cmdStats.Commands))"
Write-Output (Get-OutputString "See: $($app.Report)" $title)

# Output all commands to report file
$data = $cmdData.GetEnumerator() | Sort-Object -Property key |
    ForEach-Object { Format-PathList} | Out-String

$out = Get-OutputString $data $title
Add-Content -Path $app.report -Value $out
