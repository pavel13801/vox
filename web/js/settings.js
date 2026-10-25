// Settings, API keys and the provider registry (built-in + user-defined), kept in localStorage.
import { Emitter, uuid } from './util.js';

/**
 * kind:  'openai'    — OpenAI-compatible API (/chat/completions, /models, /audio/transcriptions)
 *        'anthropic' — Anthropic Messages API
 *        'deepgram'  — Deepgram (speech only)
 * stt:   default way this provider transcribes files: 'deepgram' | 'whisper' (/audio/transcriptions)
 *        | 'chat' (chat model that accepts audio input, e.g. Gemini) | null (cannot transcribe)
 * blocked: the provider blocks some countries (Russia) — route through the proxy when one is set.
 */
export const BUILTIN = {
  deepgram: {
    title: 'Deepgram', kind: 'deepgram', base: 'https://api.deepgram.com/v1', llm: false, stt: 'deepgram',
    model: '', models: [], sttModel: 'nova-3', sttModels: ['nova-3', 'nova-2'],
    hint: 'console.deepgram.com → API Keys ($200 бесплатно). Live-расшифровка со спикерами.', url: 'https://console.deepgram.com',
  },
  gemini: {
    title: 'Google Gemini', kind: 'openai', base: 'https://generativelanguage.googleapis.com/v1beta/openai', llm: true, stt: 'chat', blocked: true,
    model: 'gemini-3.8-flash', models: ['gemini-3.8-flash', 'gemini-flash-latest', 'gemini-flash-lite-latest', 'gemini-pro-latest'],
    sttModel: 'gemini-3.8-flash', sttModels: ['gemini-3.8-flash', 'gemini-flash-latest', 'gemini-pro-latest'],
    hint: 'aistudio.google.com → Get API key. Ключ начинается с «AIza». Google не обслуживает Россию — нужен VPN или прокси.',
    url: 'https://aistudio.google.com/apikey',
  },
  openai: {
    title: 'OpenAI', kind: 'openai', base: 'https://api.openai.com/v1', llm: true, stt: 'whisper', blocked: true,
    model: 'gpt-5-mini', models: ['gpt-5-mini', 'gpt-5', 'gpt-5-nano', 'gpt-4.1-mini', 'gpt-4o-mini'],
    sttModel: 'whisper-1', sttModels: ['whisper-1', 'gpt-4o-transcribe', 'gpt-4o-mini-transcribe'],
    hint: 'platform.openai.com → API keys. Россия заблокирована — нужен VPN или прокси.', url: 'https://platform.openai.com/api-keys',
  },
  groq: {
    title: 'Groq', kind: 'openai', base: 'https://api.groq.com/openai/v1', llm: true, stt: 'whisper',
    model: 'openai/gpt-oss-120b', models: ['openai/gpt-oss-120b', 'llama-3.3-70b-versatile', 'moonshotai/kimi-k2-instruct'],
    sttModel: 'whisper-large-v3', sttModels: ['whisper-large-v3', 'whisper-large-v3-turbo'],
    hint: 'console.groq.com → API Keys (бесплатно, есть Whisper для расшифровки).', url: 'https://console.groq.com/keys',
  },
  openrouter: {
    title: 'OpenRouter', kind: 'openai', base: 'https://openrouter.ai/api/v1', llm: true, stt: 'chat',
    model: 'google/gemini-3.8-flash', models: ['google/gemini-3.8-flash', 'openai/gpt-5-mini', 'anthropic/claude-haiku-5-5', 'deepseek/deepseek-chat', 'x-ai/grok-4', 'qwen/qwen3-max'],
    sttModel: 'google/gemini-3.8-flash', sttModels: ['google/gemini-3.8-flash', 'openai/gpt-4o-audio-preview'],
    hint: 'openrouter.ai → Keys. Сотни моделей по одному ключу, работает из России. Расшифровка — через Gemini на OpenRouter.',
    url: 'https://openrouter.ai/keys',
  },
  anthropic: {
    title: 'Anthropic (Claude)', kind: 'anthropic', base: 'https://api.anthropic.com/v1', llm: true, stt: null, blocked: true,
    model: 'claude-haiku-5-5', models: ['claude-haiku-5-5', 'claude-sonnet-5-5', 'claude-opus-5-5'], sttModel: '', sttModels: [],
    hint: 'console.anthropic.com → API Keys. Россия заблокирована — нужен VPN или прокси.', url: 'https://console.anthropic.com/settings/keys',
  },
  deepseek: {
    title: 'DeepSeek', kind: 'openai', base: 'https://api.deepseek.com/v1', llm: true, stt: null,
    model: 'deepseek-chat', models: ['deepseek-chat', 'deepseek-reasoner'], sttModel: '', sttModels: [],
    hint: 'platform.deepseek.com → API keys. Работает из России.', url: 'https://platform.deepseek.com/api_keys',
  },
};

