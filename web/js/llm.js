// Browser client for OpenAI-compatible chat APIs and the Anthropic Messages API.
import { settings } from './settings.js';

export function extractError(text) {
  try {
    const j = JSON.parse(text);
    if (Array.isArray(j) && j[0]?.error?.message) return j[0].error.message;
    return j?.error?.message || (typeof j?.error === 'string' ? j.error : '') || j?.err_msg || j?.message || j?.detail || '';
  } catch {
    return String(text || '').slice(0, 300);
  }
}

/** Turns provider errors into an actionable message in Russian. */
export function friendlyError(title, status, body, model = '') {
  const d = extractError(body);
  const all = `${d} ${String(body || '').slice(0, 2000)}`;
  if (/location is not supported|unsupported_country|country, region, or territory|not available in your (country|region)|request not allowed/i.test(all)) {
    return `${title}: сервис недоступен из вашей страны (запросы из России блокируются). Включите VPN на телефоне или настройте прокси: Настройки → Прокси. Ещё вариант — OpenRouter или DeepSeek, они работают из России.`;
  }
  if (/api key not valid|api_key_invalid|pass a valid api key|invalid[_ ]api[_ ]key|incorrect api key|invalid x-api-key|invalid credentials|unauthorized|authentication/i.test(all) || status === 401) {
    return `${title}: ключ не подходит. Проверьте, что он скопирован целиком, без пробелов, и выдан именно для ${title}. (${status}) ${d}`;
  }
  if (status === 404 || /not found|does not exist|no such model|unknown model|model_not_found/i.test(d)) {
    return `${title}: модель «${model}» не найдена. Нажмите ⟳ рядом с моделью, чтобы загрузить список доступных. (${status}) ${d}`;
  }
  if (status === 429 || /quota|rate limit|resource_exhausted/i.test(all)) return `${title}: превышен лимит запросов или квота. Подождите и повторите. ${d}`;
  if (status === 402 || /insufficient|balance|credit/i.test(all)) return `${title}: недостаточно средств на счёте. ${d}`;
  if (status === 403) return `${title}: нет доступа (403). Возможно, ключ без нужных прав или страна заблокирована. ${d}`;
  if (status === 413) return `${title}: файл слишком большой. ${d}`;
  return `${title}: ошибка ${status}. ${d}`;
}

/** fetch with a readable message for network/CORS failures. */
export async function request(url, init, title) {
  try {
    return await fetch(url, init);
  } catch (e) {
    if (e.name === 'AbortError') throw e;
    throw new Error(`Не удалось связаться с ${title}: нет интернета, адрес заблокирован или сервис не принимает запросы из браузера (CORS). Попробуйте VPN или прокси (Настройки → Прокси).`);
  }
}

class HTTPError extends Error {
  constructor(status, message, body = '') { super(message); this.status = status; this.body = body; }
}

/** Error with a readable message that still carries status/body, so key rotation can see the reason. */
export const apiError = (title, status, body, model) => new HTTPError(status, friendlyError(title, status, body, model), body);

function ensure(cfg) {
  if (!cfg.custom && !cfg.apiKey) throw new Error(`Нет API-ключа для ${cfg.title}. Добавьте его в Настройки → Ключи и провайдеры.`);
  if (!cfg.model) throw new Error(`Не выбрана модель для ${cfg.title}.`);
  if (!cfg.baseURL) throw new Error(`Не задан адрес API для ${cfg.title}.`);
}

const base = (cfg) => cfg.baseURL.replace(/\/+$/, '');

function buildRequest(cfg, system, messages, { json = false, stream = false } = {}) {
  ensure(cfg);
  const headers = { 'Content-Type': 'application/json' };
  let url, body;
  if (cfg.kind === 'anthropic') {
    url = `${base(cfg)}/messages`;
    headers['x-api-key'] = cfg.apiKey;
    headers['anthropic-version'] = '2023-06-01';
    headers['anthropic-dangerous-direct-browser-access'] = 'true';
    body = { model: cfg.model, max_tokens: 16000, system, messages };
    if (stream) body.stream = true;
  } else {
    url = `${base(cfg)}/chat/completions`;
    if (cfg.apiKey) headers['Authorization'] = `Bearer ${cfg.apiKey}`;
    if (cfg.provider === 'openrouter') headers['X-Title'] = 'Vox';
    body = { model: cfg.model, messages: [{ role: 'system', content: system }, ...messages] };
    if (json) body.response_format = { type: 'json_object' };
    if (stream) body.stream = true;
  }
  return { url, init: { method: 'POST', headers, body: JSON.stringify(body) } };
}

