#!/usr/bin/env python3
"""Run Windows Flutter from WSL; sync changes before every reload."""

import argparse
from collections import deque
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading

from sync_windows import ROOT, windows_path


def startup_message(message):
    timestamp = datetime.now(timezone.utc).isoformat(timespec='milliseconds')
    timestamp = timestamp.replace('+00:00', 'Z')
    print(f'[{timestamp}] [Caocode][开发启动] {message}', flush=True)


@contextmanager
def terminal_input():
    if not sys.stdin.isatty():
        yield
        return
    import termios
    import tty
    previous = termios.tcgetattr(sys.stdin)
    try:
        tty.setcbreak(sys.stdin.fileno())
        yield
    finally:
        termios.tcsetattr(sys.stdin, termios.TCSADRAIN, previous)


def main():
    parser = argparse.ArgumentParser(
        description='在 WSL 启动 Windows 调试窗口；r 增量同步并热重载，R 热重启，q 退出。')
    parser.add_argument('--sync-only', action='store_true', help='仅同步代码')
    args = parser.parse_args()
    target = Path(os.environ.get(
        'CAOCODE_WINDOWS_DIR', '/mnt/c/Users/11914/Documents/Caocode'))

    def sync():
        return subprocess.run([
            sys.executable, str(ROOT / 'tool/caocode/sync_windows.py'),
            '--target', str(target),
        ], cwd=ROOT).returncode == 0

    if not args.sync_only:
        startup_message('开始启动，正在增量同步源码。')
    if not sync():
        if not args.sync_only:
            startup_message('启动失败：源码同步失败，具体原因见上方输出。')
        return 1
    if args.sync_only:
        return 0
    startup_message('正在启动 Windows 调试进程，等待构建和主窗口初始化。')
    try:
        process = subprocess.Popen([
            'pwsh', '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
            windows_path(target / 'tool/caocode/run-windows.ps1'),
        ], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding='utf-8', errors='replace', bufsize=1, cwd=ROOT)
    except (OSError, subprocess.SubprocessError) as error:
        startup_message(f'启动失败：无法启动 Windows 调试进程：{error}')
        return 1
    events = queue.Queue()

    def read_output():
        for line in process.stdout:
            events.put(('output', line.rstrip('\r\n')))
        events.put(('end', None))

    def read_input():
        while True:
            key = sys.stdin.read(1)
            if not key:
                return
            events.put(('key', key))

    threading.Thread(target=read_output, daemon=True).start()
    request_id = 0
    app_id = None
    started = False
    connected = False
    quit_requested = False
    recent_output = deque(maxlen=8)
    startup_error = None
    requests = {}

    def request(method, params, label):
        nonlocal request_id
        request_id += 1
        requests[request_id] = label
        process.stdin.write(json.dumps([{
            'id': request_id, 'method': method, 'params': params,
        }]) + '\n')
        process.stdin.flush()

    try:
        with terminal_input():
            threading.Thread(target=read_input, daemon=True).start()
            while True:
                try:
                    kind, value = events.get(timeout=0.2)
                except queue.Empty:
                    if process.poll() is not None:
                        break
                    continue
                if kind == 'end':
                    break
                if kind == 'key':
                    if value == 'q':
                        quit_requested = True
                        if app_id:
                            request('app.stop', {'appId': app_id}, '退出')
                        else:
                            request('daemon.shutdown', {}, '退出')
                        continue
                    if value not in ('r', 'R', 's'):
                        continue
                    if not started and value != 's':
                        print('窗口尚未启动，请等待 Debug 构建完成。', flush=True)
                        continue
                    if not sync():
                        print('同步失败，请修正后重试。', flush=True)
                        continue
                    if value != 's':
                        request('app.restart', {
                            'appId': app_id, 'fullRestart': value == 'R',
                            'pause': False, 'reason': 'WSL source changed',
                        }, '热重启' if value == 'R' else '热重载')
                    continue
                try:
                    messages = json.loads(value)
                except (json.JSONDecodeError, TypeError):
                    if value.strip():
                        recent_output.append(value.strip())
                    print(value, flush=True)
                    continue
                if not isinstance(messages, list):
                    print(value, flush=True)
                    continue
                for message in messages:
                    if not isinstance(message, dict):
                        continue
                    event = message.get('event')
                    params = message.get('params') or {}
                    if event == 'app.start':
                        app_id = params['appId']
                    elif event == 'app.started':
                        started = True
                        connected = True
                        print('\nFlutter 调试连接已就绪。r：同步并热重载；R：同步并热重启；'
                              's：只同步；q：退出。', flush=True)
                    elif event == 'app.log':
                        line = params.get('log', '')
                        if line.strip():
                            recent_output.append(line.strip())
                        print(line, flush=True)
                    elif event == 'daemon.logMessage':
                        line = params.get('message', '')
                        if line.strip():
                            recent_output.append(line.strip())
                        if params.get('level') == 'error':
                            startup_error = line
                        print(line, flush=True)
                    elif event == 'app.progress':
                        if params.get('message'):
                            print(params['message'], flush=True)
                    elif event == 'app.debugPort':
                        if params.get('wsUri'):
                            print('Dart 调试服务：' + params['wsUri'], flush=True)
                    elif event == 'app.stop':
                        started = False
                        if params.get('error'):
                            startup_error = params['error']
                            print(params['error'], file=sys.stderr, flush=True)
                    elif 'id' in message:
                        label = requests.pop(message['id'], None)
                        if 'error' in message:
                            print(f'{label or "Flutter"}失败：{message["error"]}',
                                  file=sys.stderr, flush=True)
                        elif label:
                            result = message.get('result')
                            if isinstance(result, dict) and result.get('code', 0):
                                print(f'{label}失败：{result.get("message", result)}',
                                      file=sys.stderr, flush=True)
                            else:
                                print(f'{label}完成。', flush=True)
    except KeyboardInterrupt:
        quit_requested = True
        if process.poll() is None:
            try:
                request('app.stop' if app_id else 'daemon.shutdown',
                        {'appId': app_id} if app_id else {}, '退出')
            except (BrokenPipeError, OSError):
                pass
    finally:
        if process.poll() is None:
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=10)
        process.stdin.close()
        process.stdout.close()
    if not connected and not quit_requested:
        reason = startup_error or (recent_output[-1] if recent_output else None)
        reason = reason or f'调试进程在连接就绪前退出，退出码 {process.returncode}'
        startup_message(f'启动失败：{reason}')
        return process.returncode or 1
    return process.returncode


if __name__ == '__main__':
    sys.exit(main())
