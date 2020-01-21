$pathList = $env:Path -Split ";"
#Write-Output $pathList

$pathExt = $env:PATHEXT -Split ";"
$pathExt = @(".COM", ".EXE", ".BAT", ".CMD")
#Write-Output $pathExt

$table = @{}
$strict = $false
$native = $true

function CheckPath([string] $path) {

}
function Add-TableEntry([string] $baseName, [string] $filePath, [string] $shebang) {
    $key = $baseName.ToLower()

    if ($table.Contains($key)) {
        $item = $table.Get_Item($key)

        if ($filePath -eq $item.Path) {
            return
        }

        if ($strict) {
            $existingFile = Split-Path $item.Path -Leaf
            $newFile = Split-Path $filePath -Leaf

            if ($existingFile -ne $newFile) {
                return
            }
        }

        ++$item.Count
        $item.Dupes += $filePath
        $table.Set_Item($key, $item)


    } else {
        $value = @{ Path = $filePath; Count = 1; Dupes = @() }
        $table.Add($key, $value)
    }
}

$pathTable = New-Object System.Collections.ArrayList
$allPaths = New-Object System.Collections.ArrayList
$validPaths = @()

foreach ($item in $pathList) {

    [string]$path = $item
    $errors = @()

    if (-Not (Test-Path -Path $path)) {
        $errors += "Missing"
        $path = $path -replace '/', '\'
    } else {
        # Normalize path
        $path = Resolve-Path -Path $path
    }

    if ($allPaths -contains $path) {
        $errors += "Duplicate"
    }

    $allPaths.Add($path) | Out-Null

    if ($errors.Length -eq 0) {
        $status = "OK"
    } else {
        $status = $errors -join "/"
    }

    $row = New-Object PSObject -Property @{"PathEntry" = $path; Status = $status}
    $pathTable.Add($row) | Out-Null

    if ($status -eq "OK") {
        $validPaths += $path
    }
}

Write-Output $($pathTable | Format-Table -Property PathEntry, Status -AutoSize)

$level = 0;

foreach ($path in $validPaths) {
    ++$level

    $fileList = Get-ChildItem -Path $path -File

    foreach ($file in $fileList) {
        if ($file.BaseName.StartsWith(".") -Or $file.BaseName -match "\s") {
            continue
        }

        $shebang = ""
        $matched = $false

        if ($file.Extension -eq "") {
            $line = Get-Content -Path $file.FullName -First 1

            if ($line.StartsWith("#!/")) {
                $matched = $true
                $shebang = $line
            }

        } elseif ($pathExt -contains $file.Extension) {
            $matched = $true
        }

        if ($matched) {
            Add-TableEntry $file.BaseName $file.FullName $shebang
        }
    }

    if ($level -eq 100) {
        break;
    }

}

$out = $table.GetEnumerator() | Sort-Object -Property key
$out = $table.GetEnumerator() | Sort-Object -Property key | Where-Object {$_.Value.Count -gt 1} | ForEach-Object {

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

    #"{0,-20} ({1})   {2}, {3}" -f $_.Key, $_.Value.Count, $_.Value.Path, $($_.Value.Dupes -join ", ")

} | Out-String
#$out = $table.GetEnumerator() | Sort-Object -Property key |  ForEach-Object {$_.Key} | Out-String

Write-Output $out
Set-Content -Path 'result.txt' -Value $out
#Write-Output $table
