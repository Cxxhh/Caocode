#!/usr/bin/env python3
"""Plan content-based WSL -> Windows synchronization; PowerShell applies it."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = '.caocode-sync.json'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def windows_path(path):
    return subprocess.check_output(['wslpath', '-w', str(path)], text=True).strip()


def relative_path(value):
    path = PurePosixPath(value)
    if path.is_absolute() or '..' in path.parts or '\\' in value or ':' in value:
        raise ValueError(f'非法同步路径：{value}')
    if not path.parts or path.parts[0] in ('.git', 'reference', '.caocode', MANIFEST):
        raise ValueError(f'同步路径不可使用：{value}')
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', default=os.environ.get(
        'CAOCODE_WINDOWS_DIR', '/mnt/c/Users/11914/Documents/Caocode'))
    parser.add_argument('--dry-run', action='store_true')
    parser.add_argument('--verbose', action='store_true')
    args = parser.parse_args()
    target = Path(args.target).resolve()
    if target == ROOT or ROOT in target.parents or target in ROOT.parents:
        parser.error('同步目标必须位于工程目录之外')
    if not str(target).startswith('/mnt/'):
        parser.error('同步目标必须是 WSL 挂载的 Windows 本地目录')

    # Include new, uncommitted files; respect every .gitignore in the workspace.
    listing = subprocess.check_output([
        'git', '-C', str(ROOT), 'ls-files', '--cached', '--others',
        '--exclude-standard', '-z',
    ])
    files = {}
    for name in sorted(set(os.fsdecode(x) for x in listing.split(b'\0') if x)):
        relative_path(name)
        source = ROOT / name
        if not source.exists():
            continue
        if not source.is_file() or not source.resolve().is_relative_to(ROOT):
            parser.error(f'不支持的源文件：{name}')
        files[name] = digest(source)

    plan = {
        'sourceRoot': windows_path(ROOT), 'targetRoot': windows_path(target),
        'dryRun': args.dry_run, 'verbose': args.verbose,
        'manifest': {'source': str(ROOT), 'files': files},
    }
    # Author the execution script in WSL, then place it in a local Windows temp
    # directory. All Windows writes run in PowerShell 7, with no policy bypass.
    bootstrap = '''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) {
    throw '需要 Windows PowerShell 7'
}
$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
$directory = Join-Path ([IO.Path]::GetTempPath()) 'Caocode'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$localScript = Join-Path $directory 'sync-windows.ps1'
[IO.File]::Copy($payload.script, $localScript, $true)
Write-Output $localScript
'''
    with tempfile.TemporaryDirectory(prefix='caocode-sync-') as temporary:
        plan_path = Path(temporary) / 'plan.json'
        plan_path.write_text(json.dumps(plan, ensure_ascii=False), encoding='utf-8')
        local_script = subprocess.check_output([
            'pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', bootstrap,
        ], input=json.dumps({'script': windows_path(
            ROOT / 'tool/caocode/sync-windows.ps1')}), text=True).strip()
        result = subprocess.check_output([
            'pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
            local_script, '-PlanPath', windows_path(plan_path),
        ], text=True, cwd='/mnt/c')
    print(json.dumps(json.loads(result), ensure_ascii=False))


if __name__ == '__main__':
    main()
