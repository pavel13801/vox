// Speech-to-text: Deepgram live (WebSocket) and batch (Deepgram / Whisper-compatible / audio-capable chat models).
import { uuid, wavFromPCM16, extForMime } from './util.js';
import { apiError, request, extractJSONObject } from './llm.js';
import { settings } from './settings.js';

// ---------------------------------------------------------------- live

/**
 * Streams Int16 PCM to Deepgram. Buffers audio while (re)connecting, so short network drops lose nothing.
 * Auth uses the WebSocket sub-protocol ["token", KEY] (browsers cannot set headers).
 */
export class DeepgramLive {
  constructor({ apiKey, apiKeys, model, language, sampleRate, diarize, keyterms, endpoint, onKeyFailed }) {
    this.o = { apiKey, model, language, sampleRate, diarize, keyterms: keyterms || [], endpoint: endpoint || 'wss://api.deepgram.com/v1/listen' };
    // Several keys: when a connection is refused with one key, the next key is tried.
    this.keys = (apiKeys && apiKeys.length ? apiKeys : [apiKey]).filter(Boolean);
    this.keyIndex = 0;
    this.refusedInRow = 0;
    this.onKeyFailed = onKeyFailed || (() => {});
    this.onStatus = () => {};
    this.onResult = () => {};
    this.ws = null;
    this.open = false;
    this.running = false;
    this.finishing = false;
    this.attempt = 0;
    this.gaps = false;
    this.everOpened = false;
    this.failed = false;
    this.pending = []; // {data: ArrayBuffer, t0}
    this.pendingBytes = 0;
    this.maxPending = sampleRate * 2 * 120;
    this.timeline = 0;
    this.base = 0;
    this.baseSet = false;
    this.lastSend = Date.now();
    this.keepAlive = null;
    this.finishResolve = null;
  }

  url() {
    const p = new URLSearchParams({
      model: this.o.model, language: this.o.language, encoding: 'linear16',
      sample_rate: String(this.o.sampleRate), channels: '1', punctuate: 'true', smart_format: 'true',
      interim_results: 'true', endpointing: '300', utterance_end_ms: '1000',
    });
    if (this.o.diarize) p.append('diarize', 'true');
    const termKey = this.o.model.startsWith('nova-3') ? 'keyterm' : 'keywords';
    for (const t of this.o.keyterms.slice(0, 50)) p.append(termKey, t);
    return `${this.o.endpoint}?${p}`;
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.connect();
    this.keepAlive = setInterval(() => {
      if (this.open && Date.now() - this.lastSend > 3500) {
        try { this.ws.send(JSON.stringify({ type: 'KeepAlive' })); } catch {}
        this.lastSend = Date.now();
      }
    }, 4000);
  }

  connect() {
    if (!this.running) return;
    this.open = false;
    this.baseSet = false;
    this.onStatus(this.attempt === 0 ? 'connecting' : 'reconnecting');
    let ws;
    try {
      ws = new WebSocket(this.url(), ['token', this.keys[this.keyIndex] || this.o.apiKey]);
    } catch (e) {
      this.failed = true;
      this.onStatus('failed', 'Не удалось подключиться к Deepgram');
      return;
    }
    ws.binaryType = 'arraybuffer';
    this.ws = ws;
    let opened = false;
    ws.onopen = () => {
      if (ws !== this.ws) return;
      opened = true;
      this.refusedInRow = 0;
      this.open = true;
      this.everOpened = true;
      this.attempt = 0;
      this.onStatus('open');
      this.flush();
    };
    ws.onmessage = (ev) => { if (ws === this.ws) this.handle(ev.data); };
    ws.onerror = () => {};
    ws.onclose = (ev) => {
      if (ws !== this.ws) return;
      this.ws = null;
      const wasOpen = this.open;
      this.open = false;
      if (this.finishing) { this.complete(); return; }
      if (!this.running) return;
      // Browsers hide the HTTP status; 1008/4xxx or an immediate close usually means a bad key/params.
      if (!opened) {
        this.refusedInRow++;
        // Two refusals in a row with this key (likely out of balance or invalid) → switch to the next key.
        if (this.keys.length > 1 && !this.everOpened && this.refusedInRow % 2 === 0) {
          this.onKeyFailed(this.keys[this.keyIndex]);
          this.keyIndex = (this.keyIndex + 1) % this.keys.length;
        }
      }
      if (!opened && !this.everOpened && this.refusedInRow >= 2 * Math.max(1, this.keys.length) + 1) {
        this.running = false;
        this.failed = true;
        this.onStatus('failed', 'Deepgram не принимает подключение — проверьте ключ, модель и язык');
        return;
      }
      if (ev.code === 1008 || (ev.reason && /auth|credential|unauthor/i.test(ev.reason))) {
        this.running = false;
        this.failed = true;
        this.onStatus('failed', 'Deepgram: неверный API-ключ');
        return;
      }
      if (wasOpen) this.gaps = true;
      this.attempt++;
      const delay = Math.min(15000, 1000 * 2 ** Math.min(this.attempt - 1, 4));
      this.onStatus('reconnecting');
      setTimeout(() => { if (this.running && !this.ws) this.connect(); }, delay);
    };
  }

