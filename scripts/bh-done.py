#!/usr/bin/env python3
"""
bh-done.py [SESSION_PREFIX]

把指定 Claude Code session 在 BrainHaven 浮窗里对应的卡片归档：
- 从 tasks[] 移到 archive[]
- session_key 追加进 dismissed_keys[] 防止 reconcile 重建

默认从 $CLAUDE_CODE_SESSION_ID 取 sessionId（在 Claude Code 终端里自动可用）；
也可传一个位置参数作为 sessionId 前缀。

退出码：
  0  成功
  1  没传参数且 $CLAUDE_CODE_SESSION_ID 也空
  2  没找到匹配的活跃 auto 卡片
"""
import datetime
import json
import os
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
