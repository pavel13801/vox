// Vox web — UI (hash router, views, delegated actions).
import { esc, fmt, trim, toast, shareOrDownload, isIOS, isStandalone, extForMime, uuid } from './util.js';
import { store, conv, newConversation, STATUS_LABEL } from './store.js';
import { settings, PROVIDERS, LLM_PROVIDERS, BATCH_PROVIDERS, LANGUAGES, SUMMARY_LANGUAGES } from './settings.js';
import { recorder } from './recorder.js';
import { processing } from './processing.js';
import { TEMPLATES, template, chat } from './ai.js';
import { listModels, complete } from './llm.js';
import { verifyDeepgram } from './stt.js';
import { omi } from './omi.js';
import { md } from './markdown.js';

const $view = document.getElementById('view');
const $recbar = document.getElementById('recbar');
const $tabs = document.getElementById('tabs');
const $modal = document.getElementById('modal-root');

const ui = {
  search: '',
  starredOnly: false,
  category: null,
  detailTab: 'summary',
  taskFilter: 'open',
  memSearch: '',
  drafts: {},
  models: {},          // provider -> loaded list
  modelsLoading: null,
  keyTest: {},         // provider -> {ok, text, busy}
  storage: '',
  hideInstall: localStorage.getItem('vox.hideInstall') === '1',
};

const SPEAKER_COLORS = ['#3b82f6', '#f97316', '#22c55e', '#a855f7', '#ec4899', '#14b8a6', '#6366f1', '#a16207', '#ef4444', '#10b981'];
const spColor = (n) => SPEAKER_COLORS[Math.abs(n) % SPEAKER_COLORS.length];
const SOURCE = { phone: ['📱', 'Микрофон'], omi: ['⭕️', 'Omi'], imported: ['📥', 'Импорт'] };

// ---------------------------------------------------------------- audio player (persistent element)

const player = document.createElement('audio');
player.controls = true;
player.preload = 'metadata';
player.setAttribute('playsinline', '');
player.className = 'player';
let playerFor = null, playerURL = null;

async function attachPlayer(id) {
  const slot = document.getElementById('player-slot');
  if (!slot) return;
  if (playerFor !== id) {
    playerFor = id;
    if (playerURL) URL.revokeObjectURL(playerURL);
    playerURL = null;
    player.removeAttribute('src');
    const blob = await store.getAudio(id);
    if (playerFor !== id) return;
    if (blob) { playerURL = URL.createObjectURL(blob); player.src = playerURL; }
  }
  if (playerURL && slot.firstChild !== player) slot.appendChild(player);
  slot.classList.toggle('hidden', !playerURL);
}

// ---------------------------------------------------------------- routing & render

const route = () => location.hash.replace(/^#\/?/, '').split('/').filter(Boolean).map(decodeURIComponent);
const go = (path) => { location.hash = '#/' + path; };

let scheduled = false;
function render() {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => { scheduled = false; doRender(); });
}

let lastRouteKey = '';
function doRender() {
  const parts = route();
  const key = parts.join('/');
  const sameRoute = key === lastRouteKey;
  const scroll = sameRoute ? $view.scrollTop : 0;
  const active = document.activeElement;
  const focusId = active && active.id && $view.contains(active) ? active.id : null;
  const sel = focusId && 'selectionStart' in active ? [active.selectionStart, active.selectionEnd] : null;

  let html, tab = parts[0] || 'home';
  switch (parts[0]) {
    case 'c': html = parts[2] === 'chat' ? viewChat(parts[1]) : viewDetail(parts[1]); tab = 'home'; break;
    case 'live': html = viewLive(); tab = 'home'; break;
    case 'tasks': html = viewTasks(); break;
    case 'chat': html = viewChat(null); break;
    case 'memory': html = viewMemory(); break;
    case 'settings':
      tab = 'settings';
      html = parts[1] === 'key' ? viewKey(parts[2]) : parts[1] === 'instructions' ? viewInstructions() : viewSettings();
      break;
    case 'device': html = viewDevice(); tab = 'settings'; break;
    case 'help': html = viewHelp(); tab = 'settings'; break;
    default: html = viewHome(); tab = 'home';
  }
  $view.innerHTML = html;
  $view.dataset.route = parts[0] || 'home';
  renderRecbar(parts[0] || 'home');
  for (const b of $tabs.querySelectorAll('[data-tab]')) b.classList.toggle('active', b.dataset.tab === tab);

  if (parts[0] === 'c' && parts[2] !== 'chat') attachPlayer(parts[1]);
  if (parts[0] === 'live' || (parts[0] === 'chat') || (parts[0] === 'c' && parts[2] === 'chat')) {
    if (!sameRoute || isNearBottom()) requestAnimationFrame(() => { $view.scrollTop = $view.scrollHeight; });
    else $view.scrollTop = scroll;
  } else {
    $view.scrollTop = scroll;
  }
  if (focusId) {
    const el = document.getElementById(focusId);
    if (el) { el.focus({ preventScroll: true }); if (sel && el.setSelectionRange) try { el.setSelectionRange(sel[0], sel[1]); } catch {} }
  }
  lastRouteKey = key;
}
let wasNearBottom = true;
const isNearBottom = () => wasNearBottom;
$view.addEventListener('scroll', () => { wasNearBottom = $view.scrollHeight - $view.scrollTop - $view.clientHeight < 120; });

// ---------------------------------------------------------------- shared bits

const header = (title, { back, right = '' } = {}) => `
  <header class="bar">
    <div class="bar-side">${back !== undefined ? `<button class="icon-btn" data-action="back" data-to="${esc(back)}" aria-label="Назад">‹</button>` : ''}</div>
    <h1>${esc(title)}</h1>
    <div class="bar-side right">${right}</div>
  </header>`;

const empty = (icon, title, text = '') => `<div class="empty"><div class="empty-icon">${icon}</div><b>${esc(title)}</b>${text ? `<p>${esc(text)}</p>` : ''}</div>`;

function statusBadge(c) {
  if (c.status === 'done') return '';
  if (c.status === 'failed') return '<span class="badge warn">⚠︎ Ошибка</span>';
  if (c.status === 'recording') return '<span class="badge rec">● Запись</span>';
  return `<span class="badge"><span class="spinner sm"></span>${esc(STATUS_LABEL[c.status])}</span>`;
}

const settingSelect = (key, options, value = settings.values[key], type = 'string') => `
  <select data-setting="${key}" data-type="${type}">
    ${options.map(([v, t]) => `<option value="${esc(v)}" ${String(v) === String(value) ? 'selected' : ''}>${esc(t)}</option>`).join('')}
  </select>`;

const toggle = (key, label, hint = '') => `
  <label class="row toggle-row">
    <span>${esc(label)}${hint ? `<small>${esc(hint)}</small>` : ''}</span>
    <input type="checkbox" class="switch" data-setting="${key}" data-type="bool" ${settings.values[key] ? 'checked' : ''}>
  </label>`;

// ---------------------------------------------------------------- record bar

function renderRecbar(r) {
  if (r !== 'home') {
    $recbar.innerHTML = recorder.isRecording
      ? `<button class="rec-pill" data-action="nav" data-to="live"><span class="dot"></span> Запись · <span class="rec-time">${fmt.clock(recorder.elapsed)}</span></button>`
      : '';
    $recbar.className = recorder.isRecording ? 'recbar mini' : 'recbar hidden';
    return;
  }
  $recbar.className = 'recbar';
  if (recorder.isRecording) {
    $recbar.innerHTML = `
      <div class="rec-controls">
        <button class="side-btn" data-action="split" ${recorder.conversationId ? '' : 'disabled'}><span>✂︎</span>Разделить</button>
        <button class="big-btn stop" data-action="stop" aria-label="Остановить"><span class="square"></span></button>
        <button class="side-btn" data-action="nav" data-to="live"><span>💬</span>Текст</button>
      </div>`;
  } else {
    const src = settings.values.preferredSource;
    $recbar.innerHTML = `
      <div class="seg small">
        <button class="${src === 'phone' ? 'on' : ''}" data-action="source" data-v="phone">📱 Микрофон</button>
        <button class="${src === 'omi' ? 'on' : ''}" data-action="source" data-v="omi">⭕️ Omi</button>
      </div>
      <button class="big-btn" data-action="record" aria-label="Начать запись">${src === 'omi' ? '📡' : '🎙️'}</button>`;
  }
}

