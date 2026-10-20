$ErrorActionPreference = 'Stop'

function Initialize-CaocodeWslServer([string]$Root, [string]$FlutterSdk) {
    $output = Join-Path $Root 'build\remote'
    $stamp = Join-Path $output 'VERSION'
    $sources = @(
        (Join-Path $Root 'pubspec.yaml'),
        (Join-Path $Root 'pubspec.lock'),
        (Join-Path $Root 'tool\build_remote_server.dart')
    )
    $sources += Get-ChildItem -LiteralPath (Join-Path $Root 'packages\bao_remote'),
        (Join-Path $Root 'packages\bao_agent') -Recurse -File |
        Where-Object { $_.Extension -eq '.dart' -or $_.Name -eq 'pubspec.yaml' } |
        Select-Object -ExpandProperty FullName
    $latest = ($sources | Get-Item | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
    if ((Test-Path -LiteralPath $stamp) -and
        (Get-Item -LiteralPath $stamp).LastWriteTimeUtc -ge $latest -and
        (Test-Path -LiteralPath (Join-Path $output 'caocode-server-linux-x64')) -and
        (Test-Path -LiteralPath (Join-Path $output 'caocode-server-linux-arm64'))) { return }
    Write-Output '正在构建 WSL 原生文件服务（后续启动复用）…'
    $dart = Join-Path $FlutterSdk 'bin\cache\dart-sdk\bin\dart.exe'
    & $dart run tool/build_remote_server.dart
    if ($LASTEXITCODE -ne 0) { throw 'WSL 文件服务编译失败' }
}

function Initialize-CaocodePluginJunctions([string]$Root) {
    $metadataPath = Join-Path $Root '.flutter-plugins-dependencies'
    if (-not (Test-Path -LiteralPath $metadataPath)) { return 0 }
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $created = 0
    # Flutter prepares links for every desktop project present, even when
    # building Windows. Linux support adds a second set to prepare here.
    foreach ($platform in @('windows', 'linux')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $platform))) { continue }
        $links = Join-Path $Root "$platform\flutter\ephemeral\.plugin_symlinks"
        New-Item -ItemType Directory -Path $links -Force | Out-Null
        foreach ($plugin in $metadata.plugins.$platform) {
            # Flutter links every plugin, including Dart-only plugins.
            if (-not (Test-Path -LiteralPath $plugin.path)) { continue }
            $link = Join-Path $links $plugin.name
            if (Test-Path -LiteralPath $link) {
                $item = Get-Item -LiteralPath $link -Force
                if ($item.LinkType -eq 'Junction' -and
                    [IO.Path]::GetFullPath($item.Target).TrimEnd('\') -ne [IO.Path]::GetFullPath($plugin.path).TrimEnd('\')) {
                    [IO.Directory]::Delete($link)
                }
            }
            if (-not (Test-Path -LiteralPath $link)) {
                New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null
                $created++
            }
        }
    }
    return $created
}

function Invoke-CaocodePubGet([string]$Flutter, [string]$Root) {
    Initialize-CaocodePluginJunctions $Root | Out-Null
    & $Flutter pub get
    if ($LASTEXITCODE -eq 0) {
        # pub get refreshes the metadata. New plugins need junctions before
        # the following build attempts to create privileged symlinks.
        Initialize-CaocodePluginJunctions $Root | Out-Null
        return
    }
    if ((Initialize-CaocodePluginJunctions $Root) -gt 0) {
        Write-Output '已创建 Windows 插件目录联接，重新获取依赖。'
        & $Flutter pub get
        if ($LASTEXITCODE -eq 0) {
            Initialize-CaocodePluginJunctions $Root | Out-Null
            return
        }
    }
    throw 'Windows 依赖安装失败'
}
