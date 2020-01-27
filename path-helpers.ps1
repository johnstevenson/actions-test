function Add-DataEntry([object]$data, [string]$command, [System.IO.FileInfo]$file) {

    $duplicates = 0
    $key = $command

    if ($IsWindows) {
        $key = $key.ToLower()
    }

    if ($data.Contains($key)) {
        $item = $data.Get_Item($key)

        if ($item.Unique.Contains($file.DirectoryName)) {
            return $duplicates
        }

        ++$item.Count
        $item.Dupes += $file.FullName
        $item.Unique += $file.DirectoryName
        $data.Set_Item($key, $item)
        $duplicates = 1

    } else {
        $value = @{ Path = $file.FullName; Count = 1; Dupes = @(); Unique = @($file.DirectoryName) }
        $data.Add($key, $value)
    }

    return $duplicates
}

function Format-PathList {
    $cmd = $_.Key

    if ($cmd.Length -gt 25) {
        $cmd = $cmd.Substring(0, 22) + "..."
    }

    $format = "{0,-25} {1,-5} {2}"
    $lines = $format -f $cmd, $("({0})" -f $_.Value.Count), $_.Value.Path

    foreach ($dupe in $_.Value.Dupes) {
        $lines += "`n" + $($format -f "", "", $dupe)
    }

    $lines
}

function Format-Title([string]$value) {

    $sepRegex = '\' + [IO.Path]::DirectorySeparatorChar
    $parts = $value -split $sepRegex

    return ($parts -join '-').Trim('-') -replace '_', '-'
}

function Get-OutputList([object]$data, [string]$caption = '') {

    $data = (New-Object PSObject -Property $data | Format-List | Out-String)
    return Get-OutputString $data $caption
}

function Get-OutputString([string]$data, [string]$caption = '') {

    $eol = [Environment]::NewLine

    if ($caption) {
        $caption += $eol + ('-' * $caption.Length)
    }

    return $caption + $eol + $data.Trim() + $eol + $eol
}

function Get-ProcessList([System.Collections.ArrayList]$list) {

    $parentId = $null

    if ($list.Count -eq 0) {
        $id = $PID
    } else {
        $id = $list[$list.Count - 1].ParentId
    }

    if (-not $id) {
        return $false
    }

    if ($PSEdition -eq 'Core') {
        $proc = Get-Process -Id $id -ErrorAction SilentlyContinue

        if (-not $proc) {
            return $false
        }

        $path = $proc.Path
        $parentId = $proc.Parent.Id
    } else {
        $proc = Get-WmiObject Win32_process | Where-Object ProcessId -eq $id

        if (-not $proc)  {
            return $false
        }

        $path = $proc.Path
        $parentId = $proc.ParentProcessId
    }

    if (-not $path) {
        return $false
    }

    $list.Add(@{ Id = $id; Path = $path; ParentId = $parentId }) | Out-Null
    return ($null -ne $parentId -and 1 -ne $parentId)
}

function Get-ReportName([string]$name) {

    if ($IsWindows) {
        $prefix = 'win'
    } elseif ($IsLinux) {
        $prefix = 'linux'
    } elseif ($IsMacOS) {
        $prefix = 'mac'
    }

    return "$prefix-$name.txt"
}

function Get-ValidPaths([System.Collections.ArrayList]$data, [object]$stats) {

    $result = New-Object System.Collections.ArrayList
    $allPaths = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $pathList = $env:PATH -Split [IO.Path]::PathSeparator

    foreach ($path in $pathList) {

        $errors.Clear()

        # Test and normalize path
        $path = Resolve-PathEx $path $errors
        $stats.Missing += $errors.Count

        if ($allPaths -contains $path) {
            $errors.Add('Duplicate') | Out-Null
            ++$stats.Duplicates
        }

        $allPaths.Add($path) | Out-Null

        if ($errors.Count -eq 0) {
            $status = 'OK'
        } else {
            $status = $errors -join '/'
        }

        $row = New-Object PSObject -Property @{ Path = $path; Status = $status }
        $data.Add($row) | Out-Null

        if ($status -eq 'OK') {
            $result.Add($path) | Out-Null
        }
    }

    $stats.Entries = $allPaths.Count
    $stats.Valid = $result.Count

    return $result
}

