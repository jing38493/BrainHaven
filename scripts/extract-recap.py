#!/usr/bin/env python3
"""
extract-recap.py --pid PID    → 按 pid 找 sessions/{pid}.json → 对应 jsonl
extract-recap.py --cwd CWD    → 按 cwd 找最新 mtime 的 jsonl
extract-recap.py --jsonl PATH → 直接读指定 jsonl

输出 JSON：{title, recap, jsonl, sessionId, cwd, mtime}

优先级：customTitle > aiTitle > 最新 slug > 第一条 user 消息
"""
import argparse
import glob
import json
import os
import re
import sys


def escape_cwd(cwd: str) -> str:
    # Claude Code 把 / 和 . 都转成 -
    return cwd.replace("/", "-").replace(".", "-")


CLAUDE_HINT_RE = "(disable recaps in /config)"

# 从 away_summary 抠「下一步」「目标」
NEXT_RE = re.compile(r"下一步[：:是等、 ]*\s*([^。\n]+?)(?=[。\n]|$)")
GOAL_EXPLICIT_RE = re.compile(r"(?:目标是|目标[：:])\s*([^。;；\n]+?)(?=[。;；\n]|$)")
DASH_SPLIT_RE = re.compile(r"(?:——|——|--)")


def parse_summary(text):
    """从 away_summary 解析 (goal, next_step)，任一可能为 None"""
    if not text or not isinstance(text, str):
        return None, None

    # next_step
    next_step = None
    m = NEXT_RE.search(text)
    if m:
        next_step = m.group(1).strip(" ，,")

    # goal: 先找显式「目标是 / 目标：」
    goal = None
    m = GOAL_EXPLICIT_RE.search(text)
    if m:
        goal = m.group(1).strip(" ，,")
    else:
        # 退化：去掉「下一步...」整段后，取第一句（。前的部分）
        cleaned = re.sub(r"下一步[^。]*[。]?", "", text).strip()
        m2 = re.match(r"^(.+?)[。]", cleaned)
        if m2:
            goal = m2.group(1).strip()
        elif cleaned:
            goal = cleaned.strip()
        # 如果含「——」分隔，取后半段（如「你在做 BrainHaven——桌面置顶小窗」取「桌面置顶小窗」）
        if goal and "——" in goal:
            parts = DASH_SPLIT_RE.split(goal)
            if len(parts) >= 2 and parts[-1].strip():
                goal = parts[-1].strip()

    # 长度兜底
    if goal and len(goal) > 80:
        goal = goal[:78].rstrip() + "…"
    if next_step and len(next_step) > 80:
        next_step = next_step[:78].rstrip() + "…"
    return goal, next_step

# 这些前缀的 user 消息是 Claude Code 命令/系统注入，不是真的用户输入，过滤掉
USER_MSG_BLACKLIST_PREFIXES = (
    "<command-",
    "<local-command-",
    "<system-",
    "<bash-",
    "Caveat: ",
    "<user-prompt-submit-hook>",
)


def is_real_user_message(text: str) -> bool:
    if not text:
        return False
    t = text.lstrip()
    for p in USER_MSG_BLACKLIST_PREFIXES:
        if t.startswith(p):
            return False
    return True


def parse_jsonl(path: str):
    custom_title = None
    ai_title = None
    latest_slug = None
    first_user = None
    latest_recap = None  # away_summary 的 content

    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue

                t = o.get("type")
                if t == "custom-title" and isinstance(o.get("customTitle"), str):
                    custom_title = o["customTitle"]
                elif t == "ai-title" and isinstance(o.get("aiTitle"), str):
                    ai_title = o["aiTitle"]
                elif t == "system" and o.get("subtype") == "away_summary":
                    c = o.get("content")
                    if isinstance(c, str) and c.strip():
                        # 去掉 Claude 自带的 "(disable recaps in /config)" 提示
                        cleaned = c.replace(CLAUDE_HINT_RE, "").strip()
                        if cleaned:
                            latest_recap = cleaned
                elif isinstance(o.get("slug"), str):
                    latest_slug = o["slug"]
                elif t == "user" and first_user is None:
                    msg = o.get("message", {})
                    c = msg.get("content", "")
                    candidate = None
                    if isinstance(c, list):
                        for blk in c:
                            if isinstance(blk, dict):
                                txt = blk.get("text") or blk.get("input", "")
                                if isinstance(txt, str) and txt.strip():
                                    candidate = txt
                                    break
                    elif isinstance(c, str) and c.strip():
                        candidate = c
                    if candidate and is_real_user_message(candidate):
                        first_user = candidate
    except FileNotFoundError:
        pass

    title = custom_title or ai_title or latest_slug or first_user
    return title, latest_recap


def empty_result():
    return {
        "title": None, "recap": None,
        "auto_goal": None, "auto_next": None,
        "jsonl": None, "sessionId": None, "cwd": None, "mtime": None,
    }


def package(jsonl_path: str, sessionId: str = None, cwd: str = None):
    title, recap = parse_jsonl(jsonl_path)
    if title and len(title) > 60:
        title = title[:58].rstrip() + "…"
    if title:
        title = title.replace("\n", " ").replace("\r", " ").strip()
    if recap:
        recap = recap.replace("\r", "").strip()
    auto_goal, auto_next = parse_summary(recap)
    mtime = None
    try:
        mtime = int(os.path.getmtime(jsonl_path))
    except Exception:
        pass
    return {
        "title": title,
        "recap": recap,
        "auto_goal": auto_goal,
        "auto_next": auto_next,
        "jsonl": os.path.basename(jsonl_path),
        "sessionId": sessionId or os.path.splitext(os.path.basename(jsonl_path))[0],
        "cwd": cwd,
        "mtime": mtime,
    }


def resolve_by_pid(pid: str):
    home = os.path.expanduser("~")
    sf = f"{home}/.claude/sessions/{pid}.json"
    if not os.path.exists(sf):
        return empty_result()
    try:
        with open(sf, "r", encoding="utf-8") as f:
            meta = json.load(f)
    except Exception:
        return empty_result()
    cwd = meta.get("cwd", "")
    sid = meta.get("sessionId", "")
    if not cwd or not sid:
        return empty_result()
    jsonl = f"{home}/.claude/projects/{escape_cwd(cwd)}/{sid}.jsonl"
    if not os.path.exists(jsonl):
        return empty_result()
    return package(jsonl, sessionId=sid, cwd=cwd)


def resolve_by_cwd(cwd: str):
    home = os.path.expanduser("~")
    proj_dir = f"{home}/.claude/projects/{escape_cwd(cwd)}"
    if not os.path.isdir(proj_dir):
        return empty_result()
    candidates = glob.glob(f"{proj_dir}/*.jsonl")
    if not candidates:
        return empty_result()
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return package(candidates[0], cwd=cwd)


def resolve_by_jsonl(path: str):
    if not os.path.exists(path):
        return empty_result()
    return package(path)


if __name__ == "__main__":
    args = sys.argv[1:]
    result = empty_result()
    if not args:
        print(json.dumps({"error": "usage: --pid PID | --cwd CWD | --jsonl PATH | CWD"}))
        sys.exit(1)
    if args[0] == "--pid" and len(args) >= 2:
        result = resolve_by_pid(args[1])
    elif args[0] == "--cwd" and len(args) >= 2:
        result = resolve_by_cwd(args[1])
    elif args[0] == "--jsonl" and len(args) >= 2:
        result = resolve_by_jsonl(args[1])
    else:
        # 兼容老调用：extract-recap.py /some/cwd
        result = resolve_by_cwd(args[0])
    print(json.dumps(result, ensure_ascii=False))