/** Templates for "Add your own provider". */
export const PRESETS = [
  { title: 'Mistral', kind: 'openai', base: 'https://api.mistral.ai/v1', model: 'mistral-large-latest', stt: null, url: 'https://console.mistral.ai/api-keys' },
  { title: 'xAI Grok', kind: 'openai', base: 'https://api.x.ai/v1', model: 'grok-4', stt: null, url: 'https://console.x.ai' },
  { title: 'Qwen (Alibaba)', kind: 'openai', base: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1', model: 'qwen-plus', stt: null, url: 'https://bailian.console.alibabacloud.com' },
  { title: 'Moonshot Kimi', kind: 'openai', base: 'https://api.moonshot.ai/v1', model: 'kimi-k2-0905-preview', stt: null, url: 'https://platform.moonshot.ai' },
  { title: 'Together AI', kind: 'openai', base: 'https://api.together.xyz/v1', model: 'meta-llama/Llama-3.3-70B-Instruct-Turbo', stt: null, url: 'https://api.together.ai' },
  { title: 'Fireworks', kind: 'openai', base: 'https://api.fireworks.ai/inference/v1', model: 'accounts/fireworks/models/llama-v3p3-70b-instruct', stt: 'whisper', sttModel: 'whisper-v3', url: 'https://fireworks.ai' },
  { title: 'Cerebras', kind: 'openai', base: 'https://api.cerebras.ai/v1', model: 'gpt-oss-120b', stt: null, url: 'https://cloud.cerebras.ai' },
  { title: 'Perplexity', kind: 'openai', base: 'https://api.perplexity.ai', model: 'sonar', stt: null, url: 'https://www.perplexity.ai/settings/api' },
  { title: 'Ollama / LM Studio', kind: 'openai', base: 'http://localhost:11434/v1', model: 'llama3.1', stt: null, url: '' },
  { title: 'Другой (OpenAI-совместимый)', kind: 'openai', base: '', model: '', stt: null, url: '' },
  { title: 'Другой (Anthropic-совместимый)', kind: 'anthropic', base: '', model: '', stt: null, url: '' },
];

export const STT_ENGINES = {
  whisper: 'Whisper API (/audio/transcriptions)',
  chat: 'Модель с поддержкой аудио (чат)',
};

export const LANGUAGES = [
  ['ru', 'Русский'], ['multi', 'Мультиязычный (рус + англ и др.)'], ['en', 'English'], ['uk', 'Українська'],
  ['de', 'Deutsch'], ['es', 'Español'], ['fr', 'Français'], ['it', 'Italiano'], ['pt', 'Português'], ['tr', 'Türkçe'], ['kk', 'Қазақ'],
];

export const SUMMARY_LANGUAGES = {
  russian: { title: 'Русский', instruction: 'Пиши все поля строго на русском языке.' },
  auto: { title: 'Как в разговоре', instruction: 'Пиши на том языке, на котором в основном ведётся разговор.' },
  english: { title: 'English', instruction: 'Write every field in English.' },
};

const DEFAULTS = {
  userName: '',
  transcriptionMode: 'live', // live | afterRecording
  deepgramModel: 'nova-3',
  language: 'ru',
  diarize: true,
  keyterms: '',
  batchProvider: 'deepgram',
  alwaysRetranscribe: false,
  llmProvider: 'gemini',
  summaryLanguage: 'russian',
  defaultTemplate: 'standard',
  extractMemories: true,
  extractTasks: true,
  customInstructions: '',
  autoSummarize: true,
  maxContextChars: 300000,
  autoSplitMinutes: 0,
  deleteEmpty: true,
  keepScreenOn: true,
  preferredSource: 'phone',
  vadThreshold: 0.015,
  audioBitrate: 32000,
  models: {},        // provider -> chat model
  sttModels: {},     // provider -> transcription model
  sttEngines: {},    // provider -> 'whisper' | 'chat'
  baseURLs: {},      // provider -> base URL override
  useProxy: {},      // provider -> boolean
  proxyURL: '',
  customProviders: [],
};

const KEY = 'vox.settings.v1';
const KEYS = 'vox.keys.v1';
const COOL = 'vox.keyPause.v1';

/** Short non-reversible id of a key, used to remember its pause. */
function keyId(key) {
  let h = 5381;
  for (let i = 0; i < key.length; i++) h = ((h << 5) + h + key.charCodeAt(i)) >>> 0;
  return `${h.toString(36)}${key.length}`;
}

/** Milliseconds until the next midnight in California — when Google resets daily Gemini quotas. */
function msUntilPacificMidnight() {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Los_Angeles', hour: 'numeric', minute: 'numeric', second: 'numeric', hourCycle: 'h23',
  }).formatToParts(new Date()).map(x => [x.type, x.value]));
  const passed = (Number(parts.hour) * 3600 + Number(parts.minute) * 60 + Number(parts.second)) * 1000;
  return Math.max(60_000, 86_400_000 - passed + 60_000);
}