  send(int16 /* Int16Array */) {
    if (!int16 || !int16.length) return;
    const t0 = this.timeline;
    this.timeline += int16.length / this.o.sampleRate;
    if (!this.running && !this.finishing) return;
    const buf = int16.buffer.slice(int16.byteOffset, int16.byteOffset + int16.byteLength);
    if (this.open && this.ws) {
      if (!this.baseSet) { this.base = t0; this.baseSet = true; }
      this.transmit(buf);
    } else {
      this.pending.push({ data: buf, t0 });
      this.pendingBytes += buf.byteLength;
      while (this.pendingBytes > this.maxPending && this.pending.length) {
        this.pendingBytes -= this.pending.shift().data.byteLength;
        this.gaps = true;
      }
    }
  }

  transmit(buf) {
    try { this.ws.send(buf); this.lastSend = Date.now(); } catch { this.gaps = true; }
  }

  flush() {
    if (!this.pending.length) return;
    if (!this.baseSet) { this.base = this.pending[0].t0; this.baseSet = true; }
    for (const p of this.pending) this.transmit(p.data);
    this.pending = [];
    this.pendingBytes = 0;
  }

  handle(data) {
    let msg;
    try { msg = JSON.parse(typeof data === 'string' ? data : new TextDecoder().decode(data)); } catch { return; }
    if (msg.type && msg.type !== 'Results') return;
    const alt = msg.channel?.alternatives?.[0];
    if (!alt) return;
    const b = this.base;
    const words = (alt.words || []).map(w => ({
      text: (w.punctuated_word || w.word || '').trim(),
      start: b + (w.start || 0),
      end: b + (w.end ?? w.start ?? 0),
      speaker: w.speaker ?? 0,
    })).filter(w => w.text);
    const start = b + (msg.start || 0);
    this.onResult({
      isFinal: !!msg.is_final,
      transcript: (alt.transcript || '').trim(),
      words, start, end: start + (msg.duration || 0),
    });
  }

  /** Resolves with {gaps} after Deepgram sent the final results. */
  finish() {
    return new Promise((resolve) => {
      this.running = false;
      this.finishing = true;
      this.finishResolve = resolve;
      if (this.open && this.ws) {
        this.flush();
        try { this.ws.send(JSON.stringify({ type: 'CloseStream' })); } catch {}
        setTimeout(() => this.complete(), 6000);
      } else {
        if (this.pending.length) this.gaps = true;
        this.complete();
      }
    });
  }

  complete() {
    if (!this.finishResolve) return;
    const r = this.finishResolve;
    this.finishResolve = null;
    this.finishing = false;
    clearInterval(this.keepAlive);
    try { this.ws?.close(); } catch {}
    this.ws = null;
    this.onStatus('closed');
    r({ gaps: this.gaps });
  }

  cancel() {
    this.running = false;
    this.finishing = false;
    clearInterval(this.keepAlive);
    try { this.ws?.close(); } catch {}
    this.ws = null;
  }
}

/** Accumulates live results into speaker-grouped segments. */
export class LiveTranscript {
  constructor() { this.segments = []; this.interim = ''; }

  apply(r) {
    if (!r.isFinal) { this.interim = r.transcript; return; }
    this.interim = '';
    if (!r.words.length) {
      if (r.transcript) this.append(this.segments.at(-1)?.speaker ?? 0, r.transcript, r.start, r.end);
      return;
    }
    let sp = r.words[0].speaker, words = [], st = r.words[0].start, en = r.words[0].end;
    for (const w of r.words) {
      if (w.speaker !== sp) {
        this.append(sp, words.join(' '), st, en);
        sp = w.speaker; words = []; st = w.start;
      }
      words.push(w.text); en = w.end;
    }
    this.append(sp, words.join(' '), st, en);
  }

