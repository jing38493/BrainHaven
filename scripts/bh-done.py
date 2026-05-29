#!/usr/bin/env python3
"""
bh-done.py [SESSION_PREFIX]

把指定 Claude Code session 在 BrainHaven 浮窗里对应的卡片归档：
- 从 tasks[] 移到 archive[]
- session_key 追加进 dismissed_keys[] 防止 reconcile 重建
- 之后 ~1 秒后台杀掉 claude 进程 + 关掉对应终端 tab（iTerm2 / Terminal.app）

默认从 $CLAUDE_CODE_SESSION_ID 取 sessionId（在 Claude Code 终端里自动可用）；
也可传一个位置参数作为 sessionId 前缀。

环境变量：
  BH_DONE_NO_CLOSE=1   只归档卡片，不杀 session、不关 tab

退出码：
  0  成功
  1  没传参数且 $CLAUDE_CODE_SESSION_ID 也空
  2  没找到匹配的活跃 auto 卡片
"""
import datetime
import glob
import json
import os
import shlex
import subprocess
import sys

def _project_root() -> str:
    """优先 $BRAINHAVEN_HOME，否则按脚本自身位置推（<root>/scripts/bh-done.py）"""
    env = os.environ.get("BRAINHAVEN_HOME", "").strip()
    if env:
        return os.path.expanduser(env)
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


TASKS_JSON = os.path.join(_project_root(), "data", "tasks.json")


def iso_now() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def find_claude_pid(sid: str):
    """根据 sessionId 反查 pid（扫 ~/.claude/sessions/*.json）"""
    home = os.path.expanduser("~")
    for f in glob.glob(f"{home}/.claude/sessions/*.json"):
        try:
            with open(f, "r", encoding="utf-8") as fh:
                meta = json.load(fh)
            if isinstance(meta.get("sessionId"), str) and meta["sessionId"].startswith(sid):
                return os.path.splitext(os.path.basename(f))[0]
        except Exception:
            continue
    return None


def get_tty(pid: str):
    try:
        out = subprocess.run(
            ["ps", "-o", "tty=", "-p", pid],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip()
        return out if out else None
    except Exception:
        return None


def schedule_close(pid: str, tty):
    """后台脚本：等 0.8s 让本进程先打完输出 → 杀 claude → 关 tab。
       用 start_new_session 让它脱离父进程，父退出也不被 SIGHUP 干掉。"""
    iterm_as = ""
    terminal_as = ""
    if tty:
        iterm_as = f'''
tell application "iTerm"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (tty of s) ends with "{tty}" then
          close s
          return
        end if
      end repeat
    end repeat
  end repeat
end tell
'''
        terminal_as = f'''
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if (tty of t) ends with "{tty}" then
        close w
        return
      end if
    end repeat
  end repeat
end tell
'''

    # 1.5s 给 Claude Code 时间把 stdout 转成对话回复显示给用户
    parts = [
        "sleep 1.5",
        f"pkill -P {pid} 2>/dev/null",   # 先收 claude 的子进程（subagent / shell snapshot 等）
        f"kill {pid} 2>/dev/null",        # SIGTERM 让 claude 优雅退出（保存 session 状态）
        "sleep 0.5",
        f"kill -9 {pid} 2>/dev/null",     # 兜底硬杀
    ]
    if iterm_as:
        parts.append(f"osascript -e {shlex.quote(iterm_as)} 2>/dev/null")
    if terminal_as:
        parts.append(f"osascript -e {shlex.quote(terminal_as)} 2>/dev/null")
    bash_script = "\n".join(parts)

    subprocess.Popen(
        ["bash", "-c", bash_script],
        start_new_session=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main() -> int:
    target = sys.argv[1].strip() if len(sys.argv) > 1 and sys.argv[1].strip() else os.environ.get("CLAUDE_CODE_SESSION_ID", "").strip()
    if not target:
        print(
            "ERROR: $CLAUDE_CODE_SESSION_ID 为空，且没传 sessionId 参数。\n"
            "如果你不在 Claude Code 终端里，请显式传一个 sessionId（或前缀）",
            file=sys.stderr,
        )
        return 1

    with open(TASKS_JSON, "r", encoding="utf-8") as f:
        d = json.load(f)

    matched = None
    for t in d.get("tasks", []):
        sid = t.get("sessionId") or ""
        if t.get("source") == "auto" and sid.startswith(target):
            matched = t
            break

    if not matched:
        active = [
            (t.get("sessionId") or "")[:8]
            for t in d.get("tasks", [])
            if t.get("source") == "auto"
        ]
        print(
            f"ERROR: 没找到 sessionId 以 '{target[:8]}…' 开头的活跃 auto 卡片",
            file=sys.stderr,
        )
        print(f"目前活跃的 sessionId 前 8 位: {active}", file=sys.stderr)
        return 2

    d.setdefault("archive", []).append(
        {
            "id": matched["id"],
            "title": matched.get("title"),
            "subtitle": matched.get("subtitle"),
            "recap": matched.get("recap"),
            "goal": matched.get("goal"),
            "next_step": matched.get("next_step"),
            "tag": matched.get("tag"),
            "done_at": iso_now(),
            "reason": "marked done via /bh-done",
        }
    )

    key = matched.get("session_key") or ""
    if key and key not in d.setdefault("dismissed_keys", []):
        d["dismissed_keys"].append(key)

    d["tasks"] = [t for t in d["tasks"] if t["id"] != matched["id"]]

    with open(TASKS_JSON, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, indent=2)

    title = (matched.get("title") or "?")[:60]
    print(f"✓ 归档：{title}")

    # 关 session + 关 tab（除非显式禁用）
    if os.environ.get("BH_DONE_NO_CLOSE", "").strip():
        return 0

    sid_full = matched.get("sessionId") or target
    pid = find_claude_pid(sid_full)
    if pid:
        tty = get_tty(pid)
        schedule_close(pid, tty)
        if tty:
            print(f"🚪 即将关闭 session (pid={pid}, tty={tty}) + tab，~1 秒后生效")
        else:
            print(f"🚪 即将关闭 session (pid={pid})，但拿不到 tty，tab 不会自动关")
    else:
        print("⚠ 没找到匹配的 claude pid，只归档了卡片；session/tab 没关")

    return 0


if __name__ == "__main__":
    sys.exit(main())
