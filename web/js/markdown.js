// Minimal, safe Markdown → HTML (everything is escaped first).
import { esc } from './util.js';

function inline(s) {
  let t = esc(s);
  t = t.replace(/`([^`]+)`/g, '<code>$1</code>');
  t = t.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  t = t.replace(/(^|[^*])\*([^*\s][^*]*)\*/g, '$1<em>$2</em>');
  t = t.replace(/(^|\s)_([^_]+)_(?=\s|$|[.,!?:;])/g, '$1<em>$2</em>');
  t = t.replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  return t;
}

export function md(text) {
  const lines = String(text || '').split('\n');
  let html = '';
  let list = null; // 'ul' | 'ol'
  const close = () => { if (list) { html += `</${list}>`; list = null; } };
  for (const raw of lines) {
    const line = raw.trim();
    if (!line) { close(); continue; }
    let m;
    if ((m = line.match(/^(#{1,6})\s+(.*)$/))) {
      close();
      const lvl = Math.min(4, m[1].length + 2);
      html += `<h${lvl}>${inline(m[2])}</h${lvl}>`;
    } else if ((m = line.match(/^[-*•]\s+(.*)$/))) {
      if (list !== 'ul') { close(); html += '<ul>'; list = 'ul'; }
      const task = m[1].match(/^\[( |x)\]\s+(.*)$/i);
      html += task ? `<li>${task[1].toLowerCase() === 'x' ? '☑︎' : '☐'} ${inline(task[2])}</li>` : `<li>${inline(m[1])}</li>`;
    } else if ((m = line.match(/^(\d+)[.)]\s+(.*)$/))) {
      if (list !== 'ol') { close(); html += '<ol>'; list = 'ol'; }
      html += `<li>${inline(m[2])}</li>`;
    } else {
      close();
      html += `<p>${inline(line)}</p>`;
    }
  }
  close();
  return `<div class="md">${html}</div>`;
}