async function completeOnce(cfg, system, messages, json, signal) {
  const { url, init } = buildRequest(cfg, system, messages, { json });
  const res = await request(url, { ...init, signal }, cfg.title);
  const text = await res.text();
  if (!res.ok) throw apiError(cfg.title, res.status, text, cfg.model);
  const j = JSON.parse(text);
  if (cfg.kind === 'anthropic') {
    const out = (j.content || []).filter(b => b.type === 'text').map(b => b.text).join('');
    if (!out) throw new Error('Модель вернула пустой ответ');
    return out;
  }
  const content = j.choices?.[0]?.message?.content;
  if (typeof content === 'string' && content) return content;
  if (Array.isArray(content)) {
    const out = content.map(p => p.text || '').join('');
    if (out) return out;
  }
  throw new Error('Модель вернула пустой ответ');
}

/** Runs a request with the provider's keys, switching to the next key when one runs out (see settings.withKeys). */
const withKeys = (cfg, fn) => settings.withKeys(cfg.provider, (key) => fn({ ...cfg, apiKey: key }), { fixedKey: cfg.fixedKey });

export async function complete(cfg, system, messages, { json = false, signal } = {}) {
  return withKeys(cfg, async (c) => {
    try {
      return await completeOnce(c, system, messages, json, signal);
    } catch (e) {
      if (json && e instanceof HTTPError && e.status === 400 && /response_format|json/i.test(e.body)) {
        return await completeOnce(c, system, messages, false, signal);
      }
      throw e;
    }
  });
}

/** Streams text pieces; calls onPiece for each. Returns the full text. */
export async function stream(cfg, system, messages, onPiece, signal) {
  return withKeys(cfg, async (c) => {
    let emitted = false;
    try {
      return await streamOnce(c, system, messages, (p) => { emitted = true; onPiece(p); }, signal);
    } catch (e) {
      if (emitted) e.noRotate = true; // part of the answer is already shown — do not repeat it with another key
      throw e;
    }
  });
}

async function streamOnce(cfg, system, messages, onPiece, signal) {
  const { url, init } = buildRequest(cfg, system, messages, { stream: true });
  const res = await request(url, { ...init, signal }, cfg.title);
  if (!res.ok) throw apiError(cfg.title, res.status, await res.text(), cfg.model);
  if (!res.body || !res.body.getReader) {
    const full = await completeOnce(cfg, system, messages, false, signal);
    onPiece(full);
    return full;
  }
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = '', full = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    let nl;
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line.startsWith('data:')) continue;
      const payload = line.slice(5).trim();
      if (payload === '[DONE]') continue;
      let obj;
      try { obj = JSON.parse(payload); } catch { continue; }
      if (obj.error?.message) throw new HTTPError(obj.error.code || 0, friendlyError(cfg.title, obj.error.code || 0, payload, cfg.model), payload);
      let piece = '';
      if (cfg.kind === 'anthropic') {
        if (obj.type === 'content_block_delta') piece = obj.delta?.text || '';
      } else {
        piece = obj.choices?.[0]?.delta?.content || '';
      }
      if (piece) { full += piece; onPiece(piece); }
    }
  }
  if (!full) {
    full = await completeOnce(cfg, system, messages, false, signal);
    onPiece(full);
  }
  return full;
}

export async function listModels(cfg) {
  return withKeys(cfg, listModelsOnce);
}

async function listModelsOnce(cfg) {
  const headers = {};
  if (cfg.kind === 'anthropic') {
    headers['x-api-key'] = cfg.apiKey;
    headers['anthropic-version'] = '2023-06-01';
    headers['anthropic-dangerous-direct-browser-access'] = 'true';
  } else if (cfg.apiKey) {
    headers['Authorization'] = `Bearer ${cfg.apiKey}`;
  }
  const res = await request(`${base(cfg)}/models`, { headers }, cfg.title);
  const text = await res.text();
  if (!res.ok) throw apiError(cfg.title, res.status, text, cfg.model);
  const j = JSON.parse(text);
  const list = j.data || j.models || [];
  const skip = ['embedding', 'embed', 'tts', 'whisper', 'dall-e', 'image', 'moderation', 'audio', 'transcribe', 'realtime', 'guard'];
  const ids = list.map(m => m.id || m.name).filter(Boolean)
    .map(id => id.startsWith('models/') ? id.slice(7) : id)
    .filter(id => !skip.some(s => id.toLowerCase().includes(s)));
  return [...new Set(ids)].sort();
}

export function extractJSONObject(text) {
  try { const o = JSON.parse(text); if (o && typeof o === 'object') return o; } catch {}
  const s = text.indexOf('{'), e = text.lastIndexOf('}');
  if (s < 0 || e <= s) return null;
  try { return JSON.parse(text.slice(s, e + 1)); } catch { return null; }
}