function Initialize-App([string]$basePath, [object]$config) {

    $procList = New-Object System.Collections.ArrayList
    while (Get-ProcessList $procList) {}

    #Write-Host ($procList | Select-Object Id, ParentId, Path | Out-String)

    # Get defaults and remove first item
    $pathInfo = Get-Item -LiteralPath $procList[0].Path
    $config.Module = $pathInfo.FullName
    $config.Report = $pathInfo.BaseName.ToLower()
    $config.IsUnixy = $false
    $config.UnixHasStat = $false
    $config.UnixNoStat = $false

    $procList.RemoveAt(0);

    if ($IsWindows) {
        if (Test-ForWinUnixy $procList $config) {
            $config.IsUnixy = $true
        } else {
            Test-ForWinNative $procList $config
        }
    } else {
        $config.UnixHasStat = ($null -ne $pathInfo.UnixMode)
        $config.UnixNoStat = (-not $config.UnixHasStat)
        Test-ForUnix $procList $config
    }

    $reportName = Get-ReportName $config.Report
    $config.Report = (Join-Path $basePath (Join-Path 'logs' $reportName))

    $stats = [ordered]@{
        Module = $config.Module;
        Platform = "$($PSVersionTable.Platform)";
        OS = "$($PSVersionTable.OS)";
        IsUnixy = $config.IsUnixy;
        Powershell = $config.Powershell
        ReportName = $reportName;
    }

    if (-not $IsWindows) {
        $stats.Remove('IsUnixy')
    }

    return $stats
}

function Resolve-PathEx([string]$path, [System.Collections.ArrayList]$errors) {

    if (-not $path) {
        $errors.Add('Missing') | Out-Null
        return $path
    }

    if (-not (Test-Path -Path $path)) {
        $errors.Add('Missing') | Out-Null
    }

    $slash = [IO.Path]::DirectorySeparatorChar
    (Join-Path $path $slash).TrimEnd($slash)
}

function Test-IsExecutableOnUnixy([System.IO.FileInfo]$file, [array]$pathExt, [object]$config) {

    if (-not $file.Extension) {
        return $false
    }

    return ($file.UnixMode).EndsWith('x')
}

function Test-IsExecutableOnWindows([System.IO.FileInfo]$file, [array]$pathExt, [object]$config) {

    if (-not $file.Extension) {

        if (-not $config.IsUnixy) {
            return $false;
        }

        $line = Get-Content -Path $file.FullName -First 1

        if ($null -ne $line -and $line.StartsWith('#!/')) {
            return $true
        }

    } elseif ($pathExt -contains $file.Extension) {
        return $true
    }

    return $false
}

function Test-ForUnix([System.Collections.ArrayList]$parents, [object]$config) {

    $lastMatch = ''
    $lastPath = ''

    foreach ($item in $parents) {

        $path = $item.Path
        $testPath = $path.ToLower()

        if (-not ($testPath -match '/bin/(\w*sh)$')) {
            break;
        }

        $lastMatch = Format-Title $matches[1]
        $lastPath = $path

    }

    if ($lastMatch) {
        $config.Module = $lastPath
        $config.Report = $lastMatch
    }
}

function Test-ForWinNative([System.Collections.ArrayList]$parents, [object]$config) {

    $lastMatch = ''
    $lastPath = ''

    foreach ($item in $parents) {

        $currentMatch = ''
        $path = $item.Path
        $pathInfo = Get-Item -LiteralPath $path
        $testPath = $pathInfo.Name.ToLower()

        foreach ($name in @('cmd', 'pwsh', 'powershell', 'powershell_ise')) {

            if ($testPath -match "($name)\.exe") {
                $currentMatch = Format-Title $matches[1]
                $lastPath = $path
                break
            }
        }

        if (!$currentMatch) {
            break
        }

        $lastMatch = $currentMatch
    }

    if ($lastMatch) {
        $config.Module = $lastPath
        $config.Report = $lastMatch
    }
}

function Test-ForWinUnixy([System.Collections.ArrayList]$parents, [object]$config) {

    $lastMatch = ''
    $lastPath = ''

    foreach ($item in $parents) {

        $currentMatch = ''
        $path = $item.Path
        $pathInfo = Get-Item -LiteralPath $path
        $testPath = (Join-Path $pathInfo.DirectoryName $pathInfo.BaseName).ToLower()

        foreach ($name in @('git', 'cygwin', 'mingw', 'msys')) {

            if ($testPath -match "\\($name\w*)\\(.*)") {
                $currentMatch = Format-Title ($matches[1] + '-' + $matches[2])
                $lastPath = $path
                break
            }
        }

        if (!$currentMatch) {
            break
        }

        $lastMatch = $currentMatch
    }

    if ($lastMatch) {
        $config.Module = $lastPath
        $config.Report = $lastMatch
    }

    return [bool] $lastMatch
}