/** Decides whether an API error means "this key is used up — try the next one", and for how long. */
export function keyPause(e) {
  const status = e.status || 0;
  const text = `${e.body || ''} ${e.message || ''}`;
  if (/location is not supported|unsupported_country|country, region, or territory|not available in your (country|region)/i.test(text)) return null;
  if (status === 429 || /resource_exhausted|quota|rate.?limit|too many requests/i.test(text)) {
    if (/per ?day|perday|daily|requests per day|RPD/i.test(text)) return { ms: msUntilPacificMidnight(), reason: 'дневной лимит исчерпан' };
    const m = text.match(/retry(?:Delay)?["\s:]*(?:in\s*)?"?([\d.]+)\s*s/i);
    const sec = m ? Math.ceil(Number(m[1])) + 2 : 65;
    return { ms: Math.min(sec, 3600) * 1000, reason: 'лимит запросов в минуту' };
  }
  if (status === 402 || /insufficient|balance|out of credit|credits? exhausted|payment required/i.test(text)) return { ms: 86_400_000, reason: 'закончились деньги на счёте' };
  if (status === 401 || /api key not valid|api_key_invalid|pass a valid api key|invalid[_ ]api[_ ]key|incorrect api key|invalid x-api-key|invalid credentials/i.test(text)) return { ms: 3_600_000, reason: 'ключ не принят' };
  if (status === 403) return { ms: 3_600_000, reason: 'нет доступа' };
  return null;
}

class Settings extends Emitter {
  constructor() {
    super();
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem(KEY) || '{}'); } catch {}
    this.values = { ...DEFAULTS, ...saved };
    try { this.keys = JSON.parse(localStorage.getItem(KEYS) || '{}'); } catch { this.keys = {}; }
    try { this.cooldown = JSON.parse(localStorage.getItem(COOL) || '{}'); } catch { this.cooldown = {}; }
    this.lastUsed = {};
    this.migrate();
  }

  migrate() {
    const v = this.values;
    let changed = false;
    // v1 had a single built-in "custom" provider.
    if (v.baseURLs?.custom && !v.customProviders.some(p => p.migrated)) {
      const id = 'c_' + uuid().slice(0, 8).toLowerCase();
      v.customProviders = [...v.customProviders, { id, title: 'Свой сервер', kind: 'openai', base: v.baseURLs.custom, stt: null, migrated: true }];
      if (this.keys.custom) { this.keys[id] = this.keys.custom; }
      if (v.models?.custom) v.models = { ...v.models, [id]: v.models.custom };
      if (v.llmProvider === 'custom') v.llmProvider = id;
      changed = true;
    }
    if (v.llmProvider === 'custom') { v.llmProvider = 'gemini'; changed = true; }
    const oldBatch = { groqWhisper: 'groq', openaiWhisper: 'openai' }[v.batchProvider];
    if (oldBatch) {
      if (v.batchModel) v.sttModels = { ...v.sttModels, [oldBatch]: v.batchModel };
      v.batchProvider = oldBatch;
      changed = true;
    }
    if (!this.provider(v.batchProvider)) { v.batchProvider = 'deepgram'; changed = true; }
    if (!this.provider(v.llmProvider)) { v.llmProvider = 'gemini'; changed = true; }
    if (changed) this.save();
  }

  save() { localStorage.setItem(KEY, JSON.stringify(this.values)); }

  get(k) { return this.values[k]; }

  set(k, v) {
    this.values[k] = v;
    this.save();
    this.emit('change', k);
  }

  setIn(map, p, value) { this.set(map, { ...this.values[map], [p]: value }); }

  // ---------------------------------------------------------------- registry

  provider(id) {
    if (BUILTIN[id]) return { id, builtin: true, ...BUILTIN[id] };
    const c = (this.values.customProviders || []).find(p => p.id === id);
    if (!c) return null;
    return {
      id, builtin: false, title: c.title || 'Свой провайдер', kind: c.kind || 'openai', base: c.base || '',
      llm: true, stt: c.stt || null, model: c.model || '', models: [], sttModel: c.sttModel || '', sttModels: [],
      hint: 'Свой провайдер. Нужен HTTPS и разрешённый CORS — иначе включите «Через прокси».', url: c.url || '',
    };
  }

  providerIds() { return [...Object.keys(BUILTIN), ...(this.values.customProviders || []).map(p => p.id)]; }
  llmProviders() { return this.providerIds().filter(id => this.provider(id).llm); }

  /** Providers that can transcribe files (by default or with the engine the user picked). */
  sttProviders() {
    return this.providerIds().filter(id => {
      const p = this.provider(id);
      return p.kind !== 'anthropic' && (p.stt || this.values.sttEngines?.[id]);
    });
  }

  title(id) { return this.provider(id)?.title || id; }

  addCustomProvider(preset = {}) {
    const id = 'c_' + uuid().slice(0, 8).toLowerCase();
    const p = { id, title: preset.title || 'Свой провайдер', kind: preset.kind || 'openai', base: preset.base || '',
      model: preset.model || '', stt: preset.stt || null, sttModel: preset.sttModel || '', url: preset.url || '' };
    this.set('customProviders', [...this.values.customProviders, p]);
    return id;
  }

  updateCustomProvider(id, patch) {
    this.set('customProviders', this.values.customProviders.map(p => (p.id === id ? { ...p, ...patch } : p)));
  }

  removeCustomProvider(id) {
    this.set('customProviders', this.values.customProviders.filter(p => p.id !== id));
    delete this.keys[id];
    localStorage.setItem(KEYS, JSON.stringify(this.keys));
    if (this.values.llmProvider === id) this.set('llmProvider', 'gemini');
    if (this.values.batchProvider === id) this.set('batchProvider', 'deepgram');
  }

  // ---------------------------------------------------------------- keys, models, URLs

  // Several keys per provider (e.g. three Gemini accounts). When one hits its limit it is put on a pause
  // and the next one is used automatically.

  apiKeys(p) {
    const v = this.keys[p];
    return (Array.isArray(v) ? v : v ? [v] : []).map(k => String(k).trim()).filter(Boolean);
  }

  setApiKeys(p, list) {
    const clean = [...new Set((list || []).map(k => String(k || '').trim()).filter(Boolean))];
    if (clean.length) this.keys[p] = clean; else delete this.keys[p];
    localStorage.setItem(KEYS, JSON.stringify(this.keys));
    this.emit('change', 'keys');
  }

  /** The key that will be used now: the first one that is not on a pause. */
  apiKey(p) { return this.orderedKeys(p)[0] || ''; }
  setApiKey(p, v) { this.setApiKeys(p, v ? [v] : []); }

  keyStatus(p, key) {
    const s = this.cooldown[`${p}:${keyId(key)}`];
    if (!s) return null;
    if (s.until && s.until <= Date.now()) return null;
    return s;
  }

  markKey(p, key, ms, reason) {
    if (!key) return;
    this.cooldown[`${p}:${keyId(key)}`] = { until: Date.now() + ms, reason, at: Date.now() };
    localStorage.setItem(COOL, JSON.stringify(this.cooldown));
    this.emit('change', 'keys');
  }

  clearKey(p, key) {
    const id = `${p}:${keyId(key)}`;
    if (!this.cooldown[id]) return;
    delete this.cooldown[id];
    localStorage.setItem(COOL, JSON.stringify(this.cooldown));
    this.emit('change', 'keys');
  }

  /** Available keys first (in the user's order), then paused ones by the time they come back. */
  orderedKeys(p) {
    const keys = this.apiKeys(p);
    const free = keys.filter(k => !this.keyStatus(p, k));
    const paused = keys.filter(k => this.keyStatus(p, k)).sort((a, b) => this.keyStatus(p, a).until - this.keyStatus(p, b).until);
    return [...free, ...paused];
  }

  /**
   * Runs fn(key) with the provider's keys, switching to the next key when the current one is out of quota,
   * out of money or rejected. fixedKey — test exactly this key (no rotation).
   */
  async withKeys(p, fn, { fixedKey } = {}) {
    const keys = fixedKey !== undefined ? [fixedKey] : this.orderedKeys(p);
    if (!keys.length) return fn('');
    let lastErr = null;
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i];
      try {
        const r = await fn(key);
        this.clearKey(p, key);
        this.lastUsed[p] = key;
        return r;
      } catch (e) {
        const pause = e && !e.noRotate ? keyPause(e) : null;
        if (!pause) throw e;
        this.markKey(p, key, pause.ms, pause.reason);
        lastErr = e;
        if (fixedKey !== undefined) throw e;
      }
    }
    if (keys.length > 1) {
      const back = Math.min(...keys.map(k => this.keyStatus(p, k)?.until || Infinity));
      const when = Number.isFinite(back) ? ` Ближайший освободится в ${new Date(back).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' })}.` : '';
      lastErr.message = `${lastErr.message}\n\nВсе ключи (${keys.length}) сейчас на паузе.${when}`;
    }
    throw lastErr;
  }

  hasKey(p) {
    const info = this.provider(p);
    if (!info) return false;
    if (!info.builtin) return !!(info.base);
    return this.apiKeys(p).length > 0;
  }

  model(p) { return this.values.models?.[p] || this.provider(p)?.model || ''; }
  setModel(p, m) {
    const info = this.provider(p);
    if (info && !info.builtin) this.updateCustomProvider(p, { model: String(m || '').trim() });
    else this.setIn('models', p, String(m || '').trim());
  }

  sttEngine(p) {
    const info = this.provider(p);
    if (!info) return null;
    if (info.kind === 'deepgram') return 'deepgram';
    return this.values.sttEngines?.[p] || info.stt || null;
  }

  sttModel(p) {
    if (p === 'deepgram') return this.values.deepgramModel;
    return this.values.sttModels?.[p] || this.provider(p)?.sttModel || (this.sttEngine(p) === 'chat' ? this.model(p) : 'whisper-1');
  }

  baseURL(p) {
    const info = this.provider(p);
    if (!info) return '';
    if (!info.builtin) return info.base;
    return this.values.baseURLs?.[p] || info.base;
  }

  setBaseURL(p, u) {
    const info = this.provider(p);
    if (info && !info.builtin) this.updateCustomProvider(p, { base: String(u || '').trim() });
    else this.setIn('baseURLs', p, String(u || '').trim());
  }

  usesProxy(p) {
    if (!this.values.proxyURL) return false;
    const explicit = this.values.useProxy?.[p];
    if (explicit !== undefined) return !!explicit;
    return !!this.provider(p)?.blocked;
  }

  /** Rewrites https://host/path → <proxy>/host/path when the provider goes through the proxy. */
  route(p, url) {
    if (!this.usesProxy(p)) return url;
    const proxy = this.values.proxyURL.replace(/\/+$/, '');
    return url.replace(/^(https?|wss?):\/\//, (m, scheme) => {
      const ws = scheme.startsWith('ws');
      const base = ws ? proxy.replace(/^http/, 'ws') : proxy;
      return base + '/';
    });
  }

  llmConfig(p = this.values.llmProvider) {
    const info = this.provider(p) || this.provider('gemini');
    return { provider: p, kind: info.kind, title: info.title, baseURL: this.route(p, this.baseURL(p)), apiKey: this.apiKey(p), model: this.model(p), custom: !info.builtin };
  }

  get llmConfigured() { return this.hasKey(this.values.llmProvider); }

  get keytermList() {
    return String(this.values.keyterms || '').split(/[,\n]/).map(s => s.trim()).filter(Boolean);
  }

  batchOptions() {
    const p = this.values.batchProvider;
    const info = this.provider(p) || this.provider('deepgram');
    return {
      provider: p,
      engine: this.sttEngine(p),
      kind: info.kind,
      apiKey: this.apiKey(p),
      baseURL: this.route(p, this.baseURL(p)),
      model: this.sttModel(p),
      language: this.values.language,
      diarize: this.values.diarize,
      keyterms: this.keytermList,
      apiTitle: info.title,
      custom: !info.builtin,
    };
  }

  get deepgramBase() { return this.route('deepgram', this.baseURL('deepgram')); }
}

export const settings = new Settings();
