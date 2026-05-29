---
description: 把当前 Claude Code 会话在 BrainHaven 浮窗里的卡片归档
argument-hint: "[sessionId-前缀，可选]"
---

跑下面这条命令，把脚本的输出原样转给用户即可：

```
python3 "${BRAINHAVEN_HOME:-$HOME/Documents/whimsical/BrainHaven}/scripts/bh-done.py" $ARGUMENTS
```

- 不传参数时，脚本从 `$CLAUDE_CODE_SESSION_ID` 自动识别当前会话
- 传一个 sessionId 前缀（如 `f5384d82`）时，归档指定会话的卡
- 退出码非 0 时，把 stderr 内容原样给用户，别自己再去读 tasks.json
- 仓库不在默认路径？设 `export BRAINHAVEN_HOME=/path/to/BrainHaven` 即可覆盖