  append(speaker, text, start, end) {
    const t = text.trim();
    if (!t) return;
    const last = this.segments.at(-1);
    if (last && last.speaker === speaker && start - last.end < 20 && last.text.length < 1500) {
      last.text += ' ' + t;
      last.end = Math.max(last.end, end);
    } else {
      this.segments.push({ id: uuid(), speaker, text: t, start, end });
    }
  }
}

// ---------------------------------------------------------------- batch

export function mergeSameSpeaker(segs, maxGap = 3, maxChars = 1200) {
  const out = [];
  for (const s of segs) {
    const last = out.at(-1);
    if (last && last.speaker === s.speaker && s.start - last.end <= maxGap && last.text.length + s.text.length <= maxChars) {
      last.text += ' ' + s.text;
      last.end = Math.max(last.end, s.end);
    } else {
      out.push({ ...s });
    }
  }
  return out;
}

const httpError = apiError;

/** One request with the provider's keys: on quota/money/invalid-key errors the next key is tried. */
const withKeys = (o, fn) => settings.withKeys(o.provider, (key) => fn({ ...o, apiKey: key }), { fixedKey: o.fixedKey });
const trimBase = (u) => String(u || '').replace(/\/+$/, '');

/**
 * o: { engine: 'deepgram'|'whisper'|'chat', apiKey, baseURL, model, language, diarize, keyterms, apiTitle, custom, onProgress? }
 */
export async function transcribeBatch(blob, o) {
  if (!o.engine) throw new Error(`${o.apiTitle} не умеет расшифровывать аудио. Выберите другой сервис в Настройки → Расшифровка файла.`);
  if (!o.apiKey && !o.custom && !settings.apiKeys(o.provider).length) throw new Error(`Нет API-ключа для ${o.apiTitle}. Добавьте его в Настройки → Ключи и провайдеры.`);
  if (!o.model) throw new Error(`Не выбрана модель расшифровки для ${o.apiTitle}.`);
  if (o.engine === 'deepgram') return deepgramBatch(blob, o);
  if (o.engine === 'chat') return chatAudioBatch(blob, o);
  return whisperBatch(blob, o);
}

const deepgramBatch = (blob, o) => withKeys(o, (k) => deepgramOnce(blob, k));

async function deepgramOnce(blob, o) {
  const p = new URLSearchParams({
    model: o.model, language: o.language, punctuate: 'true', smart_format: 'true', utterances: 'true', utt_split: '1.2',
  });
  if (o.diarize) p.append('diarize', 'true');
  const termKey = o.model.startsWith('nova-3') ? 'keyterm' : 'keywords';
  for (const t of o.keyterms.slice(0, 50)) p.append(termKey, t);
  const res = await request(`${trimBase(o.baseURL)}/listen?${p}`, {
    method: 'POST',
    headers: { Authorization: `Token ${o.apiKey}`, 'Content-Type': blob.type || 'application/octet-stream' },
    body: blob,
  }, 'Deepgram');
  const text = await res.text();
  if (!res.ok) throw httpError('Deepgram', res.status, text, o.model);
  const j = JSON.parse(text);
  const utts = j.results?.utterances || [];
  if (utts.length) {
    return mergeSameSpeaker(utts.map(u => ({
      id: uuid(), speaker: u.speaker ?? 0, text: (u.transcript || '').trim(), start: u.start || 0, end: u.end ?? u.start ?? 0,
    })).filter(s => s.text));
  }
  const words = j.results?.channels?.[0]?.alternatives?.[0]?.words || [];
  const segs = [];
  for (const w of words) {
    const t = (w.punctuated_word || w.word || '').trim();
    if (!t) continue;
    const sp = w.speaker ?? 0;
    const last = segs.at(-1);
    if (last && last.speaker === sp) { last.text += ' ' + t; last.end = w.end ?? last.end; }
    else segs.push({ id: uuid(), speaker: sp, text: t, start: w.start || 0, end: w.end || 0 });
  }
  if (!segs.length) {
    const t = (j.results?.channels?.[0]?.alternatives?.[0]?.transcript || '').trim();
    if (t) segs.push({ id: uuid(), speaker: 0, text: t, start: 0, end: 0 });
  }
  return segs;
}

// ---- Whisper-compatible (/audio/transcriptions): OpenAI, Groq, Fireworks, local servers…

const WHISPER_LIMIT = 24 * 1024 * 1024;

