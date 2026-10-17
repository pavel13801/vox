// Omi wearable over Web Bluetooth (Chrome on Android/desktop, Bluefy on iOS). Protocol from BasedHardware/omi.
import { Emitter } from './util.js';

const OMI_SERVICE = '19b10000-e8f2-537e-4f6c-d104768a1214';
const AUDIO_DATA = '19b10001-e8f2-537e-4f6c-d104768a1214';
const AUDIO_CODEC = '19b10002-e8f2-537e-4f6c-d104768a1214';
const TIME_SERVICE = '19b10030-e8f2-537e-4f6c-d104768a1214';
const TIME_WRITE = '19b10031-e8f2-537e-4f6c-d104768a1214';
const OPUS_URL = 'https://cdn.jsdelivr.net/npm/opus-decoder@0.7.12/dist/opus-decoder.min.js';

const CODECS = { 0: ['pcm16', 16000, 'PCM 16 кГц'], 1: ['pcm8', 8000, 'PCM 8 кГц'], 20: ['opus', 16000, 'Opus'], 21: ['opus', 16000, 'Opus (320)'] };

let opusLib = null;
function loadOpus() {
  if (opusLib) return opusLib;
  opusLib = new Promise((resolve, reject) => {
    if (window['opus-decoder']) return resolve(window['opus-decoder']);
    const s = document.createElement('script');
    s.src = OPUS_URL;
    s.charset = 'UTF-8';
    s.onload = () => resolve(window['opus-decoder']);
    s.onerror = () => { opusLib = null; reject(new Error('Не удалось загрузить декодер Opus')); };
    document.head.appendChild(s);
  });
  return opusLib;
}

/** Reassembles frames: [idx lo][idx hi][sub][payload…]; a frame may span several packets. */
class FrameAssembler {
  constructor() { this.last = -1; this.sub = -1; this.pending = []; this.lost = 0; }
  push(p) {
    if (p.length <= 3) return [];
    const idx = p[0] | (p[1] << 8), sub = p[2], content = p.subarray(3);
    const out = [];
    if (this.last === -1) {
      if (sub === 0) { this.last = idx; this.sub = 0; this.pending = [content.slice()]; }
      return out;
    }
    const expected = (this.last + 1) & 0xffff;
    if (idx !== expected || (sub !== 0 && sub !== this.sub + 1)) {
      this.lost++;
      if (sub === 0) { this.last = idx; this.sub = 0; this.pending = [content.slice()]; }
      else { this.last = -1; this.pending = []; }
      return out;
    }
    if (sub === 0) {
      if (this.pending.length) out.push(concat(this.pending));
      this.pending = [content.slice()];
    } else {
      this.pending.push(content.slice());
    }
    this.sub = sub;
    this.last = idx;
    return out;
  }
}

function concat(parts) {
  const n = parts.reduce((a, b) => a + b.length, 0);
  const out = new Uint8Array(n);
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
}

class Omi extends Emitter {
  constructor() {
    super();
    this.supported = typeof navigator !== 'undefined' && !!navigator.bluetooth;
    this.device = null;
    this.state = 'idle'; // idle | connecting | connected | reconnecting
    this.ready = false;
    this.battery = null;
    this.codecName = '';
    this.firmware = '';
    this.sampleRate = 16000;
    this.lostFrames = 0;
    this.onPCM = null;
    this.wants = false;
    this.assembler = null;
    this.decoder = null;
    this.codec = null;
  }

  get name() { return this.device?.name || localStorage.getItem('vox.omi.name') || 'Omi'; }
  get hasSaved() { return !!this.device || !!localStorage.getItem('vox.omi.name'); }

  setState(s) { this.state = s; this.emit('change'); }

  async pair() {
    if (!this.supported) throw new Error('Этот браузер не поддерживает Bluetooth. На iPhone откройте Vox в браузере Bluefy, на Android — в Chrome.');
    const device = await navigator.bluetooth.requestDevice({
      filters: [{ services: [OMI_SERVICE] }, { namePrefix: 'Omi' }, { namePrefix: 'Friend' }],
      optionalServices: [OMI_SERVICE, TIME_SERVICE, 'battery_service', 'device_information'],
    });
    this.device = device;
    localStorage.setItem('vox.omi.name', device.name || 'Omi');
    device.addEventListener('gattserverdisconnected', () => this.onDisconnected());
    this.wants = true;
    await this.connect();
  }

