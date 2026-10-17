// IndexedDB persistence. Data shapes match the iOS app (Conversation, ActionItem, MemoryItem, ChatMessage).
import { Emitter, uuid, fmt } from './util.js';

const DB_NAME = 'vox';
const DB_VERSION = 1;

function openDB() {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains('conversations')) db.createObjectStore('conversations', { keyPath: 'id' });
      if (!db.objectStoreNames.contains('blobs')) db.createObjectStore('blobs', { keyPath: 'id' });
      if (!db.objectStoreNames.contains('chunks')) {
        const s = db.createObjectStore('chunks', { autoIncrement: true });
        s.createIndex('conv', 'convId');
      }
      if (!db.objectStoreNames.contains('kv')) db.createObjectStore('kv', { keyPath: 'key' });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function tx(db, stores, mode, fn) {
  return new Promise((resolve, reject) => {
    const t = db.transaction(stores, mode);
    let result;
    t.oncomplete = () => resolve(result);
    t.onerror = () => reject(t.error);
    t.onabort = () => reject(t.error);
    result = fn(t);
  });
}

function reqP(r) {
  return new Promise((resolve, reject) => {
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

export function newConversation(source, sampleRate = 16000) {
  const now = new Date().toISOString();
  return {
    id: uuid(),
    createdAt: now,
    startedAt: now,
    finishedAt: null,
    title: '',
    emoji: '🎙️',
    category: '',
    overview: '',
    keyPoints: [],
    segments: [],
    speakerNames: {},
    status: 'recording',
    source,
    audioFile: null,
    duration: 0,
    errorMessage: null,
    needsBatchTranscription: false,
    needsSummary: true,
    templateID: 'standard',
    starred: false,
    liveHadGaps: false,
    sampleRate,
    userEditedTitle: false,
  };
}

// Helpers that work on a conversation object
export const conv = {
  displayTitle: (c) => c.title || `Запись ${fmt.short(c.startedAt)}`,
  speakerName: (c, sp) => (c.speakerNames && c.speakerNames[String(sp)]) || `Спикер ${sp + 1}`,
  hasSpeech: (c) => (c.segments || []).some(s => (s.text || '').trim().length > 0),
  isProcessing: (c) => c.status === 'transcribing' || c.status === 'summarizing',
  plain: (c) => (c.segments || []).map(s => s.text).join(' '),
  wordCount: (c) => (c.segments || []).reduce((n, s) => n + (s.text || '').split(/\s+/).filter(Boolean).length, 0),
  speakers: (c) => [...new Set((c.segments || []).map(s => s.speaker))],
  transcript: (c, withTs = true) => (c.segments || [])
    .map(s => `${withTs ? `[${fmt.clock(s.start)}] ` : ''}${conv.speakerName(c, s.speaker)}: ${s.text}`).join('\n'),
  markdown: (c, tasks = []) => {
    let md = `# ${c.emoji} ${conv.displayTitle(c)}\n\n`;
    md += `- Дата: ${fmt.long(c.startedAt)}\n- Длительность: ${fmt.duration(c.duration)}\n`;
    if (c.category) md += `- Категория: ${c.category}\n`;
    md += '\n';
    if (c.overview) md += `## Сводка\n\n${c.overview}\n\n`;
    if (c.keyPoints?.length) md += `## Ключевые моменты\n\n${c.keyPoints.map(p => `- ${p}`).join('\n')}\n\n`;
    if (tasks.length) md += `## Задачи\n\n${tasks.map(t => `- [${t.done ? 'x' : ' '}] ${t.text}`).join('\n')}\n\n`;
    if (c.segments?.length) {
      md += '## Транскрипт\n\n';
      for (const s of c.segments) md += `**${conv.speakerName(c, s.speaker)}** _[${fmt.clock(s.start)}]_: ${s.text}\n\n`;
    }
    return md;
  },
};

export const STATUS_LABEL = {
  recording: 'Идёт запись',
  transcribing: 'Расшифровка…',
  summarizing: 'Анализ ИИ…',
  done: 'Готово',
  failed: 'Ошибка',
};

class Store extends Emitter {
  constructor() {
    super();
    this.db = null;
    this.conversations = [];
    this.actionItems = [];
    this.memories = [];
    this.chatMessages = [];
    this.loaded = false;
    this._pending = false;
  }

  changed() {
    if (this._pending) return;
    this._pending = true;
    queueMicrotask(() => { this._pending = false; this.emit('change'); });
  }

  async init() {
    this.db = await openDB();
    const all = await tx(this.db, ['conversations'], 'readonly', t => reqP(t.objectStore('conversations').getAll()));
    this.conversations = (await all) || [];
    this.sort();
    const kv = async (key) => {
      const r = await tx(this.db, ['kv'], 'readonly', t => reqP(t.objectStore('kv').get(key)));
      return (await r)?.value || [];
    };
    this.actionItems = await kv('tasks');
    this.memories = await kv('memories');
    this.chatMessages = await kv('chat');
    this.loaded = true;
    try { await navigator.storage?.persist?.(); } catch {}
    this.changed();
  }

  sort() { this.conversations.sort((a, b) => new Date(b.startedAt) - new Date(a.startedAt)); }

  // ---- conversations
  conversation(id) { return this.conversations.find(c => c.id === id); }

  insert(c) {
    this.conversations.unshift(c);
    this.sort();
    this.persist(c);
    this.changed();
  }

  update(id, fn, { persist = true } = {}) {
    const c = this.conversation(id);
    if (!c) return;
    fn(c);
    if (persist) this.persist(c);
    this.changed();
  }

  persist(c) {
    const copy = JSON.parse(JSON.stringify(c));
    tx(this.db, ['conversations'], 'readwrite', t => t.objectStore('conversations').put(copy)).catch(console.error);
  }

  async delete(id) {
    this.conversations = this.conversations.filter(c => c.id !== id);
    let changed = false;
    for (const t of this.actionItems) if (t.conversationID === id) { t.conversationID = null; changed = true; }
    if (changed) this.saveKV('tasks', this.actionItems);
    this.changed();
    await tx(this.db, ['conversations', 'blobs'], 'readwrite', t => {
      t.objectStore('conversations').delete(id);
      t.objectStore('blobs').delete(id);
    }).catch(console.error);
    await this.clearChunks(id);
  }

  // ---- audio blobs
  async putAudio(id, blob) {
    await tx(this.db, ['blobs'], 'readwrite', t => t.objectStore('blobs').put({ id, blob, type: blob.type, size: blob.size }));
  }

  async getAudio(id) {
    const r = await tx(this.db, ['blobs'], 'readonly', t => reqP(t.objectStore('blobs').get(id)));
    const rec = await r;
    return rec ? rec.blob : null;
  }

  // ---- in-progress chunks (crash safety)
  addChunk(convId, seq, data, kind) {
    return tx(this.db, ['chunks'], 'readwrite', t => t.objectStore('chunks').add({ convId, seq, data, kind })).catch(console.error);
  }

  async getChunks(convId) {
    const r = await tx(this.db, ['chunks'], 'readonly', t => reqP(t.objectStore('chunks').index('conv').getAll(convId)));
    const list = (await r) || [];
    return list.sort((a, b) => a.seq - b.seq);
  }

  async clearChunks(convId) {
    await tx(this.db, ['chunks'], 'readwrite', t => {
      const idx = t.objectStore('chunks').index('conv');
      const cur = idx.openKeyCursor(IDBKeyRange.only(convId));
      cur.onsuccess = () => {
        const c = cur.result;
        if (c) { t.objectStore('chunks').delete(c.primaryKey); c.continue(); }
      };
    }).catch(console.error);
  }

  // ---- kv arrays
  saveKV(key, value) {
    const copy = JSON.parse(JSON.stringify(value));
    tx(this.db, ['kv'], 'readwrite', t => t.objectStore('kv').put({ key, value: copy })).catch(console.error);
  }

  // tasks
  tasks(convId) { return this.actionItems.filter(t => t.conversationID === convId); }
  addTask(text, conversationID = null, dueDate = null) {
    this.actionItems.unshift({ id: uuid(), text, done: false, createdAt: new Date().toISOString(), conversationID, dueDate, completedAt: null });
    this.saveKV('tasks', this.actionItems); this.changed();
  }
  addTasks(items) {
    if (!items.length) return;
    this.actionItems.unshift(...items);
    this.saveKV('tasks', this.actionItems); this.changed();
  }
  toggleTask(id) {
    const t = this.actionItems.find(x => x.id === id);
    if (!t) return;
    t.done = !t.done;
    t.completedAt = t.done ? new Date().toISOString() : null;
    this.saveKV('tasks', this.actionItems); this.changed();
  }
  updateTask(id, text) {
    const t = this.actionItems.find(x => x.id === id);
    if (t) { t.text = text; this.saveKV('tasks', this.actionItems); this.changed(); }
  }
  deleteTask(id) {
    this.actionItems = this.actionItems.filter(x => x.id !== id);
    this.saveKV('tasks', this.actionItems); this.changed();
  }
  removeTasks(convId, onlyOpen) {
    this.actionItems = this.actionItems.filter(t => !(t.conversationID === convId && (!onlyOpen || !t.done)));
    this.saveKV('tasks', this.actionItems); this.changed();
  }

  // memories
  addMemories(texts, conversationID = null) {
    if (!texts.length) return;
    const items = texts.map(text => ({ id: uuid(), text, createdAt: new Date().toISOString(), conversationID }));
    this.memories.unshift(...items);
    this.saveKV('memories', this.memories); this.changed();
  }
  updateMemory(id, text) {
    const m = this.memories.find(x => x.id === id);
    if (m) { m.text = text; this.saveKV('memories', this.memories); this.changed(); }
  }
  deleteMemory(id) {
    this.memories = this.memories.filter(x => x.id !== id);
    this.saveKV('memories', this.memories); this.changed();
  }

  // chat
  appendChat(m) { this.chatMessages.push(m); this.saveKV('chat', this.chatMessages); this.changed(); }
  updateChat(id, text, isError = false, persist = true) {
    const m = this.chatMessages.find(x => x.id === id);
    if (!m) return;
    m.text = text; m.isError = isError;
    if (persist) this.saveKV('chat', this.chatMessages);
    this.changed();
  }
  clearChat() { this.chatMessages = []; this.saveKV('chat', []); this.changed(); }

  // ---- backup
  exportJSON() {
    return JSON.stringify({
      app: 'Vox', version: 1, exportedAt: new Date().toISOString(),
      conversations: this.conversations, tasks: this.actionItems, memories: this.memories, chat: this.chatMessages,
    }, null, 2);
  }

  async importJSON(text) {
    const data = JSON.parse(text);
    if (!data || !Array.isArray(data.conversations)) throw new Error('Это не файл резервной копии Vox');
    const known = new Set(this.conversations.map(c => c.id));
    let added = 0;
    for (const c of data.conversations) {
      if (!c.id || known.has(c.id)) continue;
      if (c.status === 'recording' || c.status === 'transcribing' || c.status === 'summarizing') c.status = 'done';
      this.conversations.push(c); this.persist(c); added++;
    }
    this.sort();
    const merge = (cur, inc) => { const ids = new Set(cur.map(x => x.id)); return [...cur, ...(inc || []).filter(x => !ids.has(x.id))]; };
    this.actionItems = merge(this.actionItems, data.tasks); this.saveKV('tasks', this.actionItems);
    this.memories = merge(this.memories, data.memories); this.saveKV('memories', this.memories);
    this.changed();
    return added;
  }

  async deleteAll() {
    const ids = this.conversations.map(c => c.id);
    for (const id of ids) await this.delete(id);
    this.actionItems = []; this.saveKV('tasks', []);
    this.memories = []; this.saveKV('memories', []);
    this.chatMessages = []; this.saveKV('chat', []);
    this.changed();
  }

  async estimate() {
    try { return await navigator.storage.estimate(); } catch { return null; }
  }
}

export const store = new Store();
