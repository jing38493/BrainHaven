// BrainHaven UI - vanilla JS
// 数据流：Lua bootstrap(json) → state → render
// 改动：state 变化 → POST /save → Lua 写文件

(function () {
  const state = {
    tasks: [],
    archive: [],
    dismissed_keys: [],
    settings: {},
    editingId: null,
  };

  // ─── DOM refs ────────────────────────────────────
  const $list      = document.getElementById('bh-list');
  const $empty     = document.getElementById('bh-empty');
  const $count     = document.getElementById('bh-count');
  const $archive   = document.getElementById('bh-archive');
  const $archCnt   = document.getElementById('bh-archive-count');
  const $archBtn   = document.getElementById('bh-archive-toggle');
  const $addBtn    = document.getElementById('bh-add');
  const $modal     = document.getElementById('bh-modal');
  const $modalTit  = document.getElementById('bh-modal-title');
  const $fTitle    = document.getElementById('bh-f-title');
  const $fGoal     = document.getElementById('bh-f-goal');
  const $fNext     = document.getElementById('bh-f-next');
  const $fTag      = document.getElementById('bh-f-tag');
  const $fTotal       = document.getElementById('bh-f-total');
  const $fDone        = document.getElementById('bh-f-done');
  const $fDoneDisplay = document.getElementById('bh-f-done-display');
  const $fCurrent     = document.getElementById('bh-f-current');
  const $mSave     = document.getElementById('bh-modal-save');
  const $mCancel   = document.getElementById('bh-modal-cancel');

  // ─── persistence bridge ──────────────────────────
  function save() {
    const payload = JSON.stringify({
      tasks: state.tasks,
      archive: state.archive,
      dismissed_keys: state.dismissed_keys,
      settings: state.settings,
    });
    fetch('http://127.0.0.1:7787/save', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: payload,
    }).catch(err => console.warn('save failed', err));
  }

  // ─── refresh status (spinner / 几秒前更新) ──────
  let _lastUpdateMs = null;
  let _loading = false;

  function fmtAgo(ms) {
    const diff = Math.max(0, Math.floor((Date.now() - ms) / 1000));
    if (diff < 5)     return '刚刚';
    if (diff < 60)    return diff + ' 秒前';
    if (diff < 3600)  return Math.floor(diff / 60) + ' 分钟前';
    if (diff < 86400) return Math.floor(diff / 3600) + ' 小时前';
    return '> 1 天前';
  }

  function renderStatus() {
    const $s = document.getElementById('bh-status');
    if (!$s) return;
    if (_loading) {
      $s.innerHTML = '<span class="spinner">↻</span><span>更新中</span>';
    } else if (_lastUpdateMs) {
      $s.textContent = fmtAgo(_lastUpdateMs);
    } else {
      $s.textContent = '';
    }
  }

  // Lua reconcile 开始时调用
  window.bhSetLoading = function (on) {
    _loading = !!on;
    renderStatus();
  };

  // Lua reconcile 结束时调用（unixSeconds）
  window.bhSetLastUpdate = function (unixSeconds) {
    _lastUpdateMs = (typeof unixSeconds === 'number')
      ? unixSeconds * 1000
      : Date.now();
    renderStatus();
  };

  // 每 1 秒刷一下，让"X 秒前"能逐秒跳动
  setInterval(renderStatus, 1000);

  window.bootstrap = function (data) {
    try {
      if (typeof data === 'string') data = JSON.parse(data);
      state.tasks          = data.tasks          || [];
      state.archive        = data.archive        || [];
      state.dismissed_keys = data.dismissed_keys || [];
      state.settings       = data.settings       || {};
      render();
    } catch (e) {
      console.error('bootstrap failed', e);
    }
  };

  // ─── render ──────────────────────────────────────
  function render() {
    const sorted = [...state.tasks].sort((a, b) => {
      if (a.status !== b.status) {
        if (a.status === 'active') return -1;
        if (b.status === 'active') return  1;
      }
      // auto 卡片在前
      if ((a.source === 'auto') !== (b.source === 'auto')) {
        return a.source === 'auto' ? -1 : 1;
      }
      return (b.updated_at || '').localeCompare(a.updated_at || '');
    });

    $list.innerHTML = '';
    if (sorted.length === 0) {
      $empty.classList.remove('hidden');
    } else {
      $empty.classList.add('hidden');
      for (const t of sorted) $list.appendChild(renderCard(t));
    }
    $count.textContent = sorted.filter(t => t.status === 'active').length;

    $archCnt.textContent = state.archive.length;
    $archive.innerHTML = '';
    for (const a of state.archive.slice().reverse()) {
      const row = document.createElement('div');
      row.className = 'bh-archive-item';
      const reasonTxt = a.reason === 'session ended' ? ' · 已离线' : '';
      row.innerHTML = `<span>✓ ${escapeHtml(a.title)}${reasonTxt}</span><span class="ts">${fmtTime(a.done_at)}</span>`;
      $archive.appendChild(row);
    }
  }

  function renderCard(t) {
    const el = document.createElement('div');
    const isAuto = t.source === 'auto';
    el.className = `bh-card ${t.status === 'paused' ? 'paused' : ''} ${t.tag ? 'tag-' + t.tag : ''} ${isAuto ? 'auto' : ''}`;
    el.dataset.id = t.id;
    if (isAuto && t.cwd) el.title = `${t.tool} · ${t.cwd}`;

    const tagHtml = t.tag ? `<span class="bh-tag ${t.tag}">${t.tag}</span>` : '';
    const sourceIcon = isAuto ? '<span class="bh-src" title="自动检测">🤖</span>' : '';
    const playPauseIcon = t.status === 'paused' ? '▶' : '⏸';
    const playPauseTitle = t.status === 'paused' ? '继续' : '暂停';
    const goalDisplay = t.goal && t.goal.trim() ? escapeHtml(t.goal) : '<span class="dim">点 ✎ 写目标</span>';
    const nextDisplay = t.next_step && t.next_step.trim() ? escapeHtml(t.next_step) : '<span class="dim">点 ✎ 写下一步</span>';

    const subtitleHtml = t.subtitle
      ? `<div class="bh-card-subtitle">${escapeHtml(t.subtitle)}</div>`
      : '';
    const progressHtml = t.progress && t.progress.total
      ? (() => {
          const isManual = t.progress.source === 'manual';
          const tipText  = isManual ? '✏️ 手动设置' : (t.progress.file || 'plan.md');
          const icon     = isManual ? '✏️' : '📊';
          return `<div class="bh-card-progress ${isManual ? 'manual' : ''}" title="${escapeHtml(tipText)}">
            <div class="bh-progress-bar"><div class="bh-progress-fill" style="width:${t.progress.percent}%"></div></div>
            <div class="bh-progress-meta">
              <span class="bh-progress-pct">${icon} ${t.progress.percent}%</span>
              <span class="bh-progress-count">${t.progress.done}/${t.progress.total}</span>
            </div>
            ${t.progress.current ? `<div class="bh-progress-step">当前：${escapeHtml(t.progress.current)}</div>` : ''}
          </div>`;
        })()
      : '';
    const recapHtml = t.recap
      ? `<div class="bh-card-recap"><span class="bh-recap-icon">📝</span>${escapeHtml(t.recap)}</div>`
      : '';

    el.innerHTML = `
      <div class="bh-card-title">
        ${sourceIcon}
        <span class="bh-card-title-text">${escapeHtml(t.title)}</span>
        ${tagHtml}
      </div>
      ${subtitleHtml}
      ${progressHtml}
      ${recapHtml}
      <div class="bh-card-row"><span class="icon">🎯</span><span>${goalDisplay}</span></div>
      <div class="bh-card-row"><span class="icon">➡</span><span>${nextDisplay}</span></div>
      <div class="bh-card-actions">
        <button class="bh-act" data-act="done" title="完成">✓</button>
        <button class="bh-act" data-act="edit" title="编辑">✎</button>
        <button class="bh-act" data-act="toggle" title="${playPauseTitle}">${playPauseIcon}</button>
        ${isAuto ? '' : '<button class="bh-act" data-act="delete" title="删除">×</button>'}
      </div>
    `;

    el.querySelectorAll('.bh-act').forEach(btn => {
      btn.addEventListener('click', (e) => {
        const act = btn.dataset.act;
        if (act === 'done')   markDone(t.id);
        if (act === 'edit')   openModal(t.id);
        if (act === 'toggle') togglePause(t.id);
        if (act === 'delete') deleteTask(t.id);
        e.stopPropagation();
      });
    });

    // 点卡片非按钮区 → 让 Lua 把对应终端窗口拉到前面
    if (isAuto && t.session_key) {
      el.classList.add('clickable');
      el.addEventListener('click', (e) => {
        if (e.target.closest('.bh-act')) return;
        focusSession(t.session_key, el);
      });
    }

    return el;
  }

  function focusSession(sessionKey, cardEl) {
    if (cardEl) cardEl.classList.add('focusing');
    fetch('http://127.0.0.1:7787/focus', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ session_key: sessionKey }),
    })
      .then(r => r.text().then(t => ({ ok: r.ok, body: t })))
      .then(({ ok, body }) => {
        if (cardEl) {
          if (!ok) {
            cardEl.classList.remove('focusing');
            cardEl.classList.add('focus-fail');
            cardEl.title = '聚焦失败：' + body;
            setTimeout(() => cardEl.classList.remove('focus-fail'), 1200);
          } else {
            setTimeout(() => cardEl.classList.remove('focusing'), 400);
          }
        }
      })
      .catch(err => {
        if (cardEl) {
          cardEl.classList.remove('focusing');
          cardEl.classList.add('focus-fail');
          setTimeout(() => cardEl.classList.remove('focus-fail'), 1200);
        }
        console.warn('focus failed', err);
      });
  }

  // ─── actions ─────────────────────────────────────
  function markDone(id) {
    const idx = state.tasks.findIndex(t => t.id === id);
    if (idx === -1) return;
    const t = state.tasks[idx];

    // auto 卡片：除了归档，还把 key 加进 dismissed_keys，避免下次 reconcile 重建
    if (t.source === 'auto' && t.session_key && !state.dismissed_keys.includes(t.session_key)) {
      state.dismissed_keys.push(t.session_key);
    }

    state.archive.push({
      id: t.id,
      title: t.title,
      goal: t.goal,
      next_step: t.next_step,
      tag: t.tag,
      done_at: nowIso(),
    });
    state.tasks.splice(idx, 1);
    render();
    save();
  }

  function togglePause(id) {
    const t = state.tasks.find(x => x.id === id);
    if (!t) return;
    t.status = t.status === 'paused' ? 'active' : 'paused';
    t.updated_at = nowIso();
    render();
    save();
  }

  function deleteTask(id) {
    state.tasks = state.tasks.filter(t => t.id !== id);
    render();
    save();
  }

  function openModal(id) {
    state.editingId = id;
    const t = id ? state.tasks.find(x => x.id === id) : null;
    $modalTit.textContent = t ? '编辑卡片' : '新卡片';
    $fTitle.value = t ? t.title : '';
    $fGoal.value  = t ? t.goal  : '';
    $fNext.value  = t ? t.next_step : '';
    $fTag.value   = t ? (t.tag || '') : '';
    const isManual = t && t.progress && t.progress.source === 'manual';
    const presetTotal = isManual ? (t.progress.total ?? 0) : 0;
    const presetDone  = isManual ? (t.progress.done  ?? 0) : 0;
    $fTotal.value   = presetTotal > 0 ? presetTotal : '';
    $fDone.max      = presetTotal;        // 必须先 set max 再 set value，否则被钳到 0
    $fDone.value    = presetDone;
    $fCurrent.value = isManual ? (t.progress.current ?? '') : '';
    syncProgressSlider();
    $modal.classList.remove('hidden');
    setTimeout(() => $fTitle.focus(), 50);
  }

  function syncProgressSlider() {
    const total = Math.max(0, parseInt($fTotal.value, 10) || 0);
    $fDone.max = total;
    let done = Math.max(0, parseInt($fDone.value, 10) || 0);
    if (done > total) { done = total; $fDone.value = total; }
    if (total === 0) {
      $fDoneDisplay.textContent = '先填总步骤';
      $fDoneDisplay.classList.add('dim');
      $fDone.disabled = true;
    } else {
      const pct = Math.round(done / total * 100);
      $fDoneDisplay.textContent = `${done} / ${total} · ${pct}%`;
      $fDoneDisplay.classList.remove('dim');
      $fDone.disabled = false;
      // 同步进度条的 fill 颜色比例（CSS 变量驱动）
      const fillPct = (done / total) * 100;
      $fDone.style.setProperty('--fill', fillPct + '%');
    }
  }

  function closeModal() {
    state.editingId = null;
    $modal.classList.add('hidden');
  }

  function saveModal() {
    const title = $fTitle.value.trim();
    if (!title) { $fTitle.focus(); return; }
    const goal  = $fGoal.value.trim();
    const next  = $fNext.value.trim();
    const tag   = $fTag.value;

    const totalRaw = $fTotal.value.trim();
    const doneRaw  = $fDone.value.trim();
    const currentRaw = $fCurrent.value.trim();
    const total = totalRaw ? Math.max(1, parseInt(totalRaw, 10) || 0) : null;
    const done  = doneRaw  ? Math.max(0, parseInt(doneRaw,  10) || 0) : null;
    let manualProgress = null;
    if (total != null || done != null || currentRaw) {
      const safeTotal = total ?? (done != null ? Math.max(done, 1) : 1);
      const safeDone  = Math.min(done ?? 0, safeTotal);
      manualProgress = {
        total:   safeTotal,
        done:    safeDone,
        current: currentRaw || null,
        percent: Math.round((safeDone / safeTotal) * 100),
        source:  'manual',
      };
    }

    if (state.editingId) {
      const t = state.tasks.find(x => x.id === state.editingId);
      if (t) {
        t.title = title; t.goal = goal; t.next_step = next; t.tag = tag;
        if (manualProgress) {
          t.progress = manualProgress;
        } else if (t.progress && t.progress.source === 'manual') {
          // 用户清空了进度字段 → 撤回手动模式，让 plan.md 自动接管（或不显示）
          delete t.progress;
        }
        t.updated_at = nowIso();
      }
    } else {
      state.tasks.push({
        id: 'manual-' + Date.now(),
        title, goal, next_step: next, tag,
        progress: manualProgress || undefined,
        status: 'active',
        source: 'manual',
        created_at: nowIso(),
        updated_at: nowIso(),
      });
    }
    closeModal();
    render();
    save();
  }

  // ─── helpers ─────────────────────────────────────
  function nowIso() { return new Date().toISOString(); }
  function escapeHtml(s) {
    if (!s) return '';
    return String(s).replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
  }
  function fmtTime(iso) {
    if (!iso) return '';
    const d = new Date(iso);
    const hh = String(d.getHours()).padStart(2, '0');
    const mm = String(d.getMinutes()).padStart(2, '0');
    return `${hh}:${mm}`;
  }

  // ─── wire-up ─────────────────────────────────────
  $addBtn.addEventListener('click',   () => openModal(null));
  $mCancel.addEventListener('click',  closeModal);
  $mSave.addEventListener('click',    saveModal);
  $archBtn.addEventListener('click',  () => $archive.classList.toggle('hidden'));
  $fTotal.addEventListener('input',   syncProgressSlider);
  $fDone.addEventListener('input',    syncProgressSlider);

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && !$modal.classList.contains('hidden')) closeModal();
    if (e.key === 'Enter'  && !$modal.classList.contains('hidden') && e.metaKey) saveModal();
  });

  render();
})();
