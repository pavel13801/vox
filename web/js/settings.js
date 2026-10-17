// Settings and API keys (kept in localStorage — the browser storage of this site only).
import { Emitter } from './util.js';

export const PROVIDERS = {
  deepgram: { title: 'Deepgram', base: 'https://api.deepgram.com/v1', model: 'nova-3', models: ['nova-3', 'nova-2'],
    hint: 'console.deepgram.com → API Keys ($200 бесплатно)', url: 'https://console.deepgram.com' },
  gemini: { title: 'Google Gemini', base: 'https://generativelanguage.googleapis.com/v1beta/openai', model: 'gemini-flash-latest',
    models: ['gemini-flash-latest', 'gemini-flash-lite-latest', 'gemini-pro-latest', 'gemini-2.5-flash'],
    hint: 'aistudio.google.com → Get API key (есть бесплатный лимит)', url: 'https://aistudio.google.com/apikey' },
  openai: { title: 'OpenAI', base: 'https://api.openai.com/v1', model: 'gpt-5-mini',
    models: ['gpt-5-mini', 'gpt-5', 'gpt-5-nano', 'gpt-4.1-mini', 'gpt-4o-mini'],
    hint: 'platform.openai.com → API keys', url: 'https://platform.openai.com/api-keys' },
  groq: { title: 'Groq', base: 'https://api.groq.com/openai/v1', model: 'openai/gpt-oss-120b',
    models: ['openai/gpt-oss-120b', 'llama-3.3-70b-versatile', 'moonshotai/kimi-k2-instruct'],
    hint: 'console.groq.com → API Keys (бесплатно)', url: 'https://console.groq.com/keys' },
  openrouter: { title: 'OpenRouter', base: 'https://openrouter.ai/api/v1', model: 'google/gemini-2.5-flash',
    models: ['google/gemini-2.5-flash', 'openai/gpt-5-mini', 'anthropic/claude-haiku-5-5', 'deepseek/deepseek-chat'],
    hint: 'openrouter.ai → Keys', url: 'https://openrouter.ai/keys' },
  anthropic: { title: 'Anthropic (Claude)', base: 'https://api.anthropic.com/v1', model: 'claude-haiku-5-5',
    models: ['claude-haiku-5-5', 'claude-sonnet-5-5', 'claude-opus-5-5'],
    hint: 'console.anthropic.com → API Keys', url: 'https://console.anthropic.com/settings/keys' },
  deepseek: { title: 'DeepSeek', base: 'https://api.deepseek.com/v1', model: 'deepseek-chat', models: ['deepseek-chat', 'deepseek-reasoner'],
    hint: 'platform.deepseek.com → API keys', url: 'https://platform.deepseek.com/api_keys' },
  custom: { title: 'Свой сервер (OpenAI-совместимый)', base: '', model: '', models: [],
    hint: 'Любой OpenAI-совместимый сервер с HTTPS и CORS (Ollama, LM Studio через туннель, прокси)', url: '' },
};

export const LLM_PROVIDERS = ['gemini', 'openai', 'groq', 'openrouter', 'anthropic', 'deepseek', 'custom'];

export const BATCH_PROVIDERS = {
  deepgram: { title: 'Deepgram (со спикерами)', api: 'deepgram', model: 'nova-3' },
  groqWhisper: { title: 'Groq Whisper (бесплатно, без спикеров)', api: 'groq', model: 'whisper-large-v3' },
  openaiWhisper: { title: 'OpenAI Whisper', api: 'openai', model: 'whisper-1' },
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
  batchModel: '',
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
  models: {},
  baseURLs: {},
};

const KEY = 'vox.settings.v1';
const KEYS = 'vox.keys.v1';

class Settings extends Emitter {
  constructor() {
    super();
    let saved = {};
    try { saved = JSON.parse(localStorage.getItem(KEY) || '{}'); } catch {}
    this.values = { ...DEFAULTS, ...saved };
    try { this.keys = JSON.parse(localStorage.getItem(KEYS) || '{}'); } catch { this.keys = {}; }
  }

  get(k) { return this.values[k]; }

  set(k, v) {
    this.values[k] = v;
    localStorage.setItem(KEY, JSON.stringify(this.values));
    this.emit('change', k);
  }

  apiKey(p) { return this.keys[p] || ''; }
  setApiKey(p, v) {
    const t = String(v || '').trim();
    if (t) this.keys[p] = t; else delete this.keys[p];
    localStorage.setItem(KEYS, JSON.stringify(this.keys));
    this.emit('change', 'keys');
  }

  hasKey(p) {
    if (p === 'custom') return !!(this.values.baseURLs?.custom);
    return !!this.apiKey(p);
  }

  model(p) { return this.values.models?.[p] || PROVIDERS[p]?.model || ''; }
  setModel(p, m) { this.set('models', { ...this.values.models, [p]: String(m || '').trim() }); }

  baseURL(p) { return this.values.baseURLs?.[p] || PROVIDERS[p]?.base || ''; }
  setBaseURL(p, u) { this.set('baseURLs', { ...this.values.baseURLs, [p]: String(u || '').trim() }); }

  llmConfig(p = this.values.llmProvider) {
    return { provider: p, baseURL: this.baseURL(p), apiKey: this.apiKey(p), model: this.model(p) };
  }

  get llmConfigured() { return this.hasKey(this.values.llmProvider); }

  get keytermList() {
    return String(this.values.keyterms || '').split(/[,\n]/).map(s => s.trim()).filter(Boolean);
  }

  batchOptions() {
    const bp = BATCH_PROVIDERS[this.values.batchProvider] || BATCH_PROVIDERS.deepgram;
    const model = this.values.batchProvider === 'deepgram'
      ? this.values.deepgramModel
      : (String(this.values.batchModel || '').trim() || bp.model);
    return {
      provider: this.values.batchProvider,
      apiKey: this.apiKey(bp.api),
      baseURL: this.baseURL(bp.api),
      model,
      language: this.values.language,
      diarize: this.values.diarize,
      keyterms: this.keytermList,
      apiTitle: PROVIDERS[bp.api].title,
    };
  }
}

export const settings = new Settings();
