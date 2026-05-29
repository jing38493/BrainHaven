-- BrainHaven · Hammerspoon module
-- 边缘自动隐藏浮窗 + 本地 httpserver + 文件监听 + agent session 自动检测
-- 用法：在 ~/.hammerspoon/init.lua 里写
--   _G.BH = dofile("/path/to/BrainHaven/hammerspoon/brainhaven.lua")
-- 必须 _G.BH = 接住返回值，否则 Lua GC 会把 timer 杀掉

local BH = {}

-- 自定位：brainhaven.lua 在 <BASE>/hammerspoon/ 下，根据自己的位置推 BASE
local function scriptDir()
  local src = debug.getinfo(1, "S").source
  if src:sub(1, 1) == "@" then src = src:sub(2) end
  return src:match("(.*/)") or "./"
end
-- 允许 BRAINHAVEN_HOME 环境变量手动覆盖
local BASE = os.getenv("BRAINHAVEN_HOME")
              or scriptDir():gsub("/hammerspoon/?$", "")

local UI_URL     = "file://" .. BASE .. "/ui/index.html"
local DATA_PATH  = BASE .. "/data/tasks.json"
local RECAP_PY   = BASE .. "/scripts/extract-recap.py"
local PORT       = 7787
local POLL_SEC   = 10

local webview        = nil
local watcher        = nil
local server         = nil
local poller         = nil
local mouseTimer     = nil
local hideTimer      = nil
local hidden         = true
local ignoreNextWatch = false
local liveSessionPids = {}  -- session_key → pid（每次 reconcile 重算）

-- ─── 检测的 agent CLI 模式 ───────────────────────
-- 每条 pattern 是 Lua 的字符串模式（不是正则）
-- 每个 tool 有 4 种匹配：起始 bare、起始带参数、绝对路径结尾、绝对路径带参数
local AGENT_TOOLS = { "claude", "codex", "aider", "opencode", "gemini" }
local AGENT_PATTERNS = {}
for _, tool in ipairs(AGENT_TOOLS) do
  table.insert(AGENT_PATTERNS, { tool = tool, pattern = "^" .. tool .. "$" })
  table.insert(AGENT_PATTERNS, { tool = tool, pattern = "^" .. tool .. "%s" })
  table.insert(AGENT_PATTERNS, { tool = tool, pattern = "/" .. tool .. "$" })
  table.insert(AGENT_PATTERNS, { tool = tool, pattern = "/" .. tool .. "%s" })
end
table.insert(AGENT_PATTERNS, { tool = "cursor", pattern = "cursor%-agent" })

-- 命令路径中包含以下任意子串则跳过（避开 .app 子进程 / 后台辅助进程）
-- 注意：claude-code-router 自己是 node 进程，模式要锁住 "node" 才不会误伤
-- 通过 ccr 路由过的 claude session（命令是 `claude --settings .../ccr-...`）
local SKIPS = {
  "%.app/Contents/",
  "/Sparkle%.framework/",
  "Updater%.app/",
  "node.*claude%-hud",
  "node.*claude%-code%-router",
}

-- ─── JSON 文件读写 ───────────────────────────────
local function loadRaw()
  local f = io.open(DATA_PATH, "r")
  if not f then return "{}" end
  local raw = f:read("*all")
  f:close()
  return raw
end

local function loadData()
  local raw = loadRaw()
  local ok, data = pcall(hs.json.decode, raw)
  if not ok or type(data) ~= "table" then
    return { tasks = {}, archive = {}, dismissed_keys = {}, settings = {} }
  end
  data.tasks          = data.tasks          or {}
  data.archive        = data.archive        or {}
  data.dismissed_keys = data.dismissed_keys or {}
  data.settings       = data.settings       or {}
  return data
end

local function saveData(data)
  local raw = hs.json.encode(data, true)
  ignoreNextWatch = true
  local f = io.open(DATA_PATH, "w")
  if not f then return false end
  f:write(raw)
  f:close()
  return true
end

local function writeRaw(raw)
  ignoreNextWatch = true
  local f = io.open(DATA_PATH, "w")
  if not f then return false end
  f:write(raw)
  f:close()
  return true
end

-- ─── 推数据到 webview ────────────────────────────
local function pushToWebview()
  if not webview then return end
  local raw = loadRaw()
  local js = "if (window.bootstrap) window.bootstrap(" .. raw .. ");"
  webview:evaluateJavaScript(js)
end

-- ─── 工具函数 ────────────────────────────────────
local function isoNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function basename(p)
  return (p:match("([^/]+)/?$")) or p
end

