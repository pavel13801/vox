// Summaries (templates, map-reduce for long recordings) and "chat with your recordings".
import { complete, stream, extractJSONObject } from './llm.js';
import { settings, SUMMARY_LANGUAGES } from './settings.js';
import { store, conv } from './store.js';
import { fmt, uuid } from './util.js';

export const TEMPLATES = [
  { id: 'standard', title: 'Сводка', icon: '📝', instructions:
    'Поле overview: связный пересказ сути разговора в 3–8 предложениях: о чём шла речь, к чему пришли, что важно запомнить. Если разговор длинный — разбей на короткие абзацы.' },
  { id: 'meeting', title: 'Встреча / протокол', icon: '👥', instructions:
    'Поле overview: протокол встречи в Markdown с разделами **Участники**, **Обсуждали**, **Решения**, **Открытые вопросы**, **Следующие шаги**. Под каждым — маркированный список. Указывай, кто что сказал или пообещал, если это понятно.' },
  { id: 'lecture', title: 'Лекция / конспект', icon: '🎓', instructions:
    'Поле overview: подробный структурированный конспект в Markdown: заголовки ### по темам, под ними тезисы, определения, формулы, примеры, выводы. Сохраняй все важные факты, цифры и термины.' },
  { id: 'call', title: 'Звонок / переговоры', icon: '📞', instructions:
    'Поле overview: в Markdown — **Суть звонка**, **Договорённости** (кто, что, когда, суммы), **Условия и цифры**, **Риски и спорные моменты**.' },
  { id: 'interview', title: 'Интервью', icon: '🎤', instructions:
    'Поле overview: в Markdown — краткое введение (кто и о чём), затем ключевые вопросы и ответы в формате **В:** … / **О:** …, в конце — главные выводы.' },
  { id: 'ideas', title: 'Идеи / мозговой штурм', icon: '💡', instructions:
    'Поле overview: в Markdown — сгруппированный список всех высказанных идей (### группа, под ней пункты), для каждой идеи — одна строка сути; в конце — самые перспективные идеи.' },
  { id: 'diary', title: 'Дневник / мысли', icon: '📔', instructions:
    'Поле overview: бережный пересказ от второго лица («Ты рассказал…»): события, мысли, чувства, инсайты. В конце одна строка о настроении.' },
  { id: 'dictation', title: 'Чистовой текст диктовки', icon: '📄', instructions:
    'Поле overview: полный чистовой текст диктовки — сохрани ВСЁ содержание и порядок мыслей, но убери слова-паразиты, повторы и оговорки, расставь пунктуацию и абзацы. Ничего не сокращай и не добавляй от себя.' },
];
export const template = (id) => TEMPLATES.find(t => t.id === id) || TEMPLATES[0];

export const CATEGORIES = ['Работа', 'Личное', 'Учёба', 'Здоровье', 'Финансы', 'Идеи', 'Семья', 'Покупки', 'Путешествия', 'Технологии', 'Встреча', 'Другое'];

