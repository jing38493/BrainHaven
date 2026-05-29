#!/usr/bin/env python3
"""
parse-progress.py CWD  →  输出 JSON {file, total, done, current, percent}

约定：cwd 根目录的 plan.md（大小写都接受），里面用 `- [ ]` / `- [x]` 列步骤。

当前步骤优先级：
  P1. 含「当前」字样的 checkbox 行（如 `- [ ] 写 README ← **当前**`）
  P2. 第一个未勾的 checkbox

退出码：
  0  成功
  2  没找到 plan.md 或里面没 checkbox
"""
import json
import os
import re
import sys

CHECKBOX_RE = re.compile(r"^\s*-\s*\[([ xX])\]\s*(.+?)\s*$")
CURRENT_TAIL_RE = re.compile(r"\s*(←\s*)?\*?\*?当前\*?\*?\s*$")


def find_plan(cwd: str):
    for name in ("plan.md", "PLAN.md", "Plan.md"):
        p = os.path.join(cwd, name)
        if os.path.isfile(p):
            return p
    return None


def clean_step(raw: str) -> str:
    s = raw.strip()
    s = CURRENT_TAIL_RE.sub("", s).strip()
    if len(s) > 60:
        s = s[:58].rstrip() + "…"
    return s


def main(cwd: str):
    plan = find_plan(cwd)
    if not plan:
        return {"error": "no plan.md in " + cwd}

    items = []  # (checked: bool, text: str, has_marker: bool)
    try:
        with open(plan, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                m = CHECKBOX_RE.match(line.rstrip("\n"))
                if not m:
                    continue
                checked = m.group(1).lower() == "x"
                text = m.group(2)
                has_marker = "当前" in text
                items.append((checked, text, has_marker))
    except Exception as e:
        return {"error": f"read failed: {e}"}

    total = len(items)
    if total == 0:
        return {"error": "no checkboxes in " + os.path.basename(plan)}

    done = sum(1 for c, _, _ in items if c)

    # current: marker first, then first unchecked
    current = None
    for _, text, has in items:
        if has:
            current = clean_step(text)
            break
    if current is None:
        for c, text, _ in items:
            if not c:
                current = clean_step(text)
                break

    percent = round(done / total * 100) if total else 0
    return {
        "file": os.path.basename(plan),
        "total": total,
        "done": done,
        "current": current,
        "percent": percent,
    }


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: parse-progress.py CWD"}))
        sys.exit(1)
    res = main(sys.argv[1])
    print(json.dumps(res, ensure_ascii=False))
    sys.exit(0 if "error" not in res else 2)