// ---------------------------------------------------------------- home

function filteredConversations() {
  let list = store.conversations.filter(c => c.id !== recorder.conversationId);
  if (ui.starredOnly) list = list.filter(c => c.starred);
  if (ui.category) list = list.filter(c => c.category === ui.category);
  const q = ui.search.trim().toLowerCase();
  if (q) {
    list = list.filter(c => conv.displayTitle(c).toLowerCase().includes(q) || (c.overview || '').toLowerCase().includes(q)
      || (c.keyPoints || []).some(p => p.toLowerCase().includes(q)) || conv.plain(c).toLowerCase().includes(q));
  }
  return list;
}

function recordingCard() {
  const tail = recorder.segments.slice(-2);
  const color = { live: 'ok', connecting: 'mid', reconnecting: 'mid', failed: 'bad', off: '' }[recorder.liveStatus] || '';
  return `
    <a class="card rec-card" href="#/live">
      <div class="row between">
        <b><span class="dot ${recorder.interrupted ? 'dim' : ''}"></span>
          ${recorder.waitingForDevice ? 'Ожидание Omi…' : recorder.interrupted ? 'Пауза (прервано)' : 'Идёт запись'}</b>
        <span class="rec-time big">${fmt.clock(recorder.elapsed)}</span>
      </div>
      <div class="muted small">${SOURCE[recorder.source][0]} ${recorder.source === 'omi' ? esc(omi.name) : 'Микрофон'} ·
        <span class="status-dot ${color}"></span> ${esc(recorder.liveLabel)}</div>
      <div class="meter" id="rec-meter">${'<i></i>'.repeat(28)}</div>
      <div id="live-tail" class="live-tail">${liveTailHTML(tail)}</div>
      ${recorder.sessionCount > 1 ? `<div class="muted small">Разговоров за сеанс: ${recorder.sessionCount}</div>` : ''}
    </a>`;
}

function liveTailHTML(tail = recorder.segments.slice(-2)) {
  return tail.map(s => `<p>${esc(s.text)}</p>`).join('') + (recorder.interim ? `<p class="interim">${esc(recorder.interim)}</p>` : '');
}