function systemPrompt(tpl) {
  const v = settings.values;
  let s = `Ты — аккуратный ассистент-аналитик. Тебе дают расшифровку аудиозаписи (разговор, встреча, лекция или диктовка). Расшифровка сделана автоматически: в ней бывают ошибки распознавания и перепутанные спикеры — понимай смысл по контексту. Не выдумывай фактов, которых нет в записи.

${(SUMMARY_LANGUAGES[v.summaryLanguage] || SUMMARY_LANGUAGES.russian).instruction}

Верни ТОЛЬКО один JSON-объект (без \`\`\` и пояснений) со схемой:
{
  "title": "короткое ёмкое название, 3–8 слов, без кавычек и даты",
  "emoji": "один подходящий эмодзи",
  "category": "одна из: ${CATEGORIES.join(', ')}",
  "overview": "строка (можно Markdown) — см. инструкцию ниже",
  "key_points": ["3–10 самых важных тезисов, фактов, цифр"],
  "action_items": [{"text": "конкретное действие, начинай с глагола", "due": "YYYY-MM-DD или null"}],
  "memories": ["долговременные факты о пользователе"],
  "speaker_names": {"0": "Имя"}
}

Инструкция для overview:
${tpl.instructions}

`;
  s += v.extractTasks
    ? 'action_items: только реальные задачи, обещания и договорённости, которые нужно выполнить пользователю (или которые он поручил/принял). Не придумывай задач. Относительные сроки («завтра», «в пятницу») переводи в дату относительно даты записи. Если задач нет — пустой массив.\n\n'
    : 'action_items: всегда пустой массив.\n\n';
  if (v.extractMemories) {
    s += 'memories: 0–5 новых устойчивых фактов о самом пользователе, полезных в будущем (люди в его жизни, предпочтения, планы, работа, здоровье, важные даты). Формулируй от третьего лица одной фразой. Не повторяй уже известные факты. Мелочи и содержание чужих разговоров сюда не попадают.\n\n';
    const known = store.memories.slice(0, 80).map(m => '- ' + m.text).join('\n');
    if (known) s += `Уже известные факты (не дублируй):\n${known}\n\n`;
  } else {
    s += 'memories: всегда пустой массив.\n\n';
  }
  s += 'speaker_names: заполняй, только если из разговора однозначно понятно, как зовут спикера (к нему обращаются по имени или он представляется). Ключ — номер спикера минус один (Спикер 1 → "0"). Иначе пустой объект.\n\n';
  if (v.userName.trim()) s += `Пользователя (владельца записи) зовут ${v.userName.trim()}.\n`;
  if (v.customInstructions.trim()) s += `\nДополнительные пожелания пользователя:\n${v.customInstructions.trim()}\n`;
  return s;
}

async function condense(c, cfg, chunkChars) {
  const chunks = [];
  let cur = '';
  for (const s of c.segments) {
    const line = `[${fmt.clock(s.start)}] ${conv.speakerName(c, s.speaker)}: ${s.text}\n`;
    if (cur.length + line.length > chunkChars && cur) { chunks.push(cur); cur = ''; }
    cur += line;
  }
  if (cur) chunks.push(cur);
  const sys = 'Ты делаешь подробный конспект части длинной расшифровки. Сохрани все факты, решения, договорённости, задачи, имена, цифры и даты, ход обсуждения. Пиши компактно, Markdown-списком. Не добавляй ничего от себя.';
  const notes = [];
  for (let i = 0; i < chunks.length; i++) {
    const r = await complete(cfg, sys, [{ role: 'user', content: `Часть ${i + 1} из ${chunks.length}:\n\n${chunks[i]}` }]);
    notes.push(`### Часть ${i + 1}\n${r.trim()}`);
  }
  return notes.join('\n\n');
}

export async function summarize(c) {
  const cfg = settings.llmConfig();
  const tpl = template(c.templateID);
  let transcript = conv.transcript(c);
  let isNotes = false;
  const limit = Math.max(40000, settings.values.maxContextChars);
  if (transcript.length > limit) {
    transcript = await condense(c, cfg, Math.floor(limit / 2));
    isNotes = true;
  }
  let user = `Дата и время записи: ${fmt.long(c.startedAt)} (сегодня ${fmt.isoDay(new Date())}).\nДлительность: ${fmt.duration(c.duration)}.\n\n`;
  user += isNotes
    ? `Запись очень длинная, поэтому ниже — подробные конспекты её частей по порядку.\n\nКОНСПЕКТЫ:\n${transcript}`
    : `ТРАНСКРИПТ:\n${transcript}`;
  const reply = await complete(cfg, systemPrompt(tpl), [{ role: 'user', content: user }], { json: true });
  const obj = extractJSONObject(reply);
  if (!obj) return { title: '', emoji: '🎙️', category: '', overview: reply.trim(), keyPoints: [], actionItems: [], memories: [], speakerNames: {} };
  const str = (k) => (typeof obj[k] === 'string' ? obj[k].trim() : '');
  const strings = (k) => (Array.isArray(obj[k]) ? obj[k] : [])
    .map(x => typeof x === 'string' ? x : (x?.text || x?.point || x?.content || ''))
    .map(x => String(x).trim()).filter(Boolean);
  const actionItems = (Array.isArray(obj.action_items) ? obj.action_items : []).map(x => {
    if (typeof x === 'string') return { text: x.trim(), due: null };
    const due = typeof x?.due === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(x.due) ? x.due : null;
    return { text: String(x?.text || '').trim(), due };
  }).filter(x => x.text);
  const speakerNames = {};
  if (obj.speaker_names && typeof obj.speaker_names === 'object') {
    for (const [k, v] of Object.entries(obj.speaker_names)) if (/^\d+$/.test(k) && typeof v === 'string' && v.trim()) speakerNames[k] = v.trim();
  }
  let emoji = str('emoji');
  if (!emoji || [...emoji].length > 3) emoji = [...(emoji || '🎙️')][0] || '🎙️';
  return {
    title: str('title').replace(/^["«»]+|["«»]+$/g, ''),
    emoji, category: str('category'), overview: str('overview'),
    keyPoints: strings('key_points'), actionItems, memories: strings('memories'), speakerNames,
  };
}