local FRESH_SECONDS = 7 * 24 * 60 * 60  -- 7 天没动的 jsonl 当僵尸过滤（终端废弃了）

-- ─── 边缘自动隐藏参数 ──────────────────────────
local HIDDEN_EDGE_PX = 4    -- 缩起后在屏幕内露多少 px
local HOT_ZONE_PX    = 2    -- 鼠标到屏幕左 N px 触发显示
local HIDE_AFTER_SEC = 2    -- 鼠标离开窗口 N 秒后缩回
local SLIDE_IN_DUR   = 0.18
local SLIDE_OUT_DUR  = 0.22
local MOUSE_POLL_SEC = 0.1

-- 调 python 脚本读 Claude Code 会话信息
-- mode = "--pid" | "--cwd" | "--jsonl"，arg 是对应的值
-- 返回 table {title, recap, jsonl, sessionId, cwd, mtime} 或 nil
local function getSessionInfo(mode, arg)
  if not arg or arg == "" then return nil end
  local safeArg = tostring(arg):gsub('"', '\\"')
  local cmd = string.format('python3 "%s" %s "%s" 2>/dev/null', RECAP_PY, mode, safeArg)
  local h = io.popen(cmd)
  if not h then return nil end
  local raw = h:read("*all")
  h:close()
  if not raw or raw == "" then return nil end
  local ok, data = pcall(hs.json.decode, raw)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

-- 判断 session 是否"新鲜"（jsonl mtime 在阈值内）
local function isFresh(info)
  if not info or not info.mtime then return false end
  return (os.time() - info.mtime) < FRESH_SECONDS
end

local function contains(t, v)
  for _, x in ipairs(t) do if x == v then return true end end
  return false
end

local function removeValue(t, v)
  for i = #t, 1, -1 do if t[i] == v then table.remove(t, i) end end
end

-- ─── ps + lsof + sessions/{pid}.json 检测活跃 session ──
-- 返回 list of { tool, pid, cwd, sessionId, jsonl, title, recap, key }
-- key 对 claude 用 sessionId（每个对话独立一张卡），对其他工具用 cwd
local function detectSessions()
  local sessions = {}
  local seenKey  = {}

  local h = io.popen("ps -axww -o pid=,command= 2>/dev/null")
  if not h then return sessions end

  local function isSkipped(cmd)
    for _, sk in ipairs(SKIPS) do
      if cmd:find(sk) then return true end
    end
    return false
  end

  local pidList = {}
  for line in h:lines() do
    local pid, cmd = line:match("^%s*(%d+)%s+(.*)$")
    if pid and cmd and not isSkipped(cmd) then
      for _, p in ipairs(AGENT_PATTERNS) do
        if cmd:find(p.pattern) then
          table.insert(pidList, { pid = pid, tool = p.tool })
          break
        end
      end
    end
  end
  h:close()

  if #pidList == 0 then return sessions end

  -- 批量拿 cwd
  local pids = {}
  for _, p in ipairs(pidList) do table.insert(pids, p.pid) end
  local lsofCmd = "lsof -a -p " .. table.concat(pids, ",") .. " -d cwd -Fpn 2>/dev/null"
  local h2 = io.popen(lsofCmd)
  if not h2 then return sessions end

  local cwdByPid = {}
  local currentPid = nil
  for line in h2:lines() do
    local prefix = line:sub(1,1)
    if prefix == "p" then
      currentPid = line:sub(2)
    elseif prefix == "n" and currentPid then
      cwdByPid[currentPid] = line:sub(2)
    end
  end
  h2:close()

  for _, p in ipairs(pidList) do
    local cwd = cwdByPid[p.pid]
    if cwd then
      local key, info
      if p.tool == "claude" then
        -- 走 --pid 模式拿 sessionId + recap
        info = getSessionInfo("--pid", p.pid)
        -- 没 sessionId 或 jsonl 过期（>1h）的当僵尸过滤掉
        if info and info.sessionId and isFresh(info) then
          key = p.tool .. ":" .. info.sessionId
        end
      else
        -- 非 claude（codex/aider 等）：sessions 文件没有，退化按 cwd
        info = getSessionInfo("--cwd", cwd)
        key = p.tool .. ":" .. cwd
      end

      if key and not seenKey[key] then
        seenKey[key] = true
        table.insert(sessions, {
          tool      = p.tool,
          pid       = p.pid,
          cwd       = cwd,
          sessionId = info and info.sessionId or nil,
          jsonl     = info and info.jsonl or nil,
          title     = info and info.title or nil,
          recap     = info and info.recap or nil,
          mtime     = info and info.mtime or nil,
          key       = key,
        })
      end
    end
  end

  return sessions
