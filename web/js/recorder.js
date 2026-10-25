// Recording controller: microphone / Omi → (MediaRecorder file | raw PCM) + Deepgram live, with auto-split on silence.
import { Emitter } from './util.js';
import { store, newConversation } from './store.js';
import { settings } from './settings.js';
import { DeepgramLive, LiveTranscript } from './stt.js';
import { processing, buildBlobFromChunks } from './processing.js';
import { omi } from './omi.js';

const LIVE_LABEL = {
  off: 'Расшифровка после записи',
  connecting: 'Подключение к Deepgram…',
  live: 'Live-расшифровка',
  reconnecting: 'Нет связи — пишу в буфер',
};

function pickMime() {
  if (typeof MediaRecorder === 'undefined') return null;
  const opts = ['audio/mp4;codecs=mp4a.40.2', 'audio/mp4', 'audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus'];
  for (const m of opts) { try { if (MediaRecorder.isTypeSupported(m)) return m; } catch {} }
  return '';
}

class Recorder extends Emitter {
  constructor() {
    super();
    this.isRecording = false;
    this.source = 'phone';
    this.session = null;
    this.finishing = new Map();
    this.level = 0;
    this.liveStatus = 'off';
    this.liveError = '';
    this.lastError = '';
    this.waitingForDevice = false;
    this.interrupted = false;
    this.sessionCount = 0;
    this.stream = null;
    this.ctx = null;
    this.node = null;
    this.timer = null;
    this.wakeLock = null;
    this.deviceLostAt = null;

    document.addEventListener('visibilitychange', () => this.onVisibility());
    omi.on('ready', (ready) => this.deviceReadyChanged(ready));
  }

  get conversationId() { return this.session?.id || null; }
  get elapsed() { return this.session ? this.session.samples / this.session.sampleRate : 0; }
  get segments() { return this.session?.transcript.segments || []; }
  get interim() { return this.session?.transcript.interim || ''; }
  get liveLabel() { return this.liveStatus === 'failed' ? this.liveError : (LIVE_LABEL[this.liveStatus] || ''); }

  changed() { this.emit('change'); }

  // ------------------------------------------------------------ controls

  async start(source) {
    if (this.isRecording) return;
    this.lastError = '';
    if (settings.values.transcriptionMode === 'live' && !settings.hasKey('deepgram')) {
      const bp = settings.values.batchProvider;
      this.lastError = bp !== 'deepgram' && settings.hasKey(bp) && settings.sttEngine(bp)
        ? `Live-текст работает только с Deepgram. Запись расшифруется после остановки через ${settings.title(bp)}.`
        : 'Ключ Deepgram не задан — запись сохранится, расшифруйте её позже (Настройки → Расшифровка файла).';
    }
    this.source = source;
    if (source === 'phone') {
      try {
        await this.openMic();
      } catch (e) {
        this.lastError = e.name === 'NotAllowedError'
          ? 'Нет доступа к микрофону. Разрешите его для этого сайта (Настройки iOS → Safari → Микрофон).'
          : `Не удалось включить микрофон: ${e.message}`;
        this.closeMic();
        this.changed();
        return;
      }
    }
    this.isRecording = true;
    this.sessionCount = 0;
    if (source === 'omi') {
      omi.onPCM = (pcm) => this.ingest(pcm);
      if (omi.ready) this.beginSession(); else { this.waitingForDevice = true; omi.reconnect(); }
    } else {
      this.beginSession();
    }
    this.timer = setInterval(() => this.tick(), 1000);
    this.acquireWakeLock();
    this.changed();
  }

  async stop() {
    if (!this.isRecording) return;
    clearInterval(this.timer);
    this.timer = null;
    const s = this.session;
    this.session = null;
    this.isRecording = false;
    this.waitingForDevice = false;
    this.interrupted = false;
    this.level = 0;
    this.liveStatus = 'off';
    if (this.source === 'omi') omi.onPCM = null;
    this.releaseWakeLock();
    this.changed();
    if (s) await this.finalize(s);
    this.closeMic();
  }

