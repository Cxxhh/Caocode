param([Parameter(Mandatory)][string]$PlanPath)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw '需要 Windows PowerShell 7'
}
$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
$root = [IO.Path]::GetFullPath($plan.targetRoot)
$marker = Join-Path $root '.caocode-sync.json'
$validatedPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function FileChecksum([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
    finally { $stream.Dispose() }
}
function TargetPath([string]$Relative) {
    if ($Relative -match '(^|/)\.\.(/|$)|\\|:|^/|^(\.git|reference|\.caocode)(/|$)') {
        throw "非法同步路径：$Relative"
    }
    $path = [IO.Path]::GetFullPath((Join-Path $root $Relative))
    if (-not $path.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "同步路径越界：$Relative"
    }
    $item = $path
    while ($item.Length -gt $root.Length) {
        if (-not $validatedPaths.Add($item)) { break }
        if (([IO.File]::Exists($item) -or [IO.Directory]::Exists($item)) -and
            ([IO.File]::GetAttributes($item) -band [IO.FileAttributes]::ReparsePoint)) {
            throw "目标路径包含链接：$Relative"
        }
        $item = Split-Path -Parent $item
    }
    return $path
}
$previous = @{ source = $plan.manifest.source; files = @{} }
if (Test-Path -LiteralPath $marker) {
    $previous = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    if ($previous.source -ne $plan.manifest.source) { throw '同步源不一致' }
} elseif ((Test-Path -LiteralPath $root) -and (Get-ChildItem -LiteralPath $root -Force | Select-Object -First 1)) {
    throw '目标目录非空且没有 Caocode 同步记录'
}
$copies = [Collections.Generic.List[string]]::new()
$deletes = [Collections.Generic.List[string]]::new()
foreach ($relative in $plan.manifest.files.Keys) {
    $destination = TargetPath $relative
    if (-not [IO.File]::Exists($destination) -or
        (FileChecksum $destination) -ne $plan.manifest.files[$relative]) {
        $copies.Add($relative)
    }
}
foreach ($relative in $previous.files.Keys) {
    if (-not $plan.manifest.files.Contains($relative)) {
        $destination = TargetPath $relative
        if (Test-Path -LiteralPath $destination) {
            if ((FileChecksum $destination) -ne $previous.files[$relative]) {
                throw "目标文件已被单独修改，无法删除：$relative"
            }
            $deletes.Add($relative)
        }
    }
}
$summary = [ordered]@{
    copied = $copies.Count; deleted = $deletes.Count
    unchanged = $plan.manifest.files.Count - $copies.Count; dryRun = $plan.dryRun
}
if ($plan.verbose) { $summary.copy = @($copies.ToArray()); $summary.delete = @($deletes.ToArray()) }
if ($plan.dryRun) { $summary | ConvertTo-Json -Depth 5 -Compress; exit 0 }
New-Item -ItemType Directory -Path $root -Force | Out-Null
if (-not (Test-Path -LiteralPath $marker)) {
    @{ source = $plan.manifest.source; files = @{} } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $marker -Encoding UTF8
}
foreach ($relative in $copies) {
    $source = Join-Path $plan.sourceRoot $relative
    $destination = TargetPath $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    $temporary = $destination + '.caocode-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::Copy($source, $temporary, $false)
        $checksum = FileChecksum $temporary
        if ($checksum -ne $plan.manifest.files[$relative]) {
            throw "同步期间源文件发生变化：$relative"
        }
        [IO.File]::SetLastWriteTimeUtc($temporary, [IO.File]::GetLastWriteTimeUtc($source))
        [IO.File]::Move($temporary, $destination, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { [IO.File]::Delete($temporary) }
    }
}
foreach ($relative in $deletes) {
    $destination = TargetPath $relative
    if (Test-Path -LiteralPath $destination) {
        $checksum = FileChecksum $destination
        if ($checksum -ne $previous.files[$relative]) {
            throw "目标文件已被单独修改，无法删除：$relative"
        }
        [IO.File]::Delete($destination)
    }
}
$json = $plan.manifest | ConvertTo-Json -Depth 5
if ((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).TrimEnd() -ne $json) {
    $temporaryMarker = $marker + '.tmp'
    Set-Content -LiteralPath $temporaryMarker -Value $json -Encoding UTF8
    [IO.File]::Move($temporaryMarker, $marker, $true)
}
$summary | ConvertTo-Json -Depth 5 -Compress