// ---------------------------------------------------------------- chat

const STOP = new Set(['какой', 'какая', 'какие', 'когда', 'почему', 'зачем', 'сколько', 'который', 'которые', 'этот', 'этой', 'этом',
  'было', 'были', 'была', 'будет', 'есть', 'меня', 'мной', 'тебя', 'чтобы', 'только', 'очень', 'можно', 'нужно', 'надо',
  'about', 'what', 'when', 'which', 'where', 'there', 'have', 'this', 'that', 'расскажи', 'напомни', 'скажи', 'говорил',
  'говорили', 'сказал', 'сказали', 'запись', 'записи', 'разговор']);

function rank(convs, q) {
  q = q.toLowerCase();
  const stems = q.split(/[^\p{L}\p{N}]+/u).filter(w => w.length >= 4 && !STOP.has(w))
    .map(w => w.slice(0, Math.max(4, Math.min(6, w.length - 2))));
  const now = Date.now();
  let dayFilter = null;
  if (q.includes('сегодня')) dayFilter = d => new Date(d).toDateString() === new Date().toDateString();
  else if (q.includes('вчера')) { const y = new Date(); y.setDate(y.getDate() - 1); dayFilter = d => new Date(d).toDateString() === y.toDateString(); }
  else if (q.includes('недел')) dayFilter = d => now - new Date(d) < 7 * 86400e3;
  const scored = [];
  for (const c of convs) {
    let score = 0;
    if (dayFilter && dayFilter(c.startedAt)) score += 50;
    if (stems.length) {
      const hay = `${c.title} ${c.overview} ${(c.keyPoints || []).join(' ')} ${conv.plain(c)}`.toLowerCase();
      const head = `${c.title} ${c.overview}`.toLowerCase();
      for (const st of stems) {
        const n = hay.split(st).length - 1;
        if (n > 0) score += 5 + Math.min(n, 20);
        if (head.includes(st)) score += 10;
      }
    }
    if (score > 0) scored.push([c, score]);
  }
  if (!scored.length) return convs.slice(0, 3);
  return scored.sort((a, b) => b[1] - a[1]).slice(0, 8).map(x => x[0]);
}

function block(c, limit) {
  let b = `=== ${c.emoji} ${conv.displayTitle(c)} — ${fmt.long(c.startedAt)}, ${fmt.duration(c.duration)} ===\n`;
  if (c.overview) b += `Сводка: ${c.overview}\n`;
  if (c.keyPoints?.length) b += `Тезисы: ${c.keyPoints.join('; ')}\n`;
  if (c.segments?.length) {
    let t = conv.transcript(c);
    if (t.length > limit) t = t.slice(0, limit) + '\n…(расшифровка обрезана)';
    b += `Расшифровка:\n${t}\n`;
  }
  return b + '\n';
}

