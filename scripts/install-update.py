#!/usr/bin/env python3
"""Install the locally built app and, if connected, hand off its existing engine."""
from datetime import datetime
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import tempfile
import time
import uuid


class UpdateError(Exception):
    pass


def run(*args, check=True, timeout=12):
    return subprocess.run(args, check=check, timeout=timeout, capture_output=True, text=True,
                          env={**os.environ, "LC_ALL": "C"}).stdout.strip()


def app_processes():
    return {int(line) for line in run("/usr/bin/pgrep", "-x", "TunnelMaster", check=False).splitlines()}


def process_command(pid):
    return run("/bin/ps", "-ww", "-p", str(pid), "-o", "command=", check=False)


def listener(port):
    result = run("/usr/sbin/lsof", "-nP", "-t", f"-iTCP:{port}", "-sTCP:LISTEN", check=False)
    pids = {int(value) for value in result.splitlines()}
    if len(pids) != 1:
        raise UpdateError("无法确认当前代理端口属于单一进程。")
    return pids.pop()


def describe_engine(support):
    journal = support / "proxy-recovery.json"
    if not journal.exists():
        return None
    port = plistlib.loads(journal.read_bytes()).get("port")
    if type(port) is not int or not 1024 <= port <= 65535:
        raise UpdateError("当前代理记录不完整。")
    proxy = run("/usr/sbin/scutil", "--proxy")
    for name in ("HTTP", "HTTPS", "SOCKS"):
        for key, value in (("Enable", 1), ("Proxy", "127.0.0.1"), ("Port", port)):
            if not re.search(rf"^\s*{name}{key} : {re.escape(str(value))}\s*$", proxy, re.MULTILINE):
                raise UpdateError("当前系统代理与会话记录不一致。")
    pid = listener(port)
    command = process_command(pid)
    home = next((path for path in support.glob("mihomo-*")
                 if command.endswith(f" -d {path} -f {path / 'config.json'}")), None)
    unix = run("/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), "-U", "-Fn", check=False)
    sockets = set(re.findall(r"^n([^\n]*?/metrics\.sock)(?:\s.*)?$", unix, re.MULTILINE))
    if home is None or len(sockets) != 1:
        raise UpdateError("当前 Mihomo 会话无法安全交接。")
    started = run("/bin/ps", "-p", str(pid), "-o", "lstart=")
    return {
        "processID": pid, "port": port, "workingDirectory": str(home),
        "metricsSocket": sockets.pop(), "createdAt": time.time(),
        "connectedAt": datetime.strptime(started, "%a %b %d %H:%M:%S %Y").timestamp(),
    }


def engine_answers(session):
    if listener(session["port"]) != session["processID"]:
        return False
    result = run("/usr/bin/curl", "--disable", "--fail", "--silent", "--max-time", "3",
                 "--max-filesize", "8388608",
                 "--noproxy", "*", "--unix-socket", session["metricsSocket"], "http://localhost/connections",
                 check=False, timeout=5)
    if not result:
        return False
    data = json.loads(result)
    return {"downloadTotal", "uploadTotal"} <= data.keys()


def proxy_exit(session):
    for url in ("https://www.cloudflare.com/cdn-cgi/trace", "https://api.ipify.org"):
        result = run("/usr/bin/curl", "--disable", "--fail", "--silent", "--max-time", "6",
                     "--noproxy", "", "--proxy", f"http://127.0.0.1:{session['port']}", url,
                     check=False, timeout=8)
        address = next((line[3:] for line in result.splitlines() if line.startswith("ip=")), result)
        try:
            return ipaddress.ip_address(address)
        except ValueError:
            continue
    return None


def install(support, built, installed):
    old_pids = app_processes()
    if len(old_pids) > 1:
        raise UpdateError("已有多个 TunnelMaster 进程，无法辨认旧版。")
    old = next(iter(old_pids), None)
    old_command = process_command(old) if old else None
    old_start = run("/bin/ps", "-p", str(old), "-o", "lstart=", check=False) if old else None
    session = describe_engine(support)
    if session and not engine_answers(session):
        raise UpdateError("现有代理健康检查未通过。")
    expected_exit = proxy_exit(session) if session else None
    if session and expected_exit is None:
        raise UpdateError("无法验证现有代理能访问 HTTPS，取消本次交接。")

    stage = Path(tempfile.mkdtemp(prefix=".tunnelmaster-update-", dir=installed.parent))
    staged = stage / "Next.app"
    backup = stage / "Previous.app"
    handoff = support / f"handoff-{uuid.uuid4()}.json"
    receipt = handoff.with_suffix(".json.ready")
    old_retired = False
    replaced = False
    try:
        run("/usr/bin/ditto", built, staged, timeout=30)
        run("/usr/bin/codesign", "--verify", "--strict", staged)
        if installed.exists():
            installed.rename(backup)
        staged.rename(installed)
        replaced = True

        args = []
        if session:
            with handoff.open("x", encoding="utf-8") as target:
                json.dump(session, target)
            args = ["--args", "--handoff", str(handoff)]
        run("/usr/bin/open", "-g", "-n", installed, *args)
        new = None
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            candidates = app_processes() - old_pids
            if session and receipt.is_file():
                launched, adopted = (int(part) for part in receipt.read_text().split())
                if launched in candidates and adopted == session["processID"] and engine_answers(session):
                    new = launched
                    break
            elif not session and len(candidates) == 1:
                new = candidates.pop()
                break
            time.sleep(0.2)
        if new is None:
            raise UpdateError("新版未确认接管，现有会话将继续运行。")

        if old and old in app_processes():
            unchanged = process_command(old) == old_command and old_start == run(
                "/bin/ps", "-p", str(old), "-o", "lstart=", check=False
            )
            if not unchanged or not old_command or new == old or (session and old == session["processID"]):
                raise UpdateError("旧界面进程身份已变化，取消交接。")
            if session and (not engine_answers(session) or proxy_exit(session) != expected_exit):
                raise UpdateError("当前代理状态已变化，取消交接。")
            # Retire only the previous UI process. The engine and its listener stay in place.
            os.kill(old, signal.SIGTERM)
        old_retired = True

        deadline = time.monotonic() + 5
        while old in app_processes() and time.monotonic() < deadline:
            time.sleep(0.15)
        if old in app_processes() or new not in app_processes():
            raise UpdateError("新版已接管，界面进程状态未达到预期。")

        if session and (not engine_answers(session) or proxy_exit(session) != expected_exit):
            raise UpdateError("界面交接后代理健康检查失败。")
        if backup.exists():
            archive = Path.home() / ".Trash" / f"TunnelMaster-before-update-{uuid.uuid4()}.app"
            try:
                backup.rename(archive)
            except OSError:
                pass  # Keep the old bundle in the private staging folder.
        print("新版已启动；原 Mihomo 进程和代理端口仍在线。" if session else "新版已启动。")
    except Exception:
        if not old_retired:
            for candidate in app_processes() - old_pids:
                command = process_command(candidate)
                if str(installed / "Contents/MacOS/TunnelMaster") in command and (
                    not session or str(handoff) in command
                ):
                    os.kill(candidate, signal.SIGTERM)
            if replaced:
                installed.rename(staged)
            if backup.exists():
                backup.rename(installed)
        raise
    finally:
        handoff.unlink(missing_ok=True)
        receipt.unlink(missing_ok=True)
        if not any(stage.iterdir()):
            stage.rmdir()


def main():
    os.umask(0o077)
    root = Path(__file__).resolve().parent.parent
    built = root / "dist/TunnelMaster.app"
    installed = Path.home() / "Applications/TunnelMaster.app"
    support = Path.home() / "Library/Application Support/TunnelMaster"
    if not built.is_dir():
        raise UpdateError("请先运行 ./scripts/build-app.sh。")
    installed.parent.mkdir(parents=True, exist_ok=True)
    support.mkdir(parents=True, exist_ok=True)
    with (support / "update.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        install(support, built, installed)


if __name__ == "__main__":
    try:
        main()
    except (UpdateError, OSError, ValueError, subprocess.SubprocessError) as error:
        raise SystemExit(str(error))
