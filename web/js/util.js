// Small shared helpers: ids, escaping, formatting, events.

export const uuid = () =>
  (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  })).toUpperCase();

const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
export const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ESC[c]);

export const trim = (s) => String(s ?? '').trim();

const ru = 'ru-RU';
const fmtShort = new Intl.DateTimeFormat(ru, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
const fmtLong = new Intl.DateTimeFormat(ru, { day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' });
const fmtTime = new Intl.DateTimeFormat(ru, { hour: '2-digit', minute: '2-digit' });
const fmtDay = new Intl.DateTimeFormat(ru, { weekday: 'long', day: 'numeric', month: 'long' });

export const fmt = {
  short: (d) => fmtShort.format(new Date(d)),
  long: (d) => fmtLong.format(new Date(d)),
  time: (d) => fmtTime.format(new Date(d)),
  isoDay: (d) => {
    const x = new Date(d);
    return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`;
  },
  fileStamp: (d) => {
    const x = new Date(d);
    return `${fmt.isoDay(x)} ${String(x.getHours()).padStart(2, '0')}-${String(x.getMinutes()).padStart(2, '0')}`;
  },
  dayTitle: (d) => {
    const x = new Date(d);
    const today = new Date();
    const y = new Date(); y.setDate(y.getDate() - 1);
    if (x.toDateString() === today.toDateString()) return 'Сегодня';
    if (x.toDateString() === y.toDateString()) return 'Вчера';
    const s = fmtDay.format(x);
    return s.charAt(0).toUpperCase() + s.slice(1);
  },
  clock: (sec) => {
    const t = Math.max(0, Math.floor(sec || 0));
    const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
    return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` : `${m}:${String(s).padStart(2, '0')}`;
  },
  duration: (sec) => {
    const t = Math.max(0, Math.round(sec || 0));
    const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60);
    if (h > 0) return `${h} ч ${m} мин`;
    if (m > 0) return `${m} мин`;
    return `${t} сек`;
  },
  bytes: (n) => {
    if (n < 1024) return `${n} Б`;
    if (n < 1024 ** 2) return `${(n / 1024).toFixed(0)} КБ`;
    if (n < 1024 ** 3) return `${(n / 1024 ** 2).toFixed(1)} МБ`;
    return `${(n / 1024 ** 3).toFixed(2)} ГБ`;
  },
};

export class Emitter {
  constructor() { this.handlers = new Map(); }
  on(evt, fn) {
    if (!this.handlers.has(evt)) this.handlers.set(evt, new Set());
    this.handlers.get(evt).add(fn);
    return () => this.handlers.get(evt)?.delete(fn);
  }
  emit(evt, ...args) {
    for (const fn of this.handlers.get(evt) || []) {
      try { fn(...args); } catch (e) { console.error(e); }
    }
  }
}

export const sleep = (ms) => new Promise(r => setTimeout(r, ms));

export function wavFromPCM16(pcm /* Int16Array | Uint8Array of LE int16 */, sampleRate) {
  const bytes = pcm instanceof Int16Array ? new Uint8Array(pcm.buffer, pcm.byteOffset, pcm.byteLength) : pcm;
  const header = new ArrayBuffer(44);
  const v = new DataView(header);
  const w = (o, s) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  w(0, 'RIFF'); v.setUint32(4, 36 + bytes.byteLength, true); w(8, 'WAVE'); w(12, 'fmt ');
  v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true);
  v.setUint32(24, sampleRate, true); v.setUint32(28, sampleRate * 2, true);
  v.setUint16(32, 2, true); v.setUint16(34, 16, true); w(36, 'data'); v.setUint32(40, bytes.byteLength, true);
  return new Blob([header, bytes], { type: 'audio/wav' });
}

export function extForMime(mime = '') {
  if (mime.includes('mp4') || mime.includes('m4a') || mime.includes('aac')) return 'm4a';
  if (mime.includes('webm')) return 'webm';
  if (mime.includes('ogg')) return 'ogg';
  if (mime.includes('wav')) return 'wav';
  if (mime.includes('mpeg') || mime.includes('mp3')) return 'mp3';
  return 'audio';
}

export function toast(message, kind = 'info') {
  const el = document.createElement('div');
  el.className = `toast toast-${kind}`;
  el.textContent = message;
  document.body.appendChild(el);
  requestAnimationFrame(() => el.classList.add('show'));
  setTimeout(() => { el.classList.remove('show'); setTimeout(() => el.remove(), 300); }, kind === 'error' ? 6000 : 2800);
}

export async function shareOrDownload({ title, text, file }) {
  try {
    if (file && navigator.canShare && navigator.canShare({ files: [file] })) {
      await navigator.share({ title, files: [file] });
      return;
    }
    if (!file && text && navigator.share) {
      await navigator.share({ title, text });
      return;
    }
  } catch (e) {
    if (e && e.name === 'AbortError') return;
  }
  const blob = file || new Blob([text], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = file ? file.name : `${title || 'vox'}.txt`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

export const isIOS = () => /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
export const isStandalone = () => window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
