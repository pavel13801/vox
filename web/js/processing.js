// Post-recording work queue: finalize audio → batch transcription → AI summary/tasks/memories.
import { store, conv } from './store.js';
import { settings } from './settings.js';
import { transcribeBatch } from './stt.js';
import { summarize } from './ai.js';
import { uuid, wavFromPCM16 } from './util.js';

export const processing = {
  queue: [],
  activeID: null,
  running: false,

  enqueue(id) {
    if (this.activeID === id || this.queue.includes(id)) return;
    this.queue.push(id);
    this.pump();
  },

  async pump() {
    if (this.running || !this.queue.length) return;
    this.running = true;
    const id = this.queue.shift();
    this.activeID = id;
    store.changed();
    try { await this.process(id); } catch (e) { console.error(e); }
    this.activeID = null;
    this.running = false;
    store.changed();
    this.pump();
  },

  /** At startup: recover recordings interrupted by a closed tab/crash and resume unfinished work. */
  async resumePending(currentId) {
    for (const c of [...store.conversations]) {
      if (c.id === currentId) continue;
      if (c.status === 'recording') await this.recover(c.id);
      else if (c.status === 'transcribing' || c.status === 'summarizing') this.enqueue(c.id);
    }
  },

  async recover(id) {
    const blob = await buildBlobFromChunks(id, store.conversation(id)?.sampleRate || 16000);
    if (blob) {
      await store.putAudio(id, blob);
      await store.clearChunks(id);
    }
    const hasAudio = !!blob || !!(await store.getAudio(id));
    store.update(id, c => {
      if (blob) c.audioFile = 'audio';
      if (hasAudio) { c.needsBatchTranscription = true; c.status = 'transcribing'; }
      else {
        c.status = c.segments.length ? 'summarizing' : 'failed';
        c.errorMessage = c.segments.length ? null : 'Запись прервалась, аудио не сохранилось';
      }
      c.needsSummary = true;
      if (!c.finishedAt) c.finishedAt = new Date(new Date(c.startedAt).getTime() + c.duration * 1000).toISOString();
    });
    if (store.conversation(id)?.status !== 'failed') this.enqueue(id);
  },

  retry(id) {
    store.update(id, c => {
      c.errorMessage = null;
      if (!c.segments.length && c.audioFile) c.needsBatchTranscription = true;
      if (!c.needsBatchTranscription) c.needsSummary = true;
      c.status = c.needsBatchTranscription ? 'transcribing' : 'summarizing';
    });
    this.enqueue(id);
  },

  retranscribe(id) {
    store.update(id, c => {
      c.errorMessage = null;
      c.needsBatchTranscription = true;
      c.needsSummary = !c.userEditedTitle || !c.overview;
      c.status = 'transcribing';
    });
    this.enqueue(id);
  },

  resummarize(id, templateID) {
    store.update(id, c => {
      c.errorMessage = null;
      c.templateID = templateID;
      c.needsSummary = true;
      c.status = 'summarizing';
    });
    this.enqueue(id);
  },

  async process(id) {
    let c = store.conversation(id);
    if (!c) return;
    if (c.needsBatchTranscription) {
      const audio = await store.getAudio(id);
      if (!audio) {
        store.update(id, x => {
          x.needsBatchTranscription = false;
          if (!x.segments.length) { x.status = 'failed'; x.errorMessage = 'Нет аудио для расшифровки'; }
        });
        if (store.conversation(id)?.status === 'failed') return;
      } else {
        store.update(id, x => { x.status = 'transcribing'; x.errorMessage = null; });
        try {
          const opts = settings.batchOptions();
          opts.onProgress = (i, n) => store.update(id, x => { x.progressText = n > 1 ? `(часть ${i + 1} из ${n})` : ''; }, { persist: false });
          const segs = await transcribeBatch(audio, opts);
          store.update(id, x => {
            delete x.progressText;
            if (segs.length || !x.segments.length) {
              const names = x.speakerNames;
              x.segments = segs;
              x.speakerNames = new Set(segs.map(s => s.speaker)).size > 1 ? {} : names;
            }
            x.needsBatchTranscription = false;
            x.liveHadGaps = false;
            const last = segs.at(-1);
            if (last && x.duration < last.end) x.duration = last.end;
          });
        } catch (e) {
          store.update(id, x => { x.status = 'failed'; x.errorMessage = e.message; });
          return;
        }
      }
    }
    await this.summarizeStep(id);
  },

  async summarizeStep(id) {
    const c = store.conversation(id);
    if (!c) return;
    if (!conv.hasSpeech(c)) {
      if (settings.values.deleteEmpty && c.source !== 'imported') await store.delete(id);
      else store.update(id, x => { x.status = 'done'; x.needsSummary = false; x.title ||= 'Без речи'; x.emoji = '🔇'; });
      return;
    }
    if (!c.needsSummary || !settings.llmConfigured) {
      store.update(id, x => { x.status = 'done'; });
      return;
    }
    store.update(id, x => { x.status = 'summarizing'; x.errorMessage = null; });
    try {
      const r = await summarize(c);
      store.removeTasks(id, true);
      const existing = new Set(store.tasks(id).map(t => t.text.toLowerCase()));
      store.addTasks(r.actionItems.filter(a => !existing.has(a.text.toLowerCase())).map(a => ({
        id: uuid(), text: a.text, done: false, createdAt: new Date().toISOString(), conversationID: id, dueDate: a.due, completedAt: null,
      })));
      const known = new Set(store.memories.map(m => m.text.toLowerCase()));
      store.addMemories(r.memories.filter(m => !known.has(m.toLowerCase())), id);
      store.update(id, x => {
        if (!x.userEditedTitle && r.title) x.title = r.title;
        x.emoji = r.emoji;
        x.category = r.category;
        x.overview = r.overview;
        x.keyPoints = r.keyPoints;
        if (!Object.keys(x.speakerNames || {}).length && Object.keys(r.speakerNames).length) x.speakerNames = r.speakerNames;
        x.needsSummary = false;
        x.status = 'done';
        x.errorMessage = null;
      });
    } catch (e) {
      store.update(id, x => { x.status = 'failed'; x.errorMessage = e.message; });
    }
  },
};

/** Rebuilds a recording from the chunks saved while recording (MediaRecorder blobs or raw PCM). */
export async function buildBlobFromChunks(id, sampleRate) {
  const chunks = await store.getChunks(id);
  if (!chunks.length) return null;
  if (chunks[0].kind === 'pcm') {
    const total = chunks.reduce((n, c) => n + c.data.byteLength, 0);
    const all = new Uint8Array(total);
    let o = 0;
    for (const c of chunks) { all.set(new Uint8Array(c.data), o); o += c.data.byteLength; }
    return wavFromPCM16(all, sampleRate);
  }
  const type = chunks.find(c => c.data?.type)?.data.type || 'audio/mp4';
  return new Blob(chunks.map(c => c.data), { type });
}