function chatSystem(question, scopeId) {
  const budget = Math.max(30000, settings.values.maxContextChars);
  let s = `Ты — личный ассистент пользователя приложения-диктофона Vox. У тебя есть доступ к его записям: расшифровкам разговоров, встреч, лекций и диктовок, к их сводкам, задачам и фактам о пользователе. Отвечай по существу, опираясь на записи; если ссылаешься на запись — указывай её дату и название. Если в записях нет ответа — честно скажи об этом, можешь ответить из общих знаний, явно пометив это. Расшифровки автоматические и могут содержать ошибки распознавания. Отвечай на языке вопроса. Можно использовать Markdown.
Сегодня: ${fmt.long(new Date())}.
`;
  if (settings.values.userName.trim()) s += `Пользователя зовут ${settings.values.userName.trim()}.\n`;
  if (scopeId) {
    const c = store.conversation(scopeId);
    if (c) return s + '\nВопросы касаются одной конкретной записи.\n\n' + block(c, budget);
  }
  if (store.memories.length) s += '\nФАКТЫ О ПОЛЬЗОВАТЕЛЕ:\n' + store.memories.slice(0, 200).map(m => `- ${m.text}`).join('\n') + '\n';
  const open = store.actionItems.filter(t => !t.done);
  if (open.length) s += '\nОТКРЫТЫЕ ЗАДАЧИ:\n' + open.slice(0, 100).map(t => `- ${t.text}${t.dueDate ? ` (до ${t.dueDate.slice(0, 10)})` : ''}`).join('\n') + '\n';
  const convs = store.conversations.filter(c => c.status !== 'recording' || conv.hasSpeech(c));
  const ranked = rank(convs, question);
  const tBudget = Math.floor(budget * 0.6);
  const full = new Set();
  let blocks = '';
  for (const c of ranked) {
    const remaining = tBudget - s.length - blocks.length;
    if (remaining < 2000) break;
    blocks += block(c, remaining);
    full.add(c.id);
  }
  if (blocks) s += '\nНАИБОЛЕЕ ПОДХОДЯЩИЕ К ВОПРОСУ ЗАПИСИ (с расшифровкой):\n\n' + blocks;
  let index = '';
  for (const c of convs) {
    if (full.has(c.id)) continue;
    let ov = (c.overview || conv.plain(c).slice(0, 200)).replace(/\n/g, ' ');
    if (ov.length > 400) ov = ov.slice(0, 400) + '…';
    const line = `- [${fmt.short(c.startedAt)}] ${c.emoji} ${conv.displayTitle(c)}: ${ov}\n`;
    if (s.length + index.length + line.length > budget) break;
    index += line;
  }
  if (index) s += '\nДРУГИЕ ЗАПИСИ (только сводки, новые сверху):\n' + index;
  return s;
}

export const chat = {
  responding: false,
  controller: null,
  scoped: new Map(), // convId -> messages (memory only)

  messages(scopeId) { return scopeId ? (this.scoped.get(scopeId) || []) : store.chatMessages; },

  async send(text, scopeId = null) {
    const q = text.trim();
    if (!q || this.responding) return;
    const user = { id: uuid(), role: 'user', text: q, createdAt: new Date().toISOString(), isError: false };
    const answer = { id: uuid(), role: 'assistant', text: '', createdAt: new Date().toISOString(), isError: false };
    const history = this.messages(scopeId).slice(-12).filter(m => !m.isError && m.text).map(m => ({ role: m.role, content: m.text }));
    if (scopeId) {
      const list = this.scoped.get(scopeId) || [];
      list.push(user, answer);
      this.scoped.set(scopeId, list);
      store.changed();
    } else {
      store.appendChat(user);
      store.appendChat(answer);
    }
    const set = (t, persist, isError = false) => {
      if (scopeId) { answer.text = t; answer.isError = isError; store.changed(); }
      else store.updateChat(answer.id, t, isError, persist);
    };
    this.responding = true;
    this.controller = new AbortController();
    store.changed();
    let acc = '', last = 0;
    try {
      await stream(settings.llmConfig(), chatSystem(q, scopeId), [...history, { role: 'user', content: q }], (piece) => {
        acc += piece;
        if (Date.now() - last > 80) { last = Date.now(); set(acc, false); }
      }, this.controller.signal);
      set(acc || '(пустой ответ)', true);
    } catch (e) {
      if (e.name === 'AbortError') set(acc || '(остановлено)', true);
      else set(acc ? `${acc}\n\n⚠️ ${e.message}` : `⚠️ ${e.message}`, true, !acc);
    }
    this.responding = false;
    this.controller = null;
    store.changed();
  },

  stop() { this.controller?.abort(); },

  clear(scopeId) {
    this.stop();
    if (scopeId) { this.scoped.set(scopeId, []); store.changed(); } else store.clearChat();
  },
};