  async reconnect() {
    if (this.device && !this.device.gatt.connected) {
      this.wants = true;
      try { await this.connect(); } catch {}
    } else if (!this.device && navigator.bluetooth?.getDevices) {
      // Chrome can return previously permitted devices without a prompt.
      try {
        const list = await navigator.bluetooth.getDevices();
        const d = list.find(x => x.name === localStorage.getItem('vox.omi.name'));
        if (d) {
          this.device = d;
          d.addEventListener('gattserverdisconnected', () => this.onDisconnected());
          this.wants = true;
          await this.connect();
        }
      } catch {}
    }
  }

  async connect() {
    this.setState(this.state === 'reconnecting' ? 'reconnecting' : 'connecting');
    const server = await this.device.gatt.connect();
    const svc = await server.getPrimaryService(OMI_SERVICE);
    const codecChar = await svc.getCharacteristic(AUDIO_CODEC);
    const codecId = (await codecChar.readValue()).getUint8(0);
    const [kind, rate, title] = CODECS[codecId] || CODECS[1];
    this.codec = kind;
    this.codecName = title;
    this.sampleRate = rate;
    this.assembler = new FrameAssembler();
    if (kind === 'opus') {
      const lib = await loadOpus();
      this.decoder = new lib.OpusDecoder({ sampleRate: 16000, channels: 1 });
      await this.decoder.ready;
    }
    const audio = await svc.getCharacteristic(AUDIO_DATA);
    audio.addEventListener('characteristicvaluechanged', (e) => this.onAudio(e.target.value));
    await audio.startNotifications();

    try {
      const bat = await (await server.getPrimaryService('battery_service')).getCharacteristic('battery_level');
      this.battery = (await bat.readValue()).getUint8(0);
      bat.addEventListener('characteristicvaluechanged', (e) => { this.battery = e.target.value.getUint8(0); this.emit('change'); });
      await bat.startNotifications().catch(() => {});
    } catch {}
    try {
      const fw = await (await server.getPrimaryService('device_information')).getCharacteristic('firmware_revision_string');
      this.firmware = new TextDecoder().decode(await fw.readValue()).replace(/\0/g, '');
    } catch {}
    try {
      const t = await (await server.getPrimaryService(TIME_SERVICE)).getCharacteristic(TIME_WRITE);
      const b = new DataView(new ArrayBuffer(4));
      b.setUint32(0, Math.floor(Date.now() / 1000), true);
      await t.writeValue(b.buffer);
    } catch {}

    this.ready = true;
    this.setState('connected');
    this.emit('ready', true);
  }

  onAudio(dv) {
    const packet = new Uint8Array(dv.buffer, dv.byteOffset, dv.byteLength);
    const frames = this.assembler.push(packet);
    this.lostFrames = this.assembler.lost;
    for (const f of frames) {
      let pcm;
      if (this.codec === 'opus') {
        try {
          const r = this.decoder.decodeFrame(f);
          const ch = r.channelData[0];
          pcm = new Int16Array(ch.length);
          for (let i = 0; i < ch.length; i++) {
            const v = Math.max(-1, Math.min(1, ch[i]));
            pcm[i] = v < 0 ? v * 0x8000 : v * 0x7fff;
          }
        } catch { continue; }
      } else {
        pcm = new Int16Array(f.buffer.slice(f.byteOffset, f.byteOffset + (f.byteLength & ~1)));
      }
      if (pcm.length && this.onPCM) this.onPCM(pcm);
    }
  }

  onDisconnected() {
    const was = this.ready;
    this.ready = false;
    this.battery = null;
    try { this.decoder?.free?.(); } catch {}
    this.decoder = null;
    if (was) this.emit('ready', false);
    if (this.wants) {
      this.setState('reconnecting');
      const retry = async (n) => {
        if (!this.wants || this.device?.gatt.connected) return;
        try { await this.connect(); } catch { setTimeout(() => retry(n + 1), Math.min(30000, 2000 * (n + 1))); }
      };
      retry(0);
    } else {
      this.setState('idle');
    }
  }

  disconnect(forget) {
    this.wants = false;
    try { this.device?.gatt.disconnect(); } catch {}
    if (forget) { this.device = null; localStorage.removeItem('vox.omi.name'); }
    this.ready = false;
    this.setState('idle');
  }
}

export const omi = new Omi();