async function whisperBatch(blob, o) {
  const parts = blob.size <= WHISPER_LIMIT
    ? [{ blob, offset: 0, name: `audio.${extForMime(blob.type)}` }]
    : await splitToWavChunks(blob, 600);
  const all = [];
  for (let i = 0; i < parts.length; i++) {
    o.onProgress?.(i, parts.length);
    all.push(...await withKeys(o, (k) => whisperChunk(parts[i], k)));
  }
  return mergeSameSpeaker(all, 2, 900);
}

async function whisperChunk(part, o) {
  const verbose = /whisper/i.test(o.model);
  const fd = new FormData();
  fd.append('model', o.model);
  if (o.language && o.language !== 'multi') fd.append('language', o.language);
  fd.append('response_format', verbose ? 'verbose_json' : 'json');
  if (o.keyterms.length) fd.append('prompt', o.keyterms.join(', '));
  fd.append('file', part.blob, part.name);
  const headers = o.apiKey ? { Authorization: `Bearer ${o.apiKey}` } : {};
  const res = await request(`${trimBase(o.baseURL)}/audio/transcriptions`, { method: 'POST', headers, body: fd }, o.apiTitle);
  const text = await res.text();
  if (!res.ok) throw httpError(o.apiTitle, res.status, text, o.model);
  const j = JSON.parse(text);
  if (Array.isArray(j.segments) && j.segments.length) {
    return j.segments.map(s => ({
      id: uuid(), speaker: 0, text: (s.text || '').trim(), start: part.offset + (s.start || 0), end: part.offset + (s.end || 0),
    })).filter(s => s.text);
  }
  const t = (j.text || '').trim();
  return t ? [{ id: uuid(), speaker: 0, text: t, start: part.offset, end: part.offset }] : [];
}

// ---- Any chat model that accepts audio (Gemini, OpenRouter audio models, GPT-4o audio…)

const LANG_NAMES = {
  ru: 'русском', en: 'английском', uk: 'украинском', de: 'немецком', es: 'испанском', fr: 'французском',
  it: 'итальянском', pt: 'португальском', tr: 'турецком', kk: 'казахском',
};

function transcriptionPrompt(o) {
  const lang = o.language === 'multi' || !LANG_NAMES[o.language]
    ? 'на языке оригинала (если языки смешаны — каждую фразу на её языке)'
    : `на ${LANG_NAMES[o.language]} языке (иностранные слова оставляй как произнесены)`;
  const speakers = o.diarize
    ? 'Раздели речь по говорящим: Спикер 1, Спикер 2 и т. д. Если голос один — все реплики от Спикера 1.'
    : 'Все реплики относи к Спикеру 1.';
  const terms = o.keyterms.length ? `\nВозможные имена и термины: ${o.keyterms.join(', ')}.` : '';
  return [
    `Сделай дословную расшифровку этой аудиозаписи ${lang}.`,
    speakers,
    'Верни ТОЛЬКО JSON без пояснений:',
    '{"segments":[{"speaker":1,"start":"MM:SS","text":"реплика"}]}',
    '— каждая реплика или законченная мысль отдельным элементом; start — время начала от начала этого фрагмента.',
    'Пиши всё, что сказано, без сокращений и пересказа, с пунктуацией. Не добавляй ничего от себя. Если речи нет — {"segments":[]}.' + terms,
  ].join('\n');
}

function parseTime(v) {
  if (typeof v === 'number') return v;
  const parts = String(v || '0').trim().split(':').map(Number);
  if (parts.some(Number.isNaN)) return 0;
  return parts.reduce((acc, n) => acc * 60 + n, 0);
}

async function chatAudioBatch(blob, o) {
  // 5-minute 16 kHz WAV pieces: ~9.6 MB each (~13 MB base64) — inside the inline limits of Gemini/OpenRouter.
  const parts = await splitToWavChunks(blob, 300);
  const all = [];
  for (let i = 0; i < parts.length; i++) {
    o.onProgress?.(i, parts.length);
    all.push(...await withKeys(o, (k) => chatAudioChunk(parts[i], k)));
  }
  return mergeSameSpeaker(all, 3, 1200);
}

async function blobToBase64(blob) {
  const buf = new Uint8Array(await blob.arrayBuffer());
  let bin = '';
  const step = 0x8000;
  for (let i = 0; i < buf.length; i += step) bin += String.fromCharCode.apply(null, buf.subarray(i, i + step));
  return btoa(bin);
}