end

-- ─── pid → 终端窗口聚焦 ─────────────────────────
-- 预热 osascript（首次 applescript() 会加载 OSAKit，~200ms 卡顿，立刻打一次 no-op）
pcall(hs.osascript.applescript, "return 1")

local function getTtyOfPid(pid)
  local h = io.popen(string.format("ps -o tty= -p %s 2>/dev/null", pid))
  if not h then return nil end
  local tty = h:read("*line")
  h:close()
  if not tty then return nil end
  tty = tty:gsub("^%s+", ""):gsub("%s+$", "")
  return tty ~= "" and tty or nil
end

-- 顺着进程父链找终端 app 名（iTerm2 / Terminal / Warp / ...）
local function findTerminalApp(pid)
  local cur = tostring(pid)
  for _ = 1, 8 do
    local h = io.popen("ps -p " .. cur .. " -o ppid=,command= 2>/dev/null")
    if not h then return nil end
    local line = h:read("*line")
    h:close()
    if not line then return nil end
    local ppid, cmd = line:match("^%s*(%d+)%s+(.+)$")
    if not ppid then return nil end
    if cmd:find("iTerm") or cmd:find("iTermServer") then return "iTerm" end
    if cmd:find("Terminal%.app") then return "Terminal" end
    if cmd:find("Warp%.app") then return "Warp" end
    if cmd:find("Alacritty") then return "Alacritty" end
    if cmd:find("kitty") then return "kitty" end
    if cmd:find("Ghostty") then return "Ghostty" end
    if ppid == "1" then return nil end
    cur = ppid
  end
  return nil
end

local function focusITermTty(tty)
  local script = string.format([[
    tell application "iTerm"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if (tty of s) ends with "%s" then
              select w
              select t
              select s
              return
            end if
          end repeat
        end repeat
      end repeat
    end tell
  ]], tty)
  hs.osascript.applescript(script)
end

local function focusTerminalTty(tty)
  local script = string.format([[
    tell application "Terminal"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          if (tty of t) ends with "%s" then
            set selected of t to true
            set frontmost of w to true
            return
          end if
        end repeat
      end repeat
    end tell
  ]], tty)
  hs.osascript.applescript(script)
end

local function focusSession(sessionKey)
  local pid = liveSessionPids[sessionKey]
  if not pid then return false, "no live pid for " .. sessionKey end
  local tty = getTtyOfPid(pid)
  if not tty then return false, "no tty for pid " .. pid end
  local app = findTerminalApp(pid)
  if app == "iTerm" then
    focusITermTty(tty); return true
  elseif app == "Terminal" then
    focusTerminalTty(tty); return true
  elseif app then
    -- 退化：至少把那个 app 拉到前面
    hs.application.launchOrFocus(app)
    return false, "no tty-level switch for " .. app .. " (activated app only)"
  end
  return false, "unknown terminal app"
end

-- ─── UI 加载状态推送 ────────────────────────────
local function setLoading(on)
  if not webview then return end
  pcall(function()
    webview:evaluateJavaScript(
      "if (window.bhSetLoading) window.bhSetLoading(" .. (on and "true" or "false") .. ");"
    )
  end)
end

local function pushLastUpdate()
  if not webview then return end
  pcall(function()
    webview:evaluateJavaScript(
      "if (window.bhSetLastUpdate) window.bhSetLastUpdate(" .. os.time() .. ");"
    )
  end)
end