function viewHome() {
  const cats = [...new Set(store.conversations.map(c => c.category).filter(Boolean))].sort();
  const list = filteredConversations();
  const groups = new Map();
  for (const c of list) {
    const d = new Date(c.startedAt); d.setHours(0, 0, 0, 0);
    const k = d.getTime();
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(c);
  }
  const deviceBtn = `<button class="chip-btn" data-action="nav" data-to="device">⭕️${omi.ready ? ` <span class="status-dot ok"></span>${omi.battery != null ? ` ${omi.battery}%` : ''}` : ''}</button>`;
  const importBtn = `<label class="icon-btn" title="Импорт аудио">⤓<input type="file" accept="audio/*,video/*" multiple hidden data-action-change="import-audio"></label>`;
  let html = header('Vox', { right: importBtn }).replace('<div class="bar-side"></div>', `<div class="bar-side">${deviceBtn}</div>`);
  html += '<div class="content">';
  if (isIOS() && !isStandalone() && !ui.hideInstall) {
    html += `<div class="card info">
      <b>Установите как приложение</b>
      <p>Нажмите <b>Поделиться</b> <span class="kbd">⎋</span> внизу Safari → <b>На экран «Домой»</b>. Так Vox откроется на весь экран, а данные не будут удаляться iOS.</p>
      <button class="link" data-action="hide-install">Скрыть</button></div>`;
  }
  if (recorder.isRecording) html += recordingCard();
  if (recorder.lastError) {
    html += `<div class="card warn row"><span>⚠︎ ${esc(recorder.lastError)}</span><button class="icon-btn" data-action="dismiss-error">✕</button></div>`;
  }
  html += `<input id="search" class="search" type="search" placeholder="Поиск по записям" value="${esc(ui.search)}" data-live="search">`;
  if (cats.length || store.conversations.some(c => c.starred)) {
    html += `<div class="chips">
      <button class="chip ${ui.starredOnly ? 'on' : ''}" data-action="toggle-starred">★ Избранное</button>
      ${cats.map(c => `<button class="chip ${ui.category === c ? 'on' : ''}" data-action="category" data-v="${esc(c)}">${esc(c)}</button>`).join('')}
    </div>`;
  }
  if (!store.loaded) html += `<div class="center"><span class="spinner"></span></div>`;
  else if (!list.length && !recorder.isRecording) {
    html += (ui.search || ui.starredOnly || ui.category)
      ? empty('🔍', 'Ничего не найдено', 'Попробуйте другой запрос или сбросьте фильтр.')
      : empty('🎙️', 'Пока нет записей', 'Нажмите на красную кнопку внизу, чтобы начать запись, или импортируйте аудиофайл (⤓ вверху).');
    if (!settings.hasKey('deepgram')) {
      html += `<div class="card info"><b>Первый шаг — ключи</b><p>Добавьте ключ Deepgram (расшифровка) и ключ ИИ (сводки, чат).</p>
        <button class="btn" data-action="nav" data-to="settings">Открыть настройки</button></div>`;
    }
  }
  for (const [day, items] of groups) {
    html += `<h2 class="section">${esc(fmt.dayTitle(day))}</h2><div class="list">`;
    for (const c of items) {
      const preview = c.overview ? c.overview.replace(/[#*_`]/g, '') : conv.plain(c);
      html += `
        <a class="item" href="#/c/${c.id}">
          <div class="avatar">${esc(c.emoji)}</div>
          <div class="item-body">
            <div class="item-title">${esc(conv.displayTitle(c))}${c.starred ? ' <span class="star">★</span>' : ''}</div>
            <div class="item-meta">${fmt.time(c.startedAt)} · ${fmt.duration(c.duration)} · ${SOURCE[c.source]?.[0] || ''}
              ${c.category ? `<span class="tag">${esc(c.category)}</span>` : ''}</div>
            ${preview ? `<div class="item-preview">${esc(preview.slice(0, 220))}</div>` : ''}
            ${statusBadge(c)}
          </div>
        </a>`;
    }
    html += '</div>';
  }
  html += '<div class="spacer"></div></div>';
  return html;
}

// ---------------------------------------------------------------- live transcript

function viewLive() {
  let body;
  if (!recorder.isRecording) {
    body = empty('⏹', 'Запись не идёт', 'Начните запись на главном экране.');
  } else if (!recorder.segments.length && !recorder.interim) {
    body = recorder.liveStatus === 'off'
      ? empty('🕐', 'Расшифровка после записи', 'Выбран режим «После записи» — текст появится, когда запись закончится.')
      : empty('👂', 'Слушаю…', 'Текст появится, как только кто-нибудь заговорит.');
  } else {
    body = `<div class="transcript" id="live-full">${liveFullHTML()}</div>`;
  }
  return header(fmt.clock(recorder.elapsed), {
    back: '',
    right: recorder.isRecording ? `<button class="icon-btn" data-action="split">✂︎</button><button class="icon-btn danger" data-action="stop">⏹</button>` : '',
  }).replace('<h1>', '<h1 class="rec-time">') + `<div class="content">${body}<div class="spacer"></div></div>`;
}

function liveFullHTML() {
  return recorder.segments.map(s => `
    <div class="seg-line" style="--sp:${spColor(s.speaker)}">
      <div class="seg-head"><b>Спикер ${s.speaker + 1}</b> <span class="muted">${fmt.clock(s.start)}</span></div>
      <div>${esc(s.text)}</div>
    </div>`).join('') + (recorder.interim ? `<p class="interim">${esc(recorder.interim)}</p>` : '');
}

// ---------------------------------------------------------------- detail

function viewDetail(id) {
  const c = store.conversation(id);
  if (!c) return header('Запись', { back: '' }) + `<div class="content">${empty('🗑', 'Запись удалена')}</div>`;
  const right = `
    <button class="icon-btn" data-action="nav" data-to="c/${c.id}/chat" ${settings.llmConfigured && c.segments.length ? '' : 'disabled'} title="Вопросы к записи">💬</button>
    <button class="icon-btn" data-action="menu" data-id="${c.id}" title="Действия">⋯</button>`;
  let html = header('', { back: '', right });
  html += '<div class="content">';
  html += `
    <div class="detail-head">
      <div class="emoji-big">${esc(c.emoji)}</div>
      <div class="grow">
        <h2 class="title" data-action="rename" data-id="${c.id}">${esc(conv.displayTitle(c))}</h2>
        <div class="muted small">${fmt.long(c.startedAt)} · ${fmt.duration(c.duration)}</div>
        <div class="muted small">${SOURCE[c.source]?.join(' ') || ''}${c.category ? ` · ${esc(c.category)}` : ''} · ${conv.wordCount(c)} слов</div>
      </div>
      <button class="icon-btn star-btn ${c.starred ? 'on' : ''}" data-action="star" data-id="${c.id}">${c.starred ? '★' : '☆'}</button>
    </div>`;
  if (conv.isProcessing(c) || processing.activeID === c.id) {
    html += `<div class="card row"><span class="spinner"></span> ${c.status === 'summarizing' ? 'ИИ анализирует запись…' : 'Идёт расшифровка…'}</div>`;
  } else if (c.status === 'failed') {
    html += `<div class="card warn"><b>⚠︎ Не удалось обработать</b>${c.errorMessage ? `<p class="small">${esc(c.errorMessage)}</p>` : ''}
      <button class="btn" data-action="retry" data-id="${c.id}">Повторить</button></div>`;
  } else if (c.needsSummary && conv.hasSpeech(c) && c.status === 'done') {
    html += settings.llmConfigured
      ? `<div class="card row between"><span class="small">Сводка ещё не создана</span><button class="btn small" data-action="resummarize" data-id="${c.id}" data-tpl="${esc(c.templateID)}">Создать</button></div>`
      : `<div class="card row between"><span class="small">Добавьте ключ ИИ, чтобы получить сводку и задачи</span><button class="btn small" data-action="nav" data-to="settings">Ключи</button></div>`;
  }
  html += `<div id="player-slot" class="player-slot hidden"></div>`;
  const t = ui.detailTab;
  html += `<div class="seg">
    <button class="${t === 'summary' ? 'on' : ''}" data-action="detail-tab" data-v="summary">Сводка</button>
    <button class="${t === 'transcript' ? 'on' : ''}" data-action="detail-tab" data-v="transcript">Транскрипт</button>
    <button class="${t === 'tasks' ? 'on' : ''}" data-action="detail-tab" data-v="tasks">Задачи</button>
  </div>`;
  if (t === 'summary') html += detailSummary(c);
  else if (t === 'transcript') html += detailTranscript(c);
  else html += detailTasks(c);
  html += '<div class="spacer"></div></div>';
  return html;
}

function detailSummary(c) {
  let h = '';
  if (!c.overview && !(c.keyPoints || []).length) h += `<p class="muted">${c.segments.length ? 'Сводки пока нет.' : 'Пока нет текста.'}</p>`;
  if (c.overview) h += md(c.overview);
  if ((c.keyPoints || []).length) {
    h += `<h3>Ключевые моменты</h3><ul class="points">${c.keyPoints.map(p => `<li>${md(p).replace(/^<div class="md"><p>|<\/p><\/div>$/g, '')}</li>`).join('')}</ul>`;
  }
  const open = store.tasks(c.id).filter(t => !t.done);
  if (open.length) h += `<h3>Задачи</h3><div class="list">${open.map(t => taskRow(t, false)).join('')}</div>`;
  if (settings.llmConfigured && c.segments.length) {
    h += `<button class="btn ghost" data-action="pick-template" data-id="${c.id}" ${conv.isProcessing(c) ? 'disabled' : ''}>✨ Пересоздать сводку · ${esc(template(c.templateID).title)}</button>`;
  }
  return h;
}

function detailTranscript(c) {
  if (!c.segments.length) return `<p class="muted">${conv.isProcessing(c) ? 'Расшифровка в процессе…' : 'Текста нет.'}</p>`;
  let h = `<div class="row gap">
    <button class="btn small ghost" data-action="speakers" data-id="${c.id}">👥 Спикеры</button>
    <button class="btn small ghost" data-action="copy-transcript" data-id="${c.id}">⧉ Копировать</button></div>`;
  h += '<div class="transcript">';
  for (const s of c.segments) {
    h += `<div class="seg-line" style="--sp:${spColor(s.speaker)}">
      <div class="seg-head"><b data-action="speakers" data-id="${c.id}">${esc(conv.speakerName(c, s.speaker))}</b>
        <button class="ts" data-action="seek" data-t="${s.start}">${fmt.clock(s.start)}</button></div>
      <div class="selectable">${esc(s.text)}</div></div>`;
  }
  return h + '</div>';
}

function detailTasks(c) {
  const items = store.tasks(c.id);
  return `${items.length ? `<div class="list">${items.map(t => taskRow(t, false)).join('')}</div>` : '<p class="muted">Задач из этой записи нет.</p>'}
    <div class="row gap add-row">
      <input id="new-task-${c.id}" type="text" placeholder="Новая задача" data-draft="task-${c.id}" value="${esc(ui.drafts['task-' + c.id] || '')}" data-enter="add-task" data-id="${c.id}">
      <button class="btn small" data-action="add-task" data-id="${c.id}">Добавить</button>
    </div>`;
}

function taskRow(t, showSource) {
  const c = showSource && t.conversationID ? store.conversation(t.conversationID) : null;
  const overdue = t.dueDate && !t.done && new Date(t.dueDate) < new Date(new Date().toDateString());
  return `<div class="item task ${t.done ? 'done' : ''}">
    <button class="check" data-action="toggle-task" data-id="${t.id}" aria-label="Готово">${t.done ? '✓' : ''}</button>
    <div class="item-body">
      <div class="task-text" data-action="edit-task" data-id="${t.id}">${esc(t.text)}</div>
      <div class="item-meta">
        ${t.dueDate ? `<span class="${overdue ? 'overdue' : ''}">📅 ${esc(fmt.dayTitle(t.dueDate))}</span>` : ''}
        ${c ? `<a href="#/c/${c.id}">${esc(c.emoji)} ${esc(conv.displayTitle(c))}</a>` : ''}
      </div>
    </div>
    <button class="icon-btn subtle" data-action="delete-task" data-id="${t.id}" aria-label="Удалить">✕</button>
  </div>`;
}

// ---------------------------------------------------------------- tasks / memory

function viewTasks() {
  const done = ui.taskFilter === 'done';
  let items = store.actionItems.filter(t => t.done === done);
  items = done
    ? items.sort((a, b) => new Date(b.completedAt || b.createdAt) - new Date(a.completedAt || a.createdAt))
    : items.sort((a, b) => (a.dueDate && b.dueDate) ? a.dueDate.localeCompare(b.dueDate) : a.dueDate ? -1 : b.dueDate ? 1 : new Date(b.createdAt) - new Date(a.createdAt));
  return header('Задачи') + `<div class="content">
    <div class="seg">
      <button class="${!done ? 'on' : ''}" data-action="task-filter" data-v="open">Открытые</button>
      <button class="${done ? 'on' : ''}" data-action="task-filter" data-v="done">Готово</button>
    </div>
    <div class="row gap add-row">
      <input id="new-task" type="text" placeholder="Новая задача" data-draft="task" value="${esc(ui.drafts.task || '')}" data-enter="add-task">
      <button class="btn small" data-action="add-task">＋</button>
    </div>
    ${items.length ? `<div class="list">${items.map(t => taskRow(t, true)).join('')}</div>`
      : empty(done ? '✅' : '📋', done ? 'Выполненных пока нет' : 'Задач нет', done ? '' : 'ИИ добавляет сюда задачи и договорённости из ваших записей.')}
    <div class="spacer"></div></div>`;
}

function viewMemory() {
  const q = ui.memSearch.trim().toLowerCase();
  const items = q ? store.memories.filter(m => m.text.toLowerCase().includes(q)) : store.memories;
  return header('Память') + `<div class="content">
    <p class="muted small">ИИ запоминает устойчивые факты о вас из записей и использует их в чате.</p>
    <div class="row gap add-row">
      <input id="new-mem" type="text" placeholder="Добавить факт о себе" data-draft="mem" value="${esc(ui.drafts.mem || '')}" data-enter="add-memory">
      <button class="btn small" data-action="add-memory">＋</button>
    </div>
    ${store.memories.length > 8 ? `<input id="mem-search" class="search" type="search" placeholder="Поиск" value="${esc(ui.memSearch)}" data-live="memSearch">` : ''}
    ${items.length ? `<div class="list">${items.map(m => {
      const c = m.conversationID ? store.conversation(m.conversationID) : null;
      return `<div class="item">
        <div class="item-body">
          <div data-action="edit-memory" data-id="${m.id}">${esc(m.text)}</div>
          <div class="item-meta">${fmt.short(m.createdAt)}${c ? ` · <a href="#/c/${c.id}">${esc(conv.displayTitle(c))}</a>` : ''}</div>
        </div>
        <button class="icon-btn subtle" data-action="delete-memory" data-id="${m.id}">✕</button></div>`;
    }).join('')}</div>` : empty('🧠', 'Память пуста', 'Факты появятся после анализа ваших записей.')}
    <div class="spacer"></div></div>`;
}

// ---------------------------------------------------------------- chat

function viewChat(scopeId) {
  const c = scopeId ? store.conversation(scopeId) : null;
  const msgs = chat.messages(scopeId);
  const suggestions = scopeId
    ? ['О чём была эта запись?', 'Какие решения приняли?', 'Что я пообещал сделать?', 'Составь письмо по итогам']
    : ['Что я делал сегодня?', 'Какие у меня открытые задачи?', 'О чём мы договорились на этой неделе?', 'Что ты обо мне знаешь?'];
  const right = `<button class="icon-btn" data-action="clear-chat" data-scope="${scopeId || ''}" ${msgs.length ? '' : 'disabled'}>🗑</button>`;
  let h = header(scopeId ? (c ? conv.displayTitle(c) : 'Вопросы') : 'Чат с записями', { back: scopeId ? '' : undefined, right });
  h += '<div class="content chat">';
  if (!settings.llmConfigured) {
    h += empty('🔑', 'Нужен ключ ИИ', 'Добавьте ключ в Настройки → Ключи API (например, бесплатный Gemini).');
  } else if (!msgs.length) {
    h += `<div class="suggest"><b>${scopeId ? 'Спросите об этой записи' : 'Спросите что угодно о своих записях'}</b>
      ${suggestions.map(s => `<button class="chip" data-action="chat-suggest" data-text="${esc(s)}" data-scope="${scopeId || ''}">${esc(s)}</button>`).join('')}</div>`;
  }
  const lastId = msgs.at(-1)?.id;
  for (const m of msgs) {
    const streaming = chat.responding && m.id === lastId && m.role === 'assistant';
    h += `<div class="bubble ${m.role === 'user' ? 'user' : 'bot'} ${m.isError ? 'error' : ''}">
      ${!m.text && streaming ? '<span class="typing"><i></i><i></i><i></i></span>' : m.role === 'user' ? esc(m.text).replace(/\n/g, '<br>') : md(m.text)}
    </div>`;
  }
  h += '<div class="spacer small"></div></div>';
  const key = `chat-${scopeId || 'all'}`;
  h += `<div class="composer">
    <textarea id="composer-${scopeId || 'all'}" rows="1" placeholder="Сообщение" data-draft="${key}" data-enter="chat-send" data-scope="${scopeId || ''}">${esc(ui.drafts[key] || '')}</textarea>
    ${chat.responding
      ? '<button class="send stop" data-action="chat-stop">■</button>'
      : `<button class="send" data-action="chat-send" data-scope="${scopeId || ''}" ${settings.llmConfigured ? '' : 'disabled'}>↑</button>`}
  </div>`;
  return h;
}

// ---------------------------------------------------------------- settings

function viewSettings() {
  const v = settings.values;
  const keysCount = Object.keys(PROVIDERS).filter(p => p !== 'custom' && settings.hasKey(p)).length;
  const p = v.llmProvider;
  return header('Настройки') + `<div class="content settings">
    <section class="group">
      <h3>Профиль</h3>
      <label class="row field"><span>Имя</span><input id="set-name" type="text" placeholder="Как вас зовут" value="${esc(v.userName)}" data-setting="userName"></label>
    </section>

    <section class="group">
      <a class="row nav-row" href="#/settings/key/deepgram"><span>🔑 Ключи API</span><span class="muted">${keysCount ? `задано: ${keysCount}` : 'не заданы'} ›</span></a>
      <div class="list inset">
        ${Object.keys(PROVIDERS).map(k => `<a class="row nav-row sub" href="#/settings/key/${k}"><span>${esc(PROVIDERS[k].title)}</span><span>${settings.hasKey(k) ? '<span class="ok">✓</span>' : '<span class="muted">нет</span>'} ›</span></a>`).join('')}
      </div>
      <p class="hint">Ключи хранятся только в этом браузере на вашем телефоне и отправляются напрямую провайдерам.</p>
    </section>

    <section class="group">
      <h3>Распознавание речи</h3>
      <label class="row field"><span>Расшифровка</span>${settingSelect('transcriptionMode', [['live', 'В реальном времени'], ['afterRecording', 'После записи (дешевле)']])}</label>
      <label class="row field"><span>Язык</span>${settingSelect('language', LANGUAGES)}</label>
      <label class="row field"><span>Модель Deepgram</span>${settingSelect('deepgramModel', [['nova-3', 'Nova-3 (лучшая)'], ['nova-2', 'Nova-2']])}</label>
      ${toggle('diarize', 'Разделять по спикерам')}
      <label class="field col"><span>Ключевые слова</span>
        <textarea id="set-keyterms" rows="2" placeholder="Имена, термины, названия — через запятую" data-setting="keyterms">${esc(v.keyterms)}</textarea></label>
      <p class="hint">Live — текст появляется во время записи (≈ $0.46/час). «После записи» — дешевле (≈ $0.26/час) и точнее со спикерами. $200 бесплатного кредита Deepgram — это сотни часов.</p>
    </section>

    <section class="group">
      <h3>Расшифровка файла</h3>
      <label class="row field"><span>Сервис</span>${settingSelect('batchProvider', Object.entries(BATCH_PROVIDERS).map(([k, b]) => [k, b.title]))}</label>
      ${v.batchProvider !== 'deepgram' ? `<label class="row field"><span>Модель</span><input id="set-batchmodel" type="text" placeholder="${esc(BATCH_PROVIDERS[v.batchProvider].model)}" value="${esc(v.batchModel)}" data-setting="batchModel" autocapitalize="off" autocorrect="off"></label>` : ''}
      ${toggle('alwaysRetranscribe', 'Всегда перерасшифровывать после записи')}
      <p class="hint">Для режима «После записи», импорта, кнопки «Расшифровать заново» и автоматически — если во время live-записи пропадала связь. Groq Whisper бесплатен, но не различает спикеров.</p>
    </section>

    <section class="group">
      <h3>ИИ-анализ и чат</h3>
      <label class="row field"><span>Провайдер</span>${settingSelect('llmProvider', LLM_PROVIDERS.map(k => [k, PROVIDERS[k].title + (settings.hasKey(k) ? '' : ' — нет ключа')]))}</label>
      ${modelField(p)}
      ${toggle('autoSummarize', 'Автоматическая сводка')}
      <label class="row field"><span>Язык сводки</span>${settingSelect('summaryLanguage', Object.entries(SUMMARY_LANGUAGES).map(([k, x]) => [k, x.title]))}</label>
      <label class="row field"><span>Шаблон</span>${settingSelect('defaultTemplate', TEMPLATES.map(t => [t.id, t.title]))}</label>
      ${toggle('extractTasks', 'Извлекать задачи')}
      ${toggle('extractMemories', 'Запоминать факты обо мне')}
      <label class="row field"><span>Объём контекста</span>${settingSelect('maxContextChars', [[100000, 'Малый (~100 тыс. симв.)'], [300000, 'Средний (~300 тыс.)'], [800000, 'Большой (~800 тыс.)'], [2000000, 'Огромный (~2 млн, Gemini)']], v.maxContextChars, 'number')}</label>
      <a class="row nav-row" href="#/settings/instructions"><span>Свои инструкции для ИИ</span><span class="muted">${v.customInstructions ? 'заданы' : ''} ›</span></a>
      <p class="hint">Бесплатно: Google Gemini (ключ в AI Studio) или Groq. Длинные записи обрабатываются по частям.</p>
    </section>

    <section class="group">
      <h3>Запись</h3>
      <label class="row field"><span>Делить на разговоры</span>${settingSelect('autoSplitMinutes', [[0, 'Нет'], [1, 'После 1 мин тишины'], [2, 'После 2 мин'], [5, 'После 5 мин'], [10, 'После 10 мин'], [15, 'После 15 мин'], [30, 'После 30 мин'], [60, 'После 60 мин']], v.autoSplitMinutes, 'number')}</label>
      ${toggle('keepScreenOn', 'Не гасить экран во время записи', 'iOS останавливает микрофон, если свернуть веб-приложение')}
      ${toggle('deleteEmpty', 'Удалять записи без речи')}
      <label class="row field"><span>Качество аудио</span>${settingSelect('audioBitrate', [[24000, 'Экономное (24 кбит/с)'], [32000, 'Обычное (32 кбит/с)'], [64000, 'Высокое (64 кбит/с)']], v.audioBitrate, 'number')}</label>
      <a class="row nav-row" href="#/device"><span>⭕️ Устройство Omi</span><span class="muted">${omi.ready ? 'подключено' : omi.supported ? 'не подключено' : 'нужен Bluefy/Chrome'} ›</span></a>
    </section>

    <section class="group">
      <h3>Данные</h3>
      <div class="row between"><span>Записей</span><span class="muted">${store.conversations.length}</span></div>
      <div class="row between"><span>Занято</span><span class="muted" id="storage-text">${esc(ui.storage || '…')}</span></div>
      <button class="row nav-row btn-row" data-action="export-json">⤒ Экспорт всех записей (JSON)</button>
      <label class="row nav-row btn-row">⤓ Импорт резервной копии<input type="file" accept="application/json,.json" hidden data-action-change="import-json"></label>
      <button class="row nav-row btn-row danger" data-action="delete-all">🗑 Удалить все данные</button>
      <p class="hint">Аудио каждой записи можно сохранить из её меню (⋯). Резервная копия JSON содержит тексты, сводки, задачи и память.</p>
    </section>

    <section class="group">
      <a class="row nav-row" href="#/help"><span>❔ Справка и установка</span><span>›</span></a>
      <div class="row between"><span>Версия</span><span class="muted">веб 1.0</span></div>
    </section>
    <div class="spacer"></div>
  </div>`;
}

function modelField(p) {
  const loaded = ui.models[p] || [];
  const all = [...new Set([...PROVIDERS[p].models, ...loaded])];
  return `<label class="field col"><span>Модель</span>
    <div class="row gap">
      <input id="model-${p}" type="text" list="models-${p}" placeholder="${esc(PROVIDERS[p].model)}" value="${esc(settings.model(p))}"
        data-model="${p}" autocapitalize="off" autocorrect="off" spellcheck="false">
      <datalist id="models-${p}">${all.map(m => `<option value="${esc(m)}"></option>`).join('')}</datalist>
      <button class="btn small ghost" data-action="load-models" data-p="${p}">${ui.modelsLoading === p ? '<span class="spinner sm"></span>' : '⟳'}</button>
    </div>
    ${loaded.length ? `<small class="muted">Загружено моделей: ${loaded.length} — выберите из подсказок</small>` : '<small class="muted">⟳ — загрузить список доступных моделей</small>'}
  </label>`;
}

function viewInstructions() {
  return header('Инструкции для ИИ', { back: 'settings' }) + `<div class="content">
    <textarea id="set-instr" class="big-text" rows="10" placeholder="Например: пиши кратко, выделяй сроки и суммы; меня интересуют решения по проекту X…" data-setting="customInstructions">${esc(settings.values.customInstructions)}</textarea>
    <p class="hint">Добавляется к каждому запросу на сводку.</p></div>`;
}

function viewKey(p) {
  if (!PROVIDERS[p]) return viewSettings();
  const info = PROVIDERS[p];
  const k = `key:${p}`;
  const val = ui.drafts[k] ?? settings.apiKey(p);
  const test = ui.keyTest[p];
  let h = header(info.title, { back: 'settings' }) + `<div class="content settings">
    <section class="group">
      <label class="field col"><span>API-ключ</span>
        <input id="key-${p}" type="password" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="Вставьте ключ" value="${esc(val)}" data-draft="${k}">
      </label>
      <div class="row gap">
        <button class="btn small ghost" data-action="paste-key" data-p="${p}">📋 Вставить</button>
        <button class="btn small ghost" data-action="reveal-key" data-p="${p}">👁 Показать</button>
        ${info.url ? `<a class="btn small ghost" href="${info.url}" target="_blank" rel="noopener">Получить ключ ↗</a>` : ''}
      </div>
      <p class="hint">${esc(info.hint)}</p>
    </section>`;
  if (p !== 'deepgram') {
    h += `<section class="group">
      <label class="field col"><span>Адрес API</span>
        <input id="base-${p}" type="url" autocapitalize="off" placeholder="${esc(info.base || 'https://…/v1')}" value="${esc(settings.values.baseURLs?.[p] || '')}" data-draft="base:${p}"></label>
      <p class="hint">${p === 'custom' ? 'OpenAI-совместимый сервер. Нужны HTTPS и разрешённый CORS.' : 'Оставьте пустым для адреса по умолчанию.'}</p>
      ${modelField(p)}
    </section>`;
  }
  h += `<section class="group">
      <button class="btn wide" data-action="save-key" data-p="${p}">${test?.busy ? '<span class="spinner sm"></span> Проверяю…' : 'Сохранить и проверить'}</button>
      ${test && !test.busy ? `<p class="${test.ok ? 'ok' : 'bad'}">${test.ok ? '✓' : '✕'} ${esc(test.text)}</p>` : ''}
      ${settings.hasKey(p) && p !== 'custom' ? `<button class="btn wide ghost danger" data-action="delete-key" data-p="${p}">Удалить ключ</button>` : ''}
    </section></div>`;
  return h;
}

function viewDevice() {
  let body;
  if (!omi.supported) {
    body = `<div class="card info"><b>Bluetooth в этом браузере недоступен</b>
      <p>Safari и все браузеры на iPhone не поддерживают Web Bluetooth. Чтобы подключить кулон Omi:</p>
      <ul><li>на iPhone — откройте этот сайт в бесплатном браузере <b>Bluefy</b> (App Store);</li>
      <li>на Android или компьютере — в <b>Chrome</b> или <b>Edge</b>.</li></ul>
      <p>Данные Vox у каждого браузера свои: записи из Safari не видны в Bluefy (перенесите резервной копией).</p></div>`;
  } else {
    const st = { idle: 'Не подключено', connecting: 'Подключение…', connected: 'Подключено · звук идёт', reconnecting: 'Ожидание устройства…' }[omi.state];
    body = `<section class="group">
      ${omi.hasSaved ? `<div class="row between"><b>⭕️ ${esc(omi.name)}</b><span class="muted">${esc(st)}</span></div>` : ''}
      ${omi.ready ? `
        <div class="row between"><span>Батарея</span><span class="muted">${omi.battery != null ? omi.battery + '%' : '—'}</span></div>
        <div class="row between"><span>Кодек</span><span class="muted">${esc(omi.codecName)}</span></div>
        ${omi.firmware ? `<div class="row between"><span>Прошивка</span><span class="muted">${esc(omi.firmware)}</span></div>` : ''}
        ${omi.lostFrames ? `<div class="row between"><span>Потеряно кадров</span><span class="muted">${omi.lostFrames}</span></div>` : ''}
        ${!recorder.isRecording ? '<button class="btn wide" data-action="record-omi">● Начать запись с Omi</button>' : ''}
        <button class="btn wide ghost danger" data-action="omi-forget">Отключить</button>`
      : `<button class="btn wide" data-action="omi-pair">${omi.hasSaved ? 'Подключить снова' : 'Найти устройство'}</button>`}
      <p class="hint">Включите Omi и держите рядом. Если кулон подключён к официальному приложению Omi — сначала отключите его там. Веб-версия работает, пока страница открыта.</p>
    </section>`;
  }
  return header('Omi', { back: 'settings' }) + `<div class="content settings">${body}</div>`;
}

function viewHelp() {
  return header('Справка', { back: 'settings' }) + `<div class="content">${md(`
## Установка на iPhone
- Откройте этот сайт в **Safari** → кнопка **Поделиться** → **На экран «Домой»**.
- Запускайте Vox с иконки: так он работает на весь экран, а записи не удаляются автоматически.

## Как записывать долго
- Веб-приложение пишет звук, **пока оно открыто на экране**. Vox не даёт экрану погаснуть во время записи.
- Не сворачивайте приложение и не блокируйте телефон: iOS остановит микрофон. Если это случилось, Vox продолжит запись новым разговором, когда вы вернётесь.
- Положите телефон экраном вниз, чтобы не мешала подсветка, или уменьшите яркость.
- Для фоновой записи с выключенным экраном нужна iOS-версия Vox (сборка в GitHub → Releases).

## Ключи
- **Deepgram**: console.deepgram.com — при регистрации дают $200 (сотни часов).
- **Gemini**: aistudio.google.com — бесплатный лимит.
- **Groq**: console.groq.com — бесплатно, есть Whisper.

## Где хранятся данные
Только в этом браузере на телефоне (IndexedDB). Делайте резервную копию в Настройки → Данные → Экспорт.

## Omi
Safari не поддерживает Bluetooth для сайтов. Используйте браузер **Bluefy** на iPhone или Chrome на Android.
`)}</div>`;
}

// ---------------------------------------------------------------- modals

function openModal(html) {
  $modal.innerHTML = `<div class="modal-backdrop" data-action="close-modal"></div><div class="modal">${html}</div>`;
  $modal.classList.add('open');
  const first = $modal.querySelector('input,textarea');
  if (first) setTimeout(() => first.focus(), 50);
}
function closeModal() { $modal.classList.remove('open'); $modal.innerHTML = ''; }

function menuModal(c) {
  openModal(`<div class="sheet-list">
    <button data-action="rename" data-id="${c.id}">✏️ Переименовать</button>
    <button data-action="speakers" data-id="${c.id}" ${c.segments.length ? '' : 'disabled'}>👥 Имена спикеров</button>
    <button data-action="share-text" data-id="${c.id}">↗ Поделиться текстом</button>
    <button data-action="export-md" data-id="${c.id}">📄 Экспорт Markdown (.md)</button>
    ${c.audioFile ? `<button data-action="share-audio" data-id="${c.id}">🎧 Сохранить аудио</button>` : ''}
    ${c.audioFile ? `<button data-action="retranscribe" data-id="${c.id}" ${conv.isProcessing(c) ? 'disabled' : ''}>⟳ Расшифровать заново</button>` : ''}
    ${settings.llmConfigured && c.segments.length ? `<button data-action="pick-template" data-id="${c.id}">✨ Сводка по шаблону</button>` : ''}
    <button class="danger" data-action="delete-conv" data-id="${c.id}">🗑 Удалить</button>
    <button data-action="close-modal">Отмена</button>
  </div>`);
}

function speakersModal(c) {
  const sps = conv.speakers(c);
  const name = settings.values.userName.trim();
  openModal(`<h3>Спикеры</h3>
    ${sps.map(sp => `<div class="row gap sp-row">
      <span class="sp-dot" style="background:${spColor(sp)}"></span>
      <input type="text" data-speaker="${sp}" placeholder="Спикер ${sp + 1}" value="${esc(c.speakerNames?.[String(sp)] || '')}">
      ${name ? `<button class="btn small ghost" data-action="speaker-me" data-sp="${sp}">Это я</button>` : ''}
    </div>`).join('')}
    ${sps.length > 1 ? `<h4>Объединить спикеров</h4><p class="hint">Если один человек распознан как два — объедините.</p>
      <div class="row gap wrap">${sps.map(a => sps.filter(b => b !== a).map(b =>
        `<button class="chip" data-action="merge-speaker" data-id="${c.id}" data-from="${a}" data-to="${b}">${esc(conv.speakerName(c, a))} → ${esc(conv.speakerName(c, b))}</button>`).join('')).join('')}</div>` : ''}
    <div class="row gap end"><button class="btn ghost" data-action="close-modal">Отмена</button><button class="btn" data-action="save-speakers" data-id="${c.id}">Готово</button></div>`);
}

function templateModal(c) {
  openModal(`<h3>Шаблон сводки</h3><div class="sheet-list">
    ${TEMPLATES.map(t => `<button data-action="resummarize" data-id="${c.id}" data-tpl="${t.id}">${t.icon} ${esc(t.title)}${t.id === c.templateID ? ' ✓' : ''}</button>`).join('')}
    <button data-action="close-modal">Отмена</button></div>`);
}

// ---------------------------------------------------------------- actions

const actions = {
  nav: (el) => go(el.dataset.to),
  back: (el) => { if (el.dataset.to) go(el.dataset.to); else if (history.length > 1) history.back(); else go(''); },
  'close-modal': () => closeModal(),
  'hide-install': () => { ui.hideInstall = true; localStorage.setItem('vox.hideInstall', '1'); render(); },
  'dismiss-error': () => { recorder.lastError = ''; render(); },
  source: (el) => settings.set('preferredSource', el.dataset.v),
  record: async () => {
    const src = settings.values.preferredSource;
    if (src === 'omi' && !omi.ready && !omi.hasSaved) { go('device'); return; }
    await recorder.start(src);
  },
  'record-omi': async () => { settings.set('preferredSource', 'omi'); await recorder.start('omi'); go(''); },
  stop: async () => { await recorder.stop(); if (route()[0] === 'live') go(''); },
  split: () => { recorder.splitNow(); toast('Начат новый разговор'); },
  'toggle-starred': () => { ui.starredOnly = !ui.starredOnly; render(); },
  category: (el) => { ui.category = ui.category === el.dataset.v ? null : el.dataset.v; render(); },
  star: (el) => store.update(el.dataset.id, c => { c.starred = !c.starred; }),
  'detail-tab': (el) => { ui.detailTab = el.dataset.v; render(); },
  menu: (el) => { const c = store.conversation(el.dataset.id); if (c) menuModal(c); },
  rename: (el) => {
    closeModal();
    const c = store.conversation(el.dataset.id);
    if (!c) return;
    const t = prompt('Название записи', c.title);
    if (t === null) return;
    store.update(c.id, x => { x.title = t.trim(); x.userEditedTitle = !!t.trim(); });
  },
  speakers: (el) => { const c = store.conversation(el.dataset.id); if (c) speakersModal(c); },
  'speaker-me': (el) => {
    const inp = $modal.querySelector(`[data-speaker="${el.dataset.sp}"]`);
    if (inp) inp.value = settings.values.userName.trim();
  },
  'save-speakers': (el) => {
    const names = {};
    for (const inp of $modal.querySelectorAll('[data-speaker]')) if (inp.value.trim()) names[inp.dataset.speaker] = inp.value.trim();
    store.update(el.dataset.id, c => { c.speakerNames = names; });
    closeModal();
  },
  'merge-speaker': (el) => {
    const from = Number(el.dataset.from), to = Number(el.dataset.to);
    store.update(el.dataset.id, c => {
      for (const s of c.segments) if (s.speaker === from) s.speaker = to;
      const merged = [];
      for (const s of c.segments) {
        const last = merged.at(-1);
        if (last && last.speaker === s.speaker && s.start - last.end < 30 && last.text.length + s.text.length < 2000) {
          last.text += ' ' + s.text; last.end = Math.max(last.end, s.end);
        } else merged.push(s);
      }
      c.segments = merged;
      delete c.speakerNames?.[String(from)];
    });
    const c = store.conversation(el.dataset.id);
    if (c) speakersModal(c);
  },
  'copy-transcript': async (el) => {
    const c = store.conversation(el.dataset.id);
    try { await navigator.clipboard.writeText(conv.transcript(c, false)); toast('Скопировано'); } catch { toast('Не удалось скопировать', 'error'); }
  },
  seek: (el) => {
    const t = Number(el.dataset.t) || 0;
    try { player.currentTime = t; player.play(); } catch {}
  },
  'share-text': async (el) => {
    closeModal();
    const c = store.conversation(el.dataset.id);
    await shareOrDownload({ title: conv.displayTitle(c), text: conv.markdown(c, store.tasks(c.id)) });
  },
  'export-md': async (el) => {
    closeModal();
    const c = store.conversation(el.dataset.id);
    const name = `${fmt.fileStamp(c.startedAt)} ${conv.displayTitle(c)}`.replace(/[\\/?%*|"<>:]/g, '-').slice(0, 80);
    const file = new File([conv.markdown(c, store.tasks(c.id))], `${name}.md`, { type: 'text/markdown' });
    await shareOrDownload({ title: name, file });
  },
  'share-audio': async (el) => {
    closeModal();
    const c = store.conversation(el.dataset.id);
    const blob = await store.getAudio(c.id);
    if (!blob) { toast('Аудио не найдено', 'error'); return; }
    const name = `${fmt.fileStamp(c.startedAt)} ${conv.displayTitle(c)}`.replace(/[\\/?%*|"<>:]/g, '-').slice(0, 80);
    await shareOrDownload({ title: name, file: new File([blob], `${name}.${extForMime(blob.type)}`, { type: blob.type }) });
  },
  retranscribe: (el) => { closeModal(); processing.retranscribe(el.dataset.id); ui.detailTab = 'transcript'; },
  'pick-template': (el) => { const c = store.conversation(el.dataset.id); if (c) templateModal(c); },
  resummarize: (el) => { closeModal(); processing.resummarize(el.dataset.id, el.dataset.tpl); ui.detailTab = 'summary'; },
  retry: (el) => processing.retry(el.dataset.id),
  'delete-conv': async (el) => {
    closeModal();
    if (!confirm('Удалить запись вместе с аудио?')) return;
    if (playerFor === el.dataset.id) { player.pause(); playerFor = null; }
    await store.delete(el.dataset.id);
    go('');
  },
  'add-task': (el) => {
    const id = el.dataset.id;
    const key = id ? `task-${id}` : 'task';
    const text = trim(ui.drafts[key]);
    if (!text) return;
    store.addTask(text, id || null);
    ui.drafts[key] = '';
    render();
  },
  'toggle-task': (el) => store.toggleTask(el.dataset.id),
  'edit-task': (el) => {
    const t = store.actionItems.find(x => x.id === el.dataset.id);
    if (!t) return;
    const v = prompt('Задача', t.text);
    if (v && v.trim()) store.updateTask(t.id, v.trim());
  },
  'delete-task': (el) => store.deleteTask(el.dataset.id),
  'task-filter': (el) => { ui.taskFilter = el.dataset.v; render(); },
  'add-memory': () => {
    const text = trim(ui.drafts.mem);
    if (!text) return;
    store.addMemories([text]);
    ui.drafts.mem = '';
    render();
  },
  'edit-memory': (el) => {
    const m = store.memories.find(x => x.id === el.dataset.id);
    if (!m) return;
    const v = prompt('Факт', m.text);
    if (v && v.trim()) store.updateMemory(m.id, v.trim());
  },
  'delete-memory': (el) => store.deleteMemory(el.dataset.id),
  'chat-send': (el) => {
    const scope = el.dataset.scope || null;
    const key = `chat-${scope || 'all'}`;
    const text = trim(ui.drafts[key]);
    if (!text || chat.responding) return;
    ui.drafts[key] = '';
    wasNearBottom = true;
    chat.send(text, scope);
  },
  'chat-suggest': (el) => { wasNearBottom = true; chat.send(el.dataset.text, el.dataset.scope || null); },
  'chat-stop': () => chat.stop(),
  'clear-chat': (el) => { if (confirm('Очистить переписку?')) chat.clear(el.dataset.scope || null); },
  'load-models': async (el) => {
    const p = el.dataset.p;
    ui.modelsLoading = p; render();
    try {
      const cfg = settings.llmConfig(p);
      if (ui.drafts[`key:${p}`] !== undefined) cfg.apiKey = trim(ui.drafts[`key:${p}`]);
      ui.models[p] = await listModels(cfg);
      if (!ui.models[p].length) toast('Сервер не вернул список моделей', 'error');
      else toast(`Моделей: ${ui.models[p].length}. Начните вводить название — появятся подсказки.`);
    } catch (e) { toast(e.message, 'error'); }
    ui.modelsLoading = null; render();
  },
  'paste-key': async (el) => {
    try {
      const t = (await navigator.clipboard.readText()).trim();
      ui.drafts[`key:${el.dataset.p}`] = t;
      render();
    } catch { toast('Вставьте ключ вручную (долгое нажатие → Вставить)', 'error'); }
  },
  'reveal-key': (el) => {
    const inp = document.getElementById(`key-${el.dataset.p}`);
    if (inp) inp.type = inp.type === 'password' ? 'text' : 'password';
  },
  'save-key': async (el) => {
    const p = el.dataset.p;
    if (ui.drafts[`key:${p}`] !== undefined) settings.setApiKey(p, ui.drafts[`key:${p}`]);
    if (ui.drafts[`base:${p}`] !== undefined) settings.setBaseURL(p, ui.drafts[`base:${p}`]);
    delete ui.drafts[`key:${p}`];
    ui.keyTest[p] = { busy: true };
    render();
    try {
      if (p === 'deepgram') {
        await verifyDeepgram(settings.apiKey(p));
        ui.keyTest[p] = { ok: true, text: 'Ключ Deepgram работает' };
      } else {
        const cfg = settings.llmConfig(p);
        const r = await complete(cfg, 'Отвечай очень кратко.', [{ role: 'user', content: 'Скажи «работает» одним словом.' }]);
        ui.keyTest[p] = { ok: true, text: `Ответ модели ${cfg.model}: ${r.trim().slice(0, 60)}` };
      }
    } catch (e) {
      ui.keyTest[p] = { ok: false, text: e.message || String(e) };
    }
    render();
  },
  'delete-key': (el) => { settings.setApiKey(el.dataset.p, ''); delete ui.drafts[`key:${el.dataset.p}`]; ui.keyTest[el.dataset.p] = null; render(); },
  'omi-pair': async () => {
    try { await omi.pair(); toast('Omi подключён'); } catch (e) { if (e.name !== 'NotFoundError') toast(e.message, 'error'); }
    render();
  },
  'omi-forget': () => { omi.disconnect(true); render(); },
  'export-json': async () => {
    const file = new File([store.exportJSON()], `Vox-backup-${fmt.fileStamp(new Date())}.json`, { type: 'application/json' });
    await shareOrDownload({ title: 'Vox backup', file });
  },
  'delete-all': async () => {
    if (!confirm('Удалить все записи, задачи, память и чат? Это нельзя отменить.')) return;
    await store.deleteAll();
    toast('Все данные удалены');
  },
};

const changeActions = {
  'import-audio': async (input) => {
    const files = [...input.files];
    input.value = '';
    let lastId = null;
    for (const f of files) {
      const c = newConversation('imported');
      c.startedAt = new Date(f.lastModified || Date.now()).toISOString();
      c.title = f.name.replace(/\.[^.]+$/, '');
      c.templateID = settings.values.defaultTemplate;
      c.audioFile = 'audio';
      c.duration = await probeDuration(f);
      c.finishedAt = new Date(new Date(c.startedAt).getTime() + c.duration * 1000).toISOString();
      c.needsBatchTranscription = true;
      c.needsSummary = settings.values.autoSummarize;
      c.status = 'transcribing';
      await store.putAudio(c.id, f);
      store.insert(c);
      processing.enqueue(c.id);
      lastId = c.id;
    }
    if (files.length === 1 && lastId) go(`c/${lastId}`);
    else if (files.length) toast(`Импортировано файлов: ${files.length}`);
  },
  'import-json': async (input) => {
    const f = input.files[0];
    input.value = '';
    if (!f) return;
    try { const n = await store.importJSON(await f.text()); toast(`Добавлено записей: ${n}`); }
    catch (e) { toast(e.message, 'error'); }
  },
};

function probeDuration(file) {
  return new Promise((resolve) => {
    const a = document.createElement('audio');
    const url = URL.createObjectURL(file);
    const done = (d) => { URL.revokeObjectURL(url); resolve(Number.isFinite(d) ? d : 0); };
    a.preload = 'metadata';
    a.onloadedmetadata = () => done(a.duration);
    a.onerror = () => done(0);
    setTimeout(() => done(a.duration), 5000);
    a.src = url;
  });
}

document.addEventListener('click', (e) => {
  const el = e.target.closest('[data-action]');
  if (!el || el.disabled) return;
  const fn = actions[el.dataset.action];
  if (!fn) return;
  if (el.tagName === 'A' || el.closest('a')) e.preventDefault();
  fn(el, e);
});

document.addEventListener('input', (e) => {
  const el = e.target;
  if (el.dataset.draft !== undefined) ui.drafts[el.dataset.draft] = el.value;
  if (el.dataset.live) { ui[el.dataset.live] = el.value; render(); }
  if (el.tagName === 'TEXTAREA' && el.closest('.composer')) {
    el.style.height = 'auto';
    el.style.height = Math.min(160, el.scrollHeight) + 'px';
  }
});

document.addEventListener('change', (e) => {
  const el = e.target;
  if (el.dataset.actionChange) { changeActions[el.dataset.actionChange]?.(el); return; }
  if (el.dataset.setting) {
    const t = el.dataset.type;
    const v = t === 'bool' ? el.checked : t === 'number' ? Number(el.value) : el.value;
    settings.set(el.dataset.setting, v);
  }
  if (el.dataset.model) settings.setModel(el.dataset.model, el.value);
});

document.addEventListener('keydown', (e) => {
  const el = e.target;
  if (e.key !== 'Enter' || !el.dataset.enter) return;
  if (el.tagName === 'TEXTAREA' && (e.shiftKey || isIOS())) return; // on iPhone Enter = new line; send with the button
  e.preventDefault();
  actions[el.dataset.enter]?.(el, e);
});

// ---------------------------------------------------------------- live UI updates (no full re-render)

function updateLive() {
  const meter = document.getElementById('rec-meter');
  if (meter) {
    const bars = meter.children;
    const lvl = Math.min(1, recorder.level * 6);
    for (let i = 0; i < bars.length; i++) bars[i].classList.toggle('on', lvl > i / bars.length);
  }
  for (const t of document.querySelectorAll('.rec-time')) t.textContent = fmt.clock(recorder.elapsed);
}

recorder.on('level', updateLive);
recorder.on('tick', updateLive);
recorder.on('change', render);
const onText = () => {
  const tail = document.getElementById('live-tail');
  if (tail) tail.innerHTML = liveTailHTML();
  const full = document.getElementById('live-full');
  if (full) {
    full.innerHTML = liveFullHTML();
    if (wasNearBottom) $view.scrollTop = $view.scrollHeight;
  } else if (route()[0] === 'live') render();
};
recorder.on('transcript', onText);
recorder.on('interim', onText);

store.on('change', () => {
  // Avoid re-rendering under the user's fingers while typing in settings fields.
  const a = document.activeElement;
  if (a && $view.contains(a) && (a.dataset.setting || a.dataset.model) && route()[0] === 'settings') return;
  render();
});
settings.on('change', (k) => {
  const a = document.activeElement;
  if (a && (a.dataset.setting === k) && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA')) return;
  render();
});
omi.on('change', render);
window.addEventListener('hashchange', () => { closeModal(); render(); });
window.addEventListener('beforeunload', (e) => {
  if (recorder.isRecording) { e.preventDefault(); e.returnValue = ''; }
});

// ---------------------------------------------------------------- boot

async function boot() {
  render();
  try {
    await store.init();
  } catch (e) {
    $view.innerHTML = `<div class="content">${empty('⚠︎', 'Не удалось открыть хранилище', e.message)}</div>`;
    return;
  }
  await processing.resumePending(null);
  const est = await store.estimate();
  if (est) ui.storage = `${fmt.bytes(est.usage || 0)} из ${fmt.bytes(est.quota || 0)}`;
  render();
  if ('serviceWorker' in navigator && location.protocol === 'https:') {
    navigator.serviceWorker.register('sw.js').catch(() => {});
  }
  if (omi.supported && omi.hasSaved) omi.reconnect();
}

boot();
window.__vox = { store, settings, recorder, processing, omi, uuid };