async function chatAudioChunk(part, o) {
  const data = await blobToBase64(part.blob);
  const headers = { 'Content-Type': 'application/json' };
  if (o.apiKey) headers.Authorization = `Bearer ${o.apiKey}`;
  const body = {
    model: o.model,
    messages: [{
      role: 'user', content: [
        { type: 'text', text: transcriptionPrompt(o) },
        { type: 'input_audio', input_audio: { data, format: 'wav' } },
      ],
    }],
    response_format: { type: 'json_object' },
  };
  const url = `${trimBase(o.baseURL)}/chat/completions`;
  let res = await request(url, { method: 'POST', headers, body: JSON.stringify(body) }, o.apiTitle);
  let text = await res.text();
  if (res.status === 400 && /response_format|json_object/i.test(text)) {
    delete body.response_format;
    res = await request(url, { method: 'POST', headers, body: JSON.stringify(body) }, o.apiTitle);
    text = await res.text();
  }
  if (!res.ok) {
    if (res.status === 400 && /input_audio|audio input|modalit|does not support audio/i.test(text) && !/location|api key/i.test(text)) {
      throw new Error(`${o.apiTitle}: модель «${o.model}» не принимает аудио. Выберите модель с поддержкой звука (например, Gemini).`);
    }
    throw httpError(o.apiTitle, res.status, text, o.model);
  }
  const j = JSON.parse(text);
  const content = j.choices?.[0]?.message?.content;
  const reply = Array.isArray(content) ? content.map(c => c.text || '').join('') : String(content || '');
  const obj = extractJSONObject(reply);
  const list = Array.isArray(obj?.segments) ? obj.segments : null;
  if (!list) {
    const plain = reply.trim();
    return plain ? [{ id: uuid(), speaker: 0, text: plain, start: part.offset, end: part.offset + part.duration }] : [];
  }
  const segs = list.map(x => ({
    id: uuid(),
    speaker: Math.max(0, (parseInt(x.speaker, 10) || 1) - 1),
    text: String(x.text || '').trim(),
    start: part.offset + Math.min(parseTime(x.start), part.duration),
    end: 0,
  })).filter(x => x.text);
  for (let i = 0; i < segs.length; i++) segs[i].end = i + 1 < segs.length ? segs[i + 1].start : part.offset + part.duration;
  return segs;
}

// ---- audio helpers

/** Decodes audio straight to 16 kHz mono (≈6× less memory than 48 kHz stereo) and cuts WAV pieces. */
export async function splitToWavChunks(blob, chunkSeconds) {
  const OAC = window.OfflineAudioContext || window.webkitOfflineAudioContext;
  const ctx = new OAC(1, 16000, 16000);
  let decoded;
  try {
    decoded = await ctx.decodeAudioData(await blob.arrayBuffer());
  } catch (e) {
    throw new Error(`Не удалось прочитать аудиофайл (${blob.type || 'неизвестный формат'}). Попробуйте Deepgram — он принимает любые форматы.`);
  }
  const rate = decoded.sampleRate;
  const chans = [];
  for (let c = 0; c < decoded.numberOfChannels; c++) chans.push(decoded.getChannelData(c));
  const per = Math.floor(chunkSeconds * rate);
  const parts = [];
  for (let i = 0, k = 0; i < decoded.length; i += per, k++) {
    const n = Math.min(per, decoded.length - i);
    const out = new Int16Array(n);
    for (let j = 0; j < n; j++) {
      let v = 0;
      for (const ch of chans) v += ch[i + j];
      v = Math.max(-1, Math.min(1, v / chans.length));
      out[j] = v < 0 ? v * 0x8000 : v * 0x7fff;
    }
    parts.push({ blob: wavFromPCM16(out, rate), offset: i / rate, duration: n / rate, name: `chunk_${k}.wav` });
  }
  return parts;
}

/** Cheap key check: transcribe 0.5 s of silence. */
export async function verifyDeepgram(key, baseURL = 'https://api.deepgram.com/v1') {
  const silent = wavFromPCM16(new Int16Array(8000), 16000);
  const res = await request(`${trimBase(baseURL)}/listen?model=nova-3&language=ru`, {
    method: 'POST', headers: { Authorization: `Token ${key}`, 'Content-Type': 'audio/wav' }, body: silent,
  }, 'Deepgram');
  if (!res.ok) throw httpError('Deepgram', res.status, await res.text(), 'nova-3');
}

/** Checks a transcription setup end-to-end on 1 s of near-silence. */
export async function verifyTranscription(o) {
  const pcm = new Int16Array(16000);
  for (let i = 0; i < pcm.length; i++) pcm[i] = Math.round(Math.sin(i / 8) * 200);
  return transcribeBatch(wavFromPCM16(pcm, 16000), o);
}
