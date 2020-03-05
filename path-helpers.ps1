function Add-CmdEntry([object]$data, [string]$command, [System.IO.FileInfo]$file) {

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

function Add-CmdLinks([object]$data, [string]$command, [System.IO.FileInfo]$file, [object]$stats) {

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
                $cmdStats.Duplicates += Add-CmdEntry $data $command $linkTarget
                $entryAdded = $true
            }
        }
    }

    return $entryAdded
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

    return $lines
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

function Get-PathCommands([System.Collections.ArrayList]$paths, [object]$stats, [object]$config) {

    $data = @{}
    $exeList = New-Object System.Collections.ArrayList
    $errors = 0

    foreach ($path in $paths) {

        if (-not $IsWindows -and -not $config.unixHasStat) {

            if (-not (Get-UnixExecutables $path $exeList)) {
                $errors += 1
                continue
            }

        }

        $fileList = Get-ChildItem -Path $path -File

        foreach ($file in $fileList) {

            if ($file.Name.StartsWith('.') -or $file.Name -match '\s') {
                continue
            }

            if (-not (Test-IsExecutable $file $config $exeList)) {
                continue
            }

            $command = $file.BaseName

            if (-not (Add-CmdLinks $data $command $file $stats)) {
                $stats.Duplicates += Add-CmdEntry $data $command $file
            }
        }
    }

    $stats.Commands = $data.Keys.Count

    if ($errors -ne 0) {
        $stats.Add('PermissionErrors', $errors)
    }
    return $data
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

function Get-RuntimeInfo([string]$module, [bool]$isUnixy, [string]$reportName) {

    if ($PSVersionTable.Platform) {
        $platform = $PSVersionTable.Platform
        $os = $PSVersionTable.OS
    } else {
        $platform = 'Win32NT'
        $os = 'Microsoft Windows ' + (Get-CimInstance Win32_OperatingSystem).Version
    }

    $stats = [ordered]@{
        Module = $module;
        Platform = $platform;
        OSVersion = $os;
        IsUnixy = $isUnixy;
        Powershell = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
        ReportName = $reportName;
    }

    if (-not $IsWindows) {
        $stats.Remove('IsUnixy')
    }

    return $stats
}


function Get-UnixExecutables([string]$path, [System.Collections.ArrayList]$names) {

    # Use ls to get file name and permissions
    $names.Clear()

    # Redirecting stderr will throw an error on access violations
    try {
        $lines = ls -l $path 2> $null
    } catch {
        return $false
    }

    foreach ($line in $lines) {
        if ($line -match '^[-l].{8}x') {
            $names.Add(($line -split '\s+')[8]) | Out-Null
        }
    }

    return $true
}

function Get-ValidPaths([System.Collections.ArrayList]$data, [object]$stats) {

    $result = New-Object System.Collections.ArrayList
    $allPaths = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $pathList = $env:PATH -Split [IO.Path]::PathSeparator
    $stats.Characters = $env:PATH.Length

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
    Write-Host ($procList | Select-Object Id, ParentId, Path | Out-String)

    # Get defaults and remove first item
    $pathInfo = Get-Item -LiteralPath $procList[0].Path
    $procList.RemoveAt(0);

    $data = @{
        module = $pathInfo.FullName;
        name = $pathInfo.BaseName.ToLower()
    }

    if ($IsWindows) {
        if (Test-WinUnixyShell $procList $data) {
            $config.isUnixy = $true
        } else {
            Test-WinNativeShell $procList $data
        }
    } else {
        $config.unixHasStat = ($null -ne $pathInfo.UnixMode)
        Test-UnixShell $procList $data
    }

    $reportName = Get-ReportName $data.name
    $config.Report = (Join-Path $basePath (Join-Path 'logs' $reportName))

    return Get-RuntimeInfo $data.module $config.isUnixy $reportName
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

function Test-IsExecutable([System.IO.FileInfo]$file, [object]$config, [System.Collections.ArrayList]$exeList) {
    # We only test the file is executable, rather than any links

    if ($IsWindows) {
        return Test-IsExecutableOnWindows $file $config
    }

    if ($file.Name.Contains('.')) {
        return $false
    }

    if ($config.unixHasStat) {
        return $file.UnixMode.EndsWith('x')
    }

    return $exeList.Contains($file.Name)
}

function Test-IsExecutableOnWindows([System.IO.FileInfo]$file, [object]$config) {

    if (-not $file.Extension) {

        # No file extension, so only check unixy
        if (-not $config.isUnixy) {
            return $false;
        }

        # Look for a shebang on the first line
        $line = Get-Content -Path $file.FullName -First 1

        if ($line -and $line.StartsWith('#!/')) {
            return $true
        }

    } elseif ($config.pathExt -contains $file.Extension) {
        return $true
    }

    return $false
}

function Test-UnixShell([System.Collections.ArrayList]$parents, [object]$data) {

    $lastMatch = ''
    $lastPath = ''

    foreach ($item in $parents) {

        $path = $item.Path
        $testPath = $path.ToLower()

        # Looks for ...sh filenames
        if (-not ($testPath -match '/bin/(\w*sh)$')) {
            break;
        }

        $lastMatch = Format-Title $matches[1]
        $lastPath = $path

    }

    if ($lastMatch) {
        $data.module = $lastPath
        $data.name = $lastMatch
    }
}

function Test-WinNativeShell([System.Collections.ArrayList]$parents, [object]$data) {

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
        $data.module = $lastPath
        $data.name = $lastMatch
    }
}

function Test-WinUnixyShell([System.Collections.ArrayList]$parents, [object]$data) {

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
        $data.module = $lastPath
        $data.name = $lastMatch
    }

    return [bool] $lastMatch
}
