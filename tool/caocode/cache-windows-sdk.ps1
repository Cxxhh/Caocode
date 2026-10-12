param(
    [Parameter(Mandatory)][string]$FlutterSdk,
    [string]$SourceArchiveRoot
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$cache = Join-Path $FlutterSdk 'bin\cache'
$engine = (Get-Content -LiteralPath (Join-Path $cache 'engine.stamp') -Raw -Encoding UTF8).Trim()
$stamp = Join-Path $cache 'windows-sdk.stamp'
$artifacts = Join-Path $cache 'artifacts\engine'
$required = @(
    'windows-x64\flutter_windows.dll',
    'windows-x64\cpp_client_wrapper\core_implementations.cc',
    'windows-x64-profile\flutter_windows.dll',
    'windows-x64-release\flutter_windows.dll'
)
$ready = (Test-Path -LiteralPath $stamp) -and
    (Get-Content -LiteralPath $stamp -Raw -Encoding UTF8).Trim() -eq $engine
foreach ($file in $required) { $ready = $ready -and (Test-Path -LiteralPath (Join-Path $artifacts $file)) }
if ($ready) { return }
$downloads = Join-Path $cache "caocode-artifacts\$engine"
New-Item -ItemType Directory -Path $downloads -Force | Out-Null
$archives = @(
    @{ name = 'windows-x64-debug'; url = 'windows-x64-debug/windows-x64-flutter.zip'; target = 'windows-x64' },
    @{ name = 'windows-wrapper'; url = 'windows-x64/flutter-cpp-client-wrapper.zip'; target = 'windows-x64' },
    @{ name = 'windows-x64-profile'; url = 'windows-x64-profile/windows-x64-flutter.zip'; target = 'windows-x64-profile' },
    @{ name = 'windows-x64-release'; url = 'windows-x64-release/windows-x64-flutter.zip'; target = 'windows-x64-release' }
)
foreach ($archive in $archives) {
    $zip = Join-Path $downloads ($archive.name + '.zip')
    if (-not (Test-Path -LiteralPath $zip)) {
        $source = if ($SourceArchiveRoot) { Join-Path $SourceArchiveRoot ('caocode-' + $archive.name + '.zip') }
        if ($source -and (Test-Path -LiteralPath $source)) {
            [IO.File]::Copy($source, $zip, $false)
        } else {
            $baseUrl = if ($env:FLUTTER_STORAGE_BASE_URL) { $env:FLUTTER_STORAGE_BASE_URL.TrimEnd('/') } else { 'https://storage.googleapis.com' }
            $url = "$baseUrl/flutter_infra_release/flutter/$engine/$($archive.url)"
            Write-Output "下载 Windows Flutter 资源：$($archive.name)"
            & curl.exe -fLsS --retry 2 --max-time 90 $url -o ($zip + '.download')
            if ($LASTEXITCODE -ne 0) { throw "Windows SDK 资源下载失败：$($archive.name)" }
            [IO.File]::Move(($zip + '.download'), $zip, $true)
        }
    }
    Write-Output "解压 Windows Flutter 资源：$($archive.name)"
    Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $artifacts $archive.target) -Force
}
foreach ($file in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $artifacts $file))) { throw "Windows SDK 资源缺失：$file" }
}
Set-Content -LiteralPath $stamp -Value $engine -Encoding UTF8