-- ─── 调和：检测结果 ↔ tasks.json ────────────────
local function reconcile()
  setLoading(true)
  local sessions = detectSessions()
  -- 顺手更新 session_key → pid 映射，给 focus 用
  liveSessionPids = {}
  for _, s in ipairs(sessions) do
    liveSessionPids[s.key] = s.pid
  end
  local data = loadData()

  -- 当前活跃 key 集合
  local liveKeys = {}
  for _, s in ipairs(sessions) do liveKeys[s.key] = s end

  -- 1. 已有 auto 卡片：在线则保留并刷新 title/recap，掉线则归档
  local kept = {}
  for _, t in ipairs(data.tasks) do
    if t.source == "auto" then
      local liveSession = liveKeys[t.session_key]
      if liveSession then
        liveSession.matched = true
        -- 用 detectSessions 已经拿到的信息刷新
        if liveSession.title and liveSession.title ~= t.title then
          t.title = liveSession.title
          t.updated_at = isoNow()
        end
        if liveSession.recap ~= t.recap then
          t.recap = liveSession.recap
          t.updated_at = isoNow()
        end
        if not t.subtitle or t.subtitle == "" then
          t.subtitle = t.tool .. " · " .. basename(t.cwd)
        end
        -- 补齐 sessionId 字段（老卡片可能没有）
        if liveSession.sessionId and not t.sessionId then
          t.sessionId = liveSession.sessionId
        end
        table.insert(kept, t)
      else
        table.insert(data.archive, {
          id        = t.id,
          title     = t.title,
          subtitle  = t.subtitle,
          recap     = t.recap,
          goal      = t.goal,
          next_step = t.next_step,
          tag       = t.tag,
          done_at   = isoNow(),
          reason    = "session ended",
        })
      end
    else
      table.insert(kept, t)
    end
  end
  data.tasks = kept

  -- 2. 新 session 且不在 dismissed：建卡
  for key, s in pairs(liveKeys) do
    if not s.matched and not contains(data.dismissed_keys, key) then
      local subtitle = s.tool .. " · " .. basename(s.cwd)
      table.insert(data.tasks, {
        id          = "auto-" .. os.time() .. "-" .. math.random(1000, 9999),
        title       = s.title or subtitle,
        subtitle    = subtitle,
        recap       = s.recap,
        goal        = "",
        next_step   = "",
        status      = "active",
        tag         = "工作",
        source      = "auto",
        session_key = key,
        sessionId   = s.sessionId,
        tool        = s.tool,
        cwd         = s.cwd,
        created_at  = isoNow(),
        updated_at  = isoNow(),
      })
    end
  end

  -- 3. dismissed_keys 清理：session 已离线的从 dismiss 列表移除
  for i = #data.dismissed_keys, 1, -1 do
    if not liveKeys[data.dismissed_keys[i]] then
      table.remove(data.dismissed_keys, i)
    end
  end

  saveData(data)
  pushToWebview()
  -- 留一小段时间让旋转看得见，再关掉 loading + 推 lastUpdate
  hs.timer.doAfter(0.3, function()
    setLoading(false)
    pushLastUpdate()
  end)
end

-- ─── httpserver: 接收 UI 写回 ────────────────────
local function startServer()
  server = hs.httpserver.new()
  server:setPort(PORT)
  server:setCallback(function(method, path, headers, body)
    local cors = {
      ["Access-Control-Allow-Origin"]  = "*",
      ["Access-Control-Allow-Headers"] = "Content-Type",
      ["Access-Control-Allow-Methods"] = "POST, OPTIONS",
    }
    if method == "OPTIONS" then return "", 204, cors end
    if method == "POST" and path == "/save" then
      local ok = writeRaw(body)
      return ok and "ok" or "fail", ok and 200 or 500, cors
    end
    if method == "POST" and path == "/focus" then
      local ok, payload = pcall(hs.json.decode, body)
      local key = ok and payload and payload.session_key or nil
      if not key then return "missing session_key", 400, cors end
      local fok, ferr = focusSession(key)
      return fok and "ok" or (ferr or "fail"), fok and 200 or 500, cors
    end
    return "not found", 404, cors
  end)
  server:start()
end

-- ─── pathwatcher: 外部改动刷新 UI ────────────────
local function startWatcher()
  watcher = hs.pathwatcher.new(DATA_PATH, function()
    if ignoreNextWatch then
      ignoreNextWatch = false
      return
    end
    pushToWebview()
  end)
  watcher:start()
end

-- ─── 关掉可能残留的浮窗（reload 后重启需要） ──────
local function killStaleWindows()
  for _, w in ipairs(hs.window.allWindows() or {}) do
    if w:title() == "BrainHaven" then
      w:close()
    end
  end
end

-- ─── 边缘自动隐藏 ──────────────────────────────
local function windowFrames(screen, width)
  local sf = screen:frame()
  return {
    shown  = { x = sf.x,                            y = sf.y, w = width, h = sf.h },
    hidden = { x = sf.x - (width - HIDDEN_EDGE_PX), y = sf.y, w = width, h = sf.h },
  }
end

local function getWidth()
  local s = (loadData().settings or {})
  return (s.size and s.size.w) or 360
end

local function slideIn()
  if not webview or not hidden then return end
  hidden = false
  local rects = windowFrames(hs.screen.primaryScreen(), getWidth())
  local w = webview:hswindow()
  if w then pcall(function() w:setFrame(rects.shown, SLIDE_IN_DUR) end) end
end

local function slideOut()
  if not webview or hidden then return end
  hidden = true
  local rects = windowFrames(hs.screen.primaryScreen(), getWidth())
  local w = webview:hswindow()
  if w then pcall(function() w:setFrame(rects.hidden, SLIDE_OUT_DUR) end) end
