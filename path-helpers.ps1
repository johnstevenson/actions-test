function Add-CmdEntry([object]$data, [string]$command, [System.IO.FileInfo]$file) {

    $duplicates = 0
    $key = $command
    $path = $file.FullName

    if ($IsWindows) {
        $key = $key.ToLower()

        # $app is a global - change
        if ($file.DirectoryName -eq $app.chocoBin) {
            $path = Get-ChocoShim $path
        }
    }

    if ($data.Contains($key)) {
        $item = $data.Get_Item($key)

        if ($item.Unique.Contains($file.DirectoryName)) {
            return $duplicates
        }

        ++$item.Count
        $item.Dupes += $path
        $item.Unique += $file.DirectoryName
        $data.Set_Item($key, $item)
        $duplicates = 1

    } else {
        $value = @{ Path = $path; Count = 1; Dupes = @(); Unique = @($file.DirectoryName) }
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
                $stats.Duplicates += Add-CmdEntry $data $command $linkTarget
                $entryAdded = $true
            }
        }
    }

    return $entryAdded
}

function Format-Path([string]$path, [string]$format) {

    if ($IsWindows -and $path.Contains('|')) {
        $parts = $path.Split('|')
        return "** {0} =>`n" -f $parts[0] + $($format -f "", "", $parts[1])
    }

    return $path
}

function Format-PathList {
    $cmd = $_.Key

    if ($cmd.Length -gt 25) {
        $cmd = $cmd.Substring(0, 22) + "..."
    }

    $format = "{0,-25} {1,-5} {2}"
    $path = Format-Path $_.Value.Path $format
    $lines = $format -f $cmd, $("({0})" -f $_.Value.Count), $path

    foreach ($dupe in $_.Value.Dupes) {
        $path = Format-Path $dupe $format
        $lines += "`n" + $($format -f "", "", $path)
    }

    return $lines
}

function Format-Title([string]$value) {

    $sepRegex = '\' + [IO.Path]::DirectorySeparatorChar
    $parts = $value -split $sepRegex

    return ($parts -join '-').Trim('-') -replace '_', '-'
}

function Get-ChocoShim([string] $path) {

    $verInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)

    if (!($verInfo.FileDescription -match 'shim')) {
        return $path
    }

    $target = matchFile $file.FullName

    if ($null -eq $target) {
        return $path
    }

    if (![System.IO.Path]::IsPathFullyQualified($target)) {
        $target = [System.IO.Path]::Combine($app.chocoBin, $target)
    }

    $target = [System.IO.Path]::GetFullPath($target)

    return "$path|$target"
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
    $unixNoStat = -not $IsWindows -and -not $config.unixHasStat
    $errors = 0

    foreach ($path in $paths) {

        if ($unixNoStat) {

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

    $id = $null
    $path = $null
    $parentId = $null

    if ($list.Count -eq 0) {
        $id = $PID
    } else {
        $id = $list[$list.Count - 1].ParentId
    }

    if ($null -eq $id) {
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

    $path = [System.IO.Path]::GetFullPath($path)

    $row = [PSCustomObject]@{ Pid = "$id"; ParentId = $parentId; ProcessName = $path; }
    $list.Add($row) | Out-Null
    return ($null -ne $parentId)
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

function Get-RuntimeInfo([string]$module, [object]$config, [string]$reportName) {

    if ($PSVersionTable.Platform) {
        $platform = $PSVersionTable.Platform
        $os = $PSVersionTable.OS
    } else {
        $platform = 'Win32NT'
        $os = 'Microsoft Windows ' + (Get-CimInstance Win32_OperatingSystem).Version
    }

    $info = [ordered]@{
        Module = $module;
        Platform = $platform;
        OSVersion = $os;
        IsUnixy = $config.isUnixy;
        ChocolateyBin = $config.chocoBin;
        Powershell = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
        ReportName = $reportName;
    }

    if (-not $IsWindows) {
        $info.Remove('IsUnixy')
        $info.Remove('ChocoBin')
    }

    return $info
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
    $parents = New-Object System.Collections.ArrayList

    # Get the process list
    while (Get-ProcessList $procList) {}

    foreach ($proc in $procList) {
        if ($null -ne $proc.ParentId -and $proc.ParentId -gt 1) {
            $parents.Add($proc.ProcessName) | Out-Null
        }
    }

    $procList.Reverse()
    $config.procTree = $procList

    # Get defaults and remove first item
    $pathInfo = Get-Item -LiteralPath $parents[0]
    $parents.RemoveAt(0);

    $data = @{
        module = $pathInfo.FullName;
        name = $pathInfo.BaseName.ToLower()
    }

    if ($IsWindows) {
        if (Test-WinUnixyShell $parents $data) {
            $config.isUnixy = $true
        } else {
            Test-WinNativeShell $parents $data
        }
    } else {
        $config.unixHasStat = ($null -ne $pathInfo.UnixMode)
        Test-UnixShell $parents $data
    }

    $reportName = Get-ReportName $data.name
    $config.report = (Join-Path $basePath (Join-Path 'logs' $reportName))

    if ($IsWindows) {
        $choco = $env:ChocolateyInstall

        if (-not $choco) {
            $choco = Join-Path $env:ProgramData 'Chocolatey'

            if (-not (Test-Path $choco)) {
                $choco = ''
            }
        }

        if ($choco) {
            $choco = Join-Path $choco 'bin'
        }

        $config.chocoBin = $choco
    }

    return Get-RuntimeInfo $data.module $config $reportName
}

function matchBinary([array]$bytes, [string]$pattern, [int]$startIndex) {

    [array]$pattern = [System.Text.Encoding]::Unicode.GetBytes($pattern)
    $max = $bytes.Count - $pattern.Count + 1

    $i = $startIndex
    $m = 0
    $found = $false
    $index = 0

    while ($i -lt $max) {

        if ($bytes[$i] -eq $pattern[$m]) {
            ++$m

            if ($m -eq $pattern.Count) {
                $found = $true
                $index = $i - $pattern.Count + 1
                break
            }

        } elseif ($m -gt 0) {
            $i -= $m
            $m = 0
        }

        ++$i
    }

    return @{ Found = $found; Index = $index }
}

function matchFile([string]$filename) {

    [array]$bin = [System.IO.File]::ReadAllBytes($filename)
    $match = $null

    $initPattern = "file at '"
    $result = matchBinary $bin $initPattern 0

    if (!$result.Found) {
        return $match
    }

    $start = $result.Index + ($initPattern.Length * 2)
    $endPattern = "'"
    $result = matchBinary $bin $endPattern $start

    if (!$result.Found) {
        return $match
    }

    $end = $result.Index - 1

    return [System.Text.Encoding]::Unicode.GetString($bin[$start..$end])
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

    foreach ($path in $parents) {

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

    foreach ($path in $parents) {

        $currentMatch = ''
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

    foreach ($path in $parents) {

        $currentMatch = ''
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