  splitNow() {
    if (!this.isRecording || !this.session) return;
    this.rotate();
  }

  // ------------------------------------------------------------ microphone

  async openMic() {
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
    });
    const AC = window.AudioContext || window.webkitAudioContext;
    this.ctx = new AC();
    const src = this.ctx.createMediaStreamSource(this.stream);
    const sink = this.ctx.createGain();
    sink.gain.value = 0;
    sink.connect(this.ctx.destination);
    if (this.ctx.audioWorklet) {
      await this.ctx.audioWorklet.addModule('worklet.js');
      this.node = new AudioWorkletNode(this.ctx, 'pcm-capture', { processorOptions: { targetRate: 16000 } });
      this.node.port.onmessage = (e) => this.ingest(new Int16Array(e.data));
    } else {
      // Old browsers: ScriptProcessor fallback with the same decimation.
      const ratio = this.ctx.sampleRate / 16000;
      let phase = 0, acc = 0, cnt = 0;
      this.node = this.ctx.createScriptProcessor(4096, 1, 1);
      this.node.onaudioprocess = (ev) => {
        const ch = ev.inputBuffer.getChannelData(0);
        const out = new Int16Array(Math.ceil(ch.length / ratio) + 2);
        let n = 0;
        for (let i = 0; i < ch.length; i++) {
          acc += ch[i]; cnt++; phase += 1;
          if (phase >= ratio) {
            phase -= ratio;
            const v = Math.max(-1, Math.min(1, acc / cnt));
            acc = 0; cnt = 0;
            out[n++] = v < 0 ? v * 0x8000 : v * 0x7fff;
          }
        }
        this.ingest(out.subarray(0, n));
      };
    }
    src.connect(this.node);
    this.node.connect(sink);
    if (this.ctx.state === 'suspended') await this.ctx.resume();
    for (const t of this.stream.getAudioTracks()) {
      t.onmute = () => { this.interrupted = true; this.changed(); };
      t.onunmute = () => { this.interrupted = false; this.changed(); };
      t.onended = () => { if (this.isRecording && this.source === 'phone') this.recoverCapture(); };
    }
  }

  closeMic() {
    try { this.node?.disconnect(); } catch {}
    try { this.ctx?.close(); } catch {}
    this.stream?.getTracks().forEach(t => { t.onended = null; t.stop(); });
    this.stream = null; this.ctx = null; this.node = null;
  }

  /** iOS stops the mic when the PWA goes to background; on return, reopen it and continue in a new conversation. */
  async recoverCapture() {
    if (!this.isRecording || this.source !== 'phone' || this._recovering) return;
    this._recovering = true;
    try {
      const old = this.session;
      this.session = null;
      if (old) this.finalize(old);
      this.closeMic();
      await this.openMic();
      this.beginSession();
      this.lastError = 'iOS приостанавливал микрофон (приложение было свёрнуто) — запись продолжена в новом разговоре.';
    } catch (e) {
      this.lastError = `Микрофон недоступен: ${e.message}`;
      await this.stop();
    }
    this._recovering = false;
    this.changed();
  }

  async onVisibility() {
    if (document.visibilityState !== 'visible' || !this.isRecording) return;
    this.acquireWakeLock();
    if (this.source !== 'phone') return;
    try { if (this.ctx && this.ctx.state !== 'running') await this.ctx.resume(); } catch {}
    const track = this.stream?.getAudioTracks()[0];
    if (!track || track.readyState === 'ended' || this.ctx?.state !== 'running') this.recoverCapture();
  }

  async acquireWakeLock() {
    if (!settings.values.keepScreenOn || !('wakeLock' in navigator) || document.visibilityState !== 'visible') return;
    try {
      if (!this.wakeLock || this.wakeLock.released) this.wakeLock = await navigator.wakeLock.request('screen');
    } catch {}
  }

  releaseWakeLock() {
    try { this.wakeLock?.release(); } catch {}
    this.wakeLock = null;
  }

  // ------------------------------------------------------------ Omi

  deviceReadyChanged(ready) {
    if (ready) {
      this.deviceLostAt = null;
      if (this.isRecording && this.source === 'omi') {
        if (!this.session) this.beginSession();
        else if (this.session.sampleRate !== omi.sampleRate) this.rotate();
        this.waitingForDevice = false;
      }
    } else if (this.isRecording && this.source === 'omi') {
      this.deviceLostAt = Date.now();
    }
    this.changed();
  }

  // ------------------------------------------------------------ sessions

  beginSession() {
    const rate = this.source === 'omi' ? omi.sampleRate : 16000;
    const c = newConversation(this.source, rate);
    c.templateID = settings.values.defaultTemplate;
    store.insert(c);

    const s = {
      id: c.id, sampleRate: rate, samples: 0, transcript: new LiveTranscript(),
      lastSpeechAt: Date.now(), hasSpeech: false, lastPersist: Date.now(), seq: 0,
      live: null, liveEverOpened: false, liveFailed: false, media: null, writes: [],
      pcmBuf: [], pcmBytes: 0, peak: 0, peakSamples: 0,
    };

    // Audio sink
    const mime = this.source === 'phone' ? pickMime() : null;
    if (mime !== null && this.stream) {
      try {
        const opts = { audioBitsPerSecond: settings.values.audioBitrate || 32000 };
        if (mime) opts.mimeType = mime;
        const mr = new MediaRecorder(this.stream, opts);
        mr.ondataavailable = (e) => {
          if (e.data && e.data.size) s.writes.push(store.addChunk(s.id, s.seq++, e.data, 'media'));
        };
        mr.start(1000);
        s.media = mr;
      } catch (e) {
        console.warn('MediaRecorder failed, falling back to PCM', e);
      }
    }

    // Live transcription
    if (settings.values.transcriptionMode === 'live' && settings.hasKey('deepgram')) {
      const live = new DeepgramLive({
        apiKey: settings.apiKey('deepgram'), model: settings.values.deepgramModel, language: settings.values.language,
        sampleRate: rate, diarize: settings.values.diarize, keyterms: settings.keytermList,
        endpoint: settings.route('deepgram', settings.baseURL('deepgram').replace(/^http/, 'ws') + '/listen'),
      });
      live.onResult = (r) => {
        s.transcript.apply(r);
        if (r.isFinal && r.words.length) { s.lastSpeechAt = Date.now(); s.hasSpeech = true; }
        else if (!r.isFinal && r.transcript) s.lastSpeechAt = Date.now();
        if (s === this.session) this.emit(r.isFinal ? 'transcript' : 'interim');
      };
      live.onStatus = (st, msg) => {
        if (st === 'open') s.liveEverOpened = true;
        if (st === 'failed') s.liveFailed = true;
        if (s !== this.session) return;
        if (st === 'open') this.liveStatus = 'live';
        else if (st === 'connecting') this.liveStatus = 'connecting';
        else if (st === 'reconnecting') this.liveStatus = 'reconnecting';
        else if (st === 'failed') { this.liveStatus = 'failed'; this.liveError = msg || 'Ошибка Deepgram'; }
        this.changed();
      };
      s.live = live;
      this.liveStatus = 'connecting';
      live.start();
    } else {
      this.liveStatus = 'off';
    }

    this.session = s;
    this.sessionCount++;
    this.changed();
  }

  ingest(pcm) {
    const s = this.session;
    if (!s || !pcm.length) return;
    s.samples += pcm.length;
    s.live?.send(pcm);
    if (!s.media) {
      const copy = new Uint8Array(pcm.buffer.slice(pcm.byteOffset, pcm.byteOffset + pcm.byteLength));
      s.pcmBuf.push(copy);
      s.pcmBytes += copy.byteLength;
      if (s.pcmBytes >= s.sampleRate * 2 * 5) this.flushPCM(s);
    }
    // Level meter (every ~100 ms)
    let sum = 0;
    for (let i = 0; i < pcm.length; i += 4) sum += pcm[i] * pcm[i];
    const rms = Math.sqrt(sum / Math.max(1, Math.ceil(pcm.length / 4))) / 32768;
    s.peak = Math.max(s.peak, rms);
    s.peakSamples += pcm.length;
    if (s.peakSamples >= s.sampleRate / 10) {
      this.level = s.peak;
      if (s.peak > settings.values.vadThreshold && (!s.live || s.liveFailed)) { s.lastSpeechAt = Date.now(); s.hasSpeech = true; }
      s.peak = 0; s.peakSamples = 0;
      this.emit('level');
    }
  }

  flushPCM(s) {
    if (!s.pcmBuf.length) return;
    const all = new Uint8Array(s.pcmBytes);
    let o = 0;
    for (const b of s.pcmBuf) { all.set(b, o); o += b.byteLength; }
    s.pcmBuf = []; s.pcmBytes = 0;
    s.writes.push(store.addChunk(s.id, s.seq++, all.buffer, 'pcm'));
  }

  rotate() {
    const old = this.session;
    this.session = null;
    if (old) this.finalize(old);
    if (this.isRecording) this.beginSession();
  }

  async finalize(s) {
    this.finishing.set(s.id, s);
    store.update(s.id, c => { c.segments = s.transcript.segments; c.duration = s.samples / s.sampleRate; });
    // Stop the file writer and wait for its last chunk.
    if (s.media && s.media.state !== 'inactive') {
      await new Promise((resolve) => {
        s.media.onstop = resolve;
        try { s.media.stop(); } catch { resolve(); }
        setTimeout(resolve, 3000);
      });
    }
    this.flushPCM(s);
    const liveResult = s.live ? await s.live.finish() : { gaps: false };
    await Promise.allSettled(s.writes);
    this.finishing.delete(s.id);

    const seconds = s.samples / s.sampleRate;
    const gaps = liveResult.gaps;
    const liveUsable = !!s.live && s.liveEverOpened && !s.liveFailed;
    const needsBatch = settings.values.transcriptionMode === 'afterRecording' || !liveUsable || gaps || settings.values.alwaysRetranscribe;
    const segments = s.transcript.segments;

    if (seconds < 2 && !segments.length && settings.values.deleteEmpty) {
      await store.delete(s.id);
      return;
    }
    const blob = await buildBlobFromChunks(s.id, s.sampleRate);
    if (blob) {
      await store.putAudio(s.id, blob);
      await store.clearChunks(s.id);
    }
    const silent = !s.hasSpeech && !segments.length && liveUsable && !gaps;
    store.update(s.id, c => {
      c.segments = segments;
      c.duration = seconds;
      c.finishedAt = new Date(new Date(c.startedAt).getTime() + seconds * 1000).toISOString();
      c.liveHadGaps = gaps;
      c.audioFile = blob ? 'audio' : null;
      c.needsBatchTranscription = needsBatch && !!blob && !silent;
      c.needsSummary = settings.values.autoSummarize;
      c.status = c.needsBatchTranscription ? 'transcribing' : 'summarizing';
    });
    processing.enqueue(s.id);
  }

  tick() {
    if (!this.isRecording) return;
    const s = this.session;
    const now = Date.now();
    if (s) {
      if (now - s.lastPersist > 20000) {
        s.lastPersist = now;
        store.update(s.id, c => { c.segments = s.transcript.segments; c.duration = s.samples / s.sampleRate; });
      }
      const mins = settings.values.autoSplitMinutes;
      if (mins > 0 && s.hasSpeech && now - s.lastSpeechAt > mins * 60000) {
        if (this.source === 'omi' && !omi.ready) {
          this.session = null;
          this.finalize(s);
          this.waitingForDevice = true;
        } else {
          this.rotate();
        }
        this.changed();
        return;
      }
    }
    if (this.source === 'omi' && this.deviceLostAt && this.session) {
      const limit = Math.max(2, settings.values.autoSplitMinutes) * 60000;
      if (now - this.deviceLostAt > limit) {
        const old = this.session;
        this.session = null;
        this.finalize(old);
        this.waitingForDevice = true;
        this.deviceLostAt = null;
        this.changed();
      }
    }
    this.emit('tick');
  }
}

export const recorder = new Recorder();
