#!/usr/bin/env python3
"""Check the installed Codex app-server protocol without sending an AI prompt."""

import argparse
import json
from pathlib import Path
import queue
import subprocess
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--windows', action='store_true')
    args = parser.parse_args()
    command = ['codex', 'app-server', '--listen', 'stdio://']
    if args.windows:
        command = ['pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '''
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) { throw '需要 Windows PowerShell 7' }
Set-Location -LiteralPath $env:USERPROFILE
& codex app-server --listen stdio://
if ($LASTEXITCODE -ne 0) { throw 'Codex app-server 进程失败' }
''']
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, text=True, encoding='utf-8',
                               cwd=Path(__file__).resolve().parents[2])
    messages = queue.Queue()

    def read():
        for line in process.stdout:
            try:
                messages.put(json.loads(line))
            except json.JSONDecodeError:
                continue
        messages.put({'error': {'message': 'Codex app-server 进程已退出'}})

    threading.Thread(target=read, daemon=True).start()

    def send(message):
        process.stdin.write(json.dumps(message) + '\n')
        process.stdin.flush()

    def request(identifier, method, params):
        send({'id': identifier, 'method': method, 'params': params})
        while True:
            message = messages.get(timeout=30)
            if 'error' in message:
                raise RuntimeError(message['error'].get('message', '协议请求失败'))
            if message.get('id') == identifier:
                return message['result']

    try:
        initialized = request(1, 'initialize', {
            'clientInfo': {'name': 'caocode', 'title': 'Caocode', 'version': '0.1.0'},
        })
        send({'method': 'initialized'})
        models = request(2, 'model/list', {'limit': 100})
        print(json.dumps({'initialized': True, 'platform': initialized.get('platformOs'),
                          'modelCount': len(models.get('data', []))}, ensure_ascii=False))
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            process.wait(timeout=5)


if __name__ == '__main__':
    main()