end

local function mouseInWidget(p, screen, width)
  local sf = screen:frame()
  return p.x >= sf.x and p.x <= sf.x + width
     and p.y >= sf.y and p.y <= sf.y + sf.h
end

local function mouseAtHotZone(p, screen)
  local sf = screen:frame()
  return p.x >= sf.x and p.x <= sf.x + HOT_ZONE_PX
     and p.y >= sf.y and p.y <= sf.y + sf.h
end

local function checkMouseTick()
  if not webview then return end
  local ok, p = pcall(hs.mouse.absolutePosition)
  if not ok or not p then return end
  local screen = hs.screen.primaryScreen()
  local width = getWidth()

  if hidden then
    if mouseAtHotZone(p, screen) then slideIn() end
  else
    if mouseInWidget(p, screen, width) then
      if hideTimer then hideTimer:stop(); hideTimer = nil end
    elseif not hideTimer then
      hideTimer = hs.timer.doAfter(HIDE_AFTER_SEC, function()
        slideOut()
        hideTimer = nil
      end)
    end
  end
end

local function startMouseWatcher()
  if mouseTimer then mouseTimer:stop() end
  mouseTimer = hs.timer.doEvery(MOUSE_POLL_SEC, function()
    local ok, err = pcall(checkMouseTick)
    if not ok then print("[BrainHaven] mouse err:", err) end
  end)
end

-- ─── 浮窗 ─────────────────────────────────────────
local function createWebview()
  killStaleWindows()

  local width = getWidth()
  local screen = hs.screen.primaryScreen()
  local rects = windowFrames(screen, width)
  -- 一开始就隐藏（只露 4px 在屏幕内）
  hidden = true

  webview = hs.webview.new(
    rects.hidden,
    {
      developerExtrasEnabled = true,
      javaScriptEnabled      = true,
    }
  )

  -- 用 borderless 风格，没有 title bar 占空间；用 floating level 永远置顶
  webview:windowStyle({ "borderless", "nonactivating" })
       :level(hs.drawing.windowLevels.floating)
       :allowGestures(true)
       :allowTextEntry(true)
       :bringToFront(true)
       :transparent(false)
       :windowTitle("BrainHaven")
       :url(UI_URL)

  webview:navigationCallback(function(action)
    if action == "didFinishNavigation" then
      pushToWebview()
      hs.timer.doAfter(0.5, reconcile)
    end
  end)

  webview:show()

  -- 强制把窗口移到主屏（防 NSWindow autosave 把它放到副屏），并保持隐藏状态
  local function placeAtHidden()
    if not webview then return end
    local w = webview:hswindow()
    if w then
      pcall(function()
        w:moveToScreen(screen, false, true, 0)
        w:setFrame(rects.hidden, 0)
        w:raise()
      end)
    end
  end
  placeAtHidden()
  for _, dt in ipairs({0.1, 0.3, 0.6, 1.2}) do
    hs.timer.doAfter(dt, placeAtHidden)
  end
end

-- ─── 起轮询 ─────────────────────────────────────
local function startPoller()
  poller = hs.timer.doEvery(POLL_SEC, function()
    local ok, err = pcall(reconcile)
    if not ok then print("[BrainHaven] reconcile err:", err) end
  end)
end

-- ─── 公开 API ────────────────────────────────────
function BH.start()
  if webview then return end
  startServer()
  startWatcher()
  createWebview()
  startPoller()
  startMouseWatcher()
  hs.alert.show("🌸 BrainHaven on", 1)
end

function BH.stop()
  if mouseTimer then mouseTimer:stop(); mouseTimer = nil end
  if hideTimer  then hideTimer:stop();  hideTimer  = nil end
  if poller     then poller:stop();     poller     = nil end
  if webview    then webview:delete();  webview    = nil end
  if watcher    then watcher:stop();    watcher    = nil end
  if server     then server:stop();     server     = nil end
end

function BH.reload()
  BH.stop()
  BH.start()
end

function BH.scanNow() reconcile() end
function BH.slideIn()  slideIn()  end
function BH.slideOut() slideOut() end
function BH.focus(key) return focusSession(key) end
BH.base = BASE  -- 暴露 BASE，调试时 hs -c "print(_G.BH.base)" 就能看

-- 调试用：让外部 hs cli 能调 JS
function BH.evalJS(js)
  if not webview then return "no webview" end
  return webview:evaluateJavaScript(js)
end

BH.start()
return BH
