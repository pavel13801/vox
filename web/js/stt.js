// Speech-to-text: Deepgram live (WebSocket) and batch (Deepgram / Whisper-compatible).
import { uuid, wavFromPCM16, extForMime } from './util.js';
import { extractError } from './llm.js';

// ---------------------------------------------------------------- live

/**
 * Streams Int16 PCM to Deepgram. Buffers audio while (re)connecting, so short network drops lose nothing.
 * Auth uses the WebSocket sub-protocol ["token", KEY] (browsers cannot set headers).
 */
export class DeepgramLive {
  constructor({ apiKey, model, language, sampleRate, diarize, keyterms }) {
    this.o = { apiKey, model, language, sampleRate, diarize, keyterms: keyterms || [] };
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
    return `wss://api.deepgram.com/v1/listen?${p}`;
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
      ws = new WebSocket(this.url(), ['token', this.o.apiKey]);
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
      if (!opened && this.attempt >= 2 && !this.everOpened) {
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

function httpError(service, status, body) {
  const d = extractError(body);
  if (status === 401 || status === 403) return new Error(`${service}: неверный API-ключ или нет доступа (${status}). ${d}`);
  if (status === 402) return new Error(`${service}: закончился баланс. ${d}`);
  if (status === 429) return new Error(`${service}: превышен лимит запросов, попробуйте позже. ${d}`);
  if (status === 413) return new Error(`${service}: файл слишком большой. ${d}`);
  return new Error(`${service}: ошибка ${status}. ${d}`);
}

export async function transcribeBatch(blob, o) {
  if (!o.apiKey) throw new Error(`Нет API-ключа для ${o.apiTitle}. Добавьте его в Настройках.`);
  if (o.provider === 'deepgram') return deepgramBatch(blob, o);
  return whisperBatch(blob, o);
}

async function deepgramBatch(blob, o) {
  const p = new URLSearchParams({
    model: o.model, language: o.language, punctuate: 'true', smart_format: 'true', utterances: 'true', utt_split: '1.2',
  });
  if (o.diarize) p.append('diarize', 'true');
  const termKey = o.model.startsWith('nova-3') ? 'keyterm' : 'keywords';
  for (const t of o.keyterms.slice(0, 50)) p.append(termKey, t);
  const res = await fetch(`https://api.deepgram.com/v1/listen?${p}`, {
    method: 'POST',
    headers: { Authorization: `Token ${o.apiKey}`, 'Content-Type': blob.type || 'application/octet-stream' },
    body: blob,
  });
  const text = await res.text();
  if (!res.ok) throw httpError('Deepgram', res.status, text);
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

const WHISPER_LIMIT = 24 * 1024 * 1024;

async function whisperBatch(blob, o) {
  let parts;
  if (blob.size <= WHISPER_LIMIT) {
    parts = [{ blob, offset: 0, name: `audio.${extForMime(blob.type)}` }];
  } else {
    parts = await splitToWavChunks(blob, 600);
  }
  const all = [];
  for (const part of parts) all.push(...await whisperChunk(part, o));
  return mergeSameSpeaker(all, 2, 900);
}

async function whisperChunk(part, o) {
  const verbose = o.model.includes('whisper');
  const fd = new FormData();
  fd.append('model', o.model);
  if (o.language && o.language !== 'multi') fd.append('language', o.language);
  fd.append('response_format', verbose ? 'verbose_json' : 'json');
  if (o.keyterms.length) fd.append('prompt', o.keyterms.join(', '));
  fd.append('file', part.blob, part.name);
  const res = await fetch(`${o.baseURL.replace(/\/+$/, '')}/audio/transcriptions`, {
    method: 'POST', headers: { Authorization: `Bearer ${o.apiKey}` }, body: fd,
  });
  const text = await res.text();
  if (!res.ok) throw httpError(o.apiTitle, res.status, text);
  const j = JSON.parse(text);
  if (Array.isArray(j.segments) && j.segments.length) {
    return j.segments.map(s => ({
      id: uuid(), speaker: 0, text: (s.text || '').trim(), start: part.offset + (s.start || 0), end: part.offset + (s.end || 0),
    })).filter(s => s.text);
  }
  const t = (j.text || '').trim();
  return t ? [{ id: uuid(), speaker: 0, text: t, start: part.offset, end: part.offset }] : [];
}

/** Decodes audio and re-encodes 16 kHz mono WAV chunks (for size-limited APIs). */
async function splitToWavChunks(blob, chunkSeconds) {
  const ctx = new (window.AudioContext || window.webkitAudioContext)();
  let decoded;
  try {
    decoded = await ctx.decodeAudioData(await blob.arrayBuffer());
  } finally {
    ctx.close?.();
  }
  const pcm = await resampleTo16k(decoded);
  const per = chunkSeconds * 16000;
  const parts = [];
  for (let i = 0, k = 0; i < pcm.length; i += per, k++) {
    parts.push({ blob: wavFromPCM16(pcm.subarray(i, Math.min(pcm.length, i + per)), 16000), offset: i / 16000, name: `chunk_${k}.wav` });
  }
  return parts;
}

export async function resampleTo16k(audioBuffer) {
  const frames = Math.ceil(audioBuffer.duration * 16000);
  const off = new OfflineAudioContext(1, Math.max(1, frames), 16000);
  const src = off.createBufferSource();
  src.buffer = audioBuffer;
  src.connect(off.destination);
  src.start();
  const rendered = await off.startRendering();
  const f = rendered.getChannelData(0);
  const out = new Int16Array(f.length);
  for (let i = 0; i < f.length; i++) {
    const v = Math.max(-1, Math.min(1, f[i]));
    out[i] = v < 0 ? v * 0x8000 : v * 0x7fff;
  }
  return out;
}

/** Cheap key check: transcribe 0.5 s of silence. */
export async function verifyDeepgram(key) {
  const silent = wavFromPCM16(new Int16Array(8000), 16000);
  const res = await fetch('https://api.deepgram.com/v1/listen?model=nova-3&language=ru', {
    method: 'POST', headers: { Authorization: `Token ${key}`, 'Content-Type': 'audio/wav' }, body: silent,
  });
  if (!res.ok) throw httpError('Deepgram', res.status, await res.text());
}
