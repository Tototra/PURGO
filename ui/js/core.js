import { Drum } from './drum.js';
// Purgo UI core: Tauri bridge, formatting, DOM helpers, icons and animated components.

const T = window.__TAURI__;
export const invoke = (cmd, args = {}) => T.core.invoke(cmd, args);
export const listen = (ev, cb) => T.event.listen(ev, cb);

export const app = {
  os: 'linux', home: '', user: '', cloud: null, module: 'smart', settings: {},
  render: () => {},
};

// ------------------------------------------------------------------ progress events

const progressSubs = new Map();
listen('progress', (e) => {
  const { module, text, bytes } = e.payload;
  progressSubs.get(module)?.(text, bytes);
});
export const onProgress = (module, cb) => { progressSubs.set(module, cb); return () => progressSubs.delete(module); };

// ------------------------------------------------------------------ formatting

const nf1 = new Intl.NumberFormat('fr-FR', { maximumFractionDigits: 1 });
const nf0 = new Intl.NumberFormat('fr-FR', { maximumFractionDigits: 0 });
export function bytes(b) {
  b = Math.max(0, Number(b) || 0);
  if (b < 1000) return `${nf0.format(b)} o`;
  const u = ['Ko', 'Mo', 'Go', 'To'];
  let i = -1;
  do { b /= 1000; i++; } while (b >= 1000 && i < u.length - 1);
  return `${b >= 100 ? nf0.format(b) : nf1.format(b)} ${u[i]}`;
}
const rtf = new Intl.RelativeTimeFormat('fr', { numeric: 'auto' });
export function rel(ts) {
  if (!ts) return 'jamais';
  const s = ts - Date.now() / 1000;
  const a = Math.abs(s);
  if (a < 3600) return rtf.format(Math.round(s / 60), 'minute');
  if (a < 86400) return rtf.format(Math.round(s / 3600), 'hour');
  if (a < 86400 * 30) return rtf.format(Math.round(s / 86400), 'day');
  if (a < 86400 * 365) return rtf.format(Math.round(s / 86400 / 30), 'month');
  return rtf.format(Math.round(s / 86400 / 365), 'year');
}
export const pct = (v) => `${Math.round((v || 0) * 100)} %`;
export const tilde = (p) => (app.home && p?.startsWith(app.home) ? '~' + p.slice(app.home.length) : p);
export const daysSince = (ts) => (ts ? (Date.now() / 1000 - ts) / 86400 : 99999);

// ------------------------------------------------------------------ DOM

export function h(tag, attrs, ...kids) {
  const [t, ...cls] = tag.split('.');
  const el = document.createElement(t || 'div');
  if (cls.length) el.className = cls.join(' ');
  if (attrs && (typeof attrs !== 'object' || attrs instanceof Node || Array.isArray(attrs))) { kids.unshift(attrs); attrs = null; }
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className += (el.className ? ' ' : '') + v;
    else if (k === 'style' && typeof v === 'object') { for (const [sk, sv] of Object.entries(v)) { if (sv == null) continue; if (sk.startsWith('--')) el.style.setProperty(sk, sv); else el.style[sk] = sv; } }
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'html') el.innerHTML = v;
    else if (k in el && k !== 'list' && k !== 'type') el[k] = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const c of kids.flat(Infinity)) if (c != null && c !== false) el.append(c instanceof Node ? c : String(c));
  return el;
}
// replaceChildren/append ignore null & false (lets views use `cond ? el : null`)
for (const name of ['replaceChildren', 'append']) {
  const orig = Element.prototype[name];
  Element.prototype[name] = function (...k) { return orig.apply(this, k.flat(Infinity).filter((x) => x != null && x !== false)); };
}
export const frag = (...k) => { const f = document.createDocumentFragment(); for (const c of k.flat(Infinity)) if (c) f.append(c); return f; };

// ------------------------------------------------------------------ icons (24×24 stroke)

const P = {
  sparkles: 'M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z M19 3v4 M17 5h4 M5 17v4 M3 19h4',
  drum: 'M4 3h16v18H4z M12 18a5 5 0 1 0 0-10 5 5 0 0 0 0 10z M8.5 14c1.2-.8 2.3-.8 3.5 0s2.3.8 3.5 0 M7 5.5h2 M15 5.5h2',
  play: 'M8 5l11 7-11 7z',
  trash: 'M3 6h18 M8 6V4h8v2 M6 6l1 14h10l1-14 M10 11v6 M14 11v6',
  lock: 'M6 11h12v10H6z M8 11V8a4 4 0 0 1 8 0v3',
  shield: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z M9 12l2 2 4-4',
  gauge: 'M4 18a8 8 0 1 1 16 0 M12 18l4-6 M12 6v2 M6.3 8.3l1.4 1.4 M17.7 8.3l-1.4 1.4',
  wrench: 'M15 4a4 4 0 0 0-4 5.3L4 16.3 7.7 20l7-7A4 4 0 0 0 20 9l-3 1-2-2 1-3z',
  power: 'M12 3v8 M6.3 7.3a8 8 0 1 0 11.4 0',
  appx: 'M4 4h16v16H4z M9 9l6 6 M15 9l-6 6',
  download: 'M12 3v12 M7 10l5 5 5-5 M4 20h16',
  pie: 'M12 3a9 9 0 1 0 9 9h-9z M14 2.5A8 8 0 0 1 21.5 10H14z',
  file: 'M6 3h8l4 4v14H6z M14 3v4h4 M9 13h6 M9 17h6',
  copy: 'M8 8h12v12H8z M16 8V4H4v12h4',
  cloud: 'M7 18h10a4 4 0 0 0 .5-8A6 6 0 0 0 6 11a3.5 3.5 0 0 0 1 7z',
  inbox: 'M3 13l3-8h12l3 8v6H3z M3 13h5l1 2h6l1-2h5',
  music: 'M9 18V5l11-2v13 M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6z M17 19a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
  bulb: 'M9 18h6 M10 21h4 M12 3a6 6 0 0 0-4 10.5c.7.7 1 1.5 1 2.5h6c0-1 .3-1.8 1-2.5A6 6 0 0 0 12 3z',
  code: 'M8 6l-6 6 6 6 M16 6l6 6-6 6 M14 4l-4 16',
  hexagon: 'M12 2l9 5v10l-9 5-9-5V7z M12 8v8 M8.5 10v4 M15.5 10v4',
  container: 'M3 9h18v10H3z M3 9l3-5h12l3 5 M7 12v4 M11 12v4 M15 12v4',
  box: 'M3 7l9-4 9 4v10l-9 4-9-4z M3 7l9 4 9-4 M12 11v10',
  branch: 'M6 3v12 M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6z M18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6z M18 9a9 9 0 0 1-9 9',
  cpu: 'M7 7h10v10H7z M10 10h4v4h-4z M9 3v4 M15 3v4 M9 17v4 M15 17v4 M3 9h4 M3 15h4 M17 9h4 M17 15h4',
  brain: 'M9 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5 3 3 0 0 0 6 1V5a3 3 0 0 0-3-1z M15 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5 3 3 0 0 1-6 1',
  search: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14z M21 21l-5-5',
  folder: 'M3 6h6l2 2h10v11H3z',
  refresh: 'M20 11a8 8 0 0 0-14.7-4.3L4 9 M4 4v5h5 M4 13a8 8 0 0 0 14.7 4.3L20 15 M20 20v-5h-5',
  check: 'M5 12l5 5 9-10',
  x: 'M6 6l12 12 M18 6L6 18',
  terminal: 'M4 5h16v14H4z M7 10l3 2-3 2 M12 15h5',
  globe: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M3 12h18 M12 3c3 3 3 15 0 18 M12 3c-3 3-3 15 0 18',
  gear: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-2.7 1.1V21a2 2 0 0 1-4 0v-.1A1.6 1.6 0 0 0 7.4 19.6l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1A1.6 1.6 0 0 0 3.1 14H3a2 2 0 0 1 0-4h.1A1.6 1.6 0 0 0 4.6 7.4l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1A1.6 1.6 0 0 0 10 3.1V3a2 2 0 0 1 4 0v.1a1.6 1.6 0 0 0 2.6 1.4l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1A1.6 1.6 0 0 0 20.9 10H21a2 2 0 0 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z',
  chevron: 'M9 6l6 6-6 6',
  warn: 'M12 3l10 18H2z M12 10v5 M12 18v.5',
  memory: 'M4 7h16v10H4z M8 7v10 M12 7v10 M16 7v10 M6 20v-3 M18 20v-3',
  battery: 'M3 8h16v8H3z M21 11v2 M5 10h8v4H5z',
  disk: 'M4 5h16v14H4z M4 14h16 M17 17h.5',
  clock: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18z M12 7v5l3 2',
  eye: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z',
  cookie: 'M12 3a9 9 0 1 0 9 9 4 4 0 0 1-5-5 4 4 0 0 1-4-4z M8 13h.5 M12 17h.5 M15 13h.5',
  moon: 'M20 15A8 8 0 1 1 9 4a6 6 0 0 0 11 11z',
  bolt: 'M13 2L4 14h7l-1 8 9-12h-7z',
  external: 'M14 4h6v6 M20 4l-9 9 M18 14v6H4V6h6',
  trophy: 'M8 4h8v5a4 4 0 0 1-8 0z M8 6H4a3 3 0 0 0 4 4 M16 6h4a3 3 0 0 1-4 4 M12 13v4 M8 21h8 M10 17h4v4h-4z',
  wave: 'M2 12h2 M6 8v8 M10 5v14 M14 8v8 M18 10v4 M22 12h-2',
};
export function icon(name, size = 18, extra = '') {
  const s = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  s.setAttribute('viewBox', '0 0 24 24');
  s.setAttribute('width', size); s.setAttribute('height', size);
  s.setAttribute('class', 'ic ' + extra);
  const p = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  p.setAttribute('d', P[name] || P.box);
  s.append(p);
  return s;
}

// ------------------------------------------------------------------ animated number

export function countUp(el, to, { duration = 700, format = bytes } = {}) {
  const from = Number(el.dataset.v || 0);
  el.dataset.v = to;
  if (app.settings.reduce_motion || from === to) { el.textContent = format(to); return; }
  const t0 = performance.now();
  const step = (t) => {
    const k = Math.min(1, (t - t0) / duration);
    const e = 1 - Math.pow(1 - k, 3);
    el.textContent = format(from + (to - from) * e);
    if (k < 1 && el.dataset.v == to) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

// ------------------------------------------------------------------ the orb

export const currentTint = () => getComputedStyle(document.documentElement).getPropertyValue('--tint').trim() || '#2c6bed';

/** The porthole + its dot-matrix display. phase: idle | scanning | cleaning | done */
export function orb({ phase = 'idle', size = 240, onClick, content, machine = false } = {}) {
  const d = new Drum(size, currentTint(), { machine });
  d.reduce = !!app.settings.reduce_motion;
  const start = () => { d.pulse(); setTimeout(onClick, 180); };
  // the LED display reads "Analyser" when idle, so it must start the cycle too
  const display = h('div.display', { onclick: (e) => { if (machine || !onClick || !el.classList.contains('idle')) return; e.stopPropagation(); start(); } });
  const port = h('div.porthole', {
    onclick: (e) => {
      if (!onClick || !el.classList.contains('idle')) return;
      const r = port.getBoundingClientRect();
      if (!machine && Math.hypot(e.clientX - r.left - r.width / 2, e.clientY - r.top - r.height / 2) > size / 2) return;
      start();
    },
    onpointerenter: () => (d.hover = 1),
    onpointerleave: () => (d.hover = 0),
  }, d.canvas);
  if (machine) {
    // the display lives in the machine's control panel
    const m = d.layout();
    const w = m.x1 - m.x0, bh = m.pb - m.y0;
    Object.assign(display.style, { position: 'absolute', left: `${m.x0 + w * 0.57}px`, width: `${w * 0.43 - 16}px`, top: `${m.y0 + bh * 0.2}px`, height: `${bh * 0.6}px` });
    port.append(display);
  }
  const el = h('div.orb', { class: machine ? 'machine' : '', style: { '--size': `${machine ? d.mw : size}px`, '--h': `${d.mh}px` } }, port, machine ? null : display);
  el.lo = d;
  el.set = (p, c) => {
    el.classList.remove('idle', 'scanning', 'cleaning', 'done');
    el.classList.add(p);
    el.classList.toggle('clickable', !!onClick && p === 'idle');
    d.setPhase(p);
    if (c !== undefined) display.replaceChildren(...[c].flat().filter(Boolean));
  };
  el.set(phase, content);
  return el;
}

/** Text line that slides each new value in. */
export function ticker() {
  const el = h('div.ticker');
  let last = 0;
  el.set = (text) => {
    const now = performance.now();
    if (now - last < 90) { const t = tilde(text || ''); el.lastChild && (el.lastChild.textContent = t.length > 80 ? '…' + t.slice(-79) : t); return; }
    last = now;
    const t = tilde(text || '');
    const line = h('span', t.length > 80 ? '…' + t.slice(-79) : t);
    el.append(line);
    while (el.children.length > 2) el.firstChild.remove();
    if (el.children.length === 2) el.firstChild.classList.add('out');
  };
  return el;
}

export function ring(value, color, size = 22, stroke = 4) {
  const r = (size - stroke) / 2;
  const c = 2 * Math.PI * r;
  const ns = 'http://www.w3.org/2000/svg';
  const s = document.createElementNS(ns, 'svg');
  s.setAttribute('width', size); s.setAttribute('height', size); s.setAttribute('class', 'ring');
  const mk = (cls, off) => {
    const e = document.createElementNS(ns, 'circle');
    e.setAttribute('cx', size / 2); e.setAttribute('cy', size / 2); e.setAttribute('r', r);
    e.setAttribute('stroke-width', stroke); e.setAttribute('class', cls);
    e.style.stroke = color;
    if (off != null) { e.setAttribute('stroke-dasharray', c); e.setAttribute('stroke-dashoffset', off); }
    return e;
  };
  s.append(mk('ring-bg'), mk('ring-fg', c * (1 - Math.min(1, Math.max(0, value)))));
  s.update = (v) => s.lastChild.setAttribute('stroke-dashoffset', c * (1 - Math.min(1, Math.max(0, v))));
  return s;
}

// ------------------------------------------------------------------ building blocks

export function header(m, subtitle, ...trailing) {
  return h('header.mod-header',
    h('div.mod-icon', { style: { '--tint': m.tint } }, icon(m.icon, 28)),
    h('div.mod-title', h('h1', m.title), h('p', subtitle)),
    h('div.spacer'), h('div.mod-actions', trailing));
}

export function notice(text, kind = 'ok') {
  return h(`div.notice.${kind}`, icon(kind === 'ok' ? 'check' : kind === 'warn' ? 'warn' : 'bulb', 16), h('span', text));
}

export function badge(text, color = 'gray') {
  return h(`span.badge.c-${color}`, text);
}

export function button(label, onClick, { kind = '', disabled = false, icon: ic, title } = {}) {
  return h(`button.btn${kind ? '.' + kind : ''}`, { onclick: onClick, disabled, title }, ic ? icon(ic, 16) : null, label);
}

export function empty({ icon: ic, title, message, action, onAction }) {
  const e = h('div.empty');
  if (action && onAction) {
    e.append(orb({ size: 230, onClick: onAction, content: [icon('play', 15), h('b', action)] }));
  } else if (ic === 'check') {
    e.append(orb({ phase: 'done', size: 180, content: [icon('check', 16, 'bold'), h('b', 'Propre')] }));
  } else {
    e.append(h('div.empty-ic', icon(ic, 44)));
  }
  e.append(h('h2', title), h('p', message));
  return e;
}

/** Full scanning screen: orb + counter + live ticker. Returns {el, update(text, bytes)}. */
export function scanning(text, { cleaning = false, showBytes = true, label } = {}) {
  const num = h('b.count', bytes(0));
  num.dataset.v = 0;
  const o = orb({ phase: cleaning ? 'cleaning' : 'scanning', size: 240,
    content: showBytes ? [num, h('small', label || (cleaning ? 'nettoyés' : 'trouvés'))] : [h('span.blink'), h('b', cleaning ? 'Essorage' : 'Lavage en cours')] });
  const tk = ticker();
  const title = h('h2', text);
  const el = h('div.scanning', o, title, tk);
  let lastFeed = 0;
  return {
    el, orb: o,
    update: (t, b) => {
      if (t) {
        tk.set(t);
        const now = performance.now();
        if (now - lastFeed > 220 && /[\\/]/.test(t)) { lastFeed = now; o.lo.feed(t); }
      }
      if (showBytes && b != null) countUp(num, b, { duration: 500 });
    },
    finish: (msg) => { o.set('done', [icon('check', 16, 'bold'), h('b', 'Terminé')]); title.textContent = msg || 'Terminé'; tk.set(''); },
  };
}

export function actionBar(text, label, onClick, { disabled = false, kind = 'primary', extra = [] } = {}) {
  return h('footer.action-bar', h('span.ab-text', text), h('div.spacer'), extra, button(label, onClick, { kind, disabled }));
}

export function revealBtn(path) {
  return h('button.icon-btn', { title: 'Afficher dans le gestionnaire de fichiers', onclick: (e) => { e.stopPropagation(); invoke('reveal', { path }); } }, icon('search', 15));
}

export function checkbox(checked, onChange, disabled = false) {
  return h('input', { type: 'checkbox', checked, disabled, onclick: (e) => e.stopPropagation(), onchange: (e) => onChange(e.target.checked) });
}

export function itemRow(item, onToggle, { bar = 0, tint } = {}) {
  return h('div.row', { class: item.selected ? 'sel' : '' },
    checkbox(item.selected, (v) => { item.selected = v; onToggle?.(v); }),
    h('div.row-main',
      h('div.row-name', h('span', item.name), ...(item.badges || []).map((b) => badge(b.text, b.color))),
      item.detail ? h('div.row-detail', tilde(item.detail)) : null),
    bar ? sizeBar(bar, tint) : null,
    h('span.size', bytes(item.size)),
    item.paths?.[0] ? revealBtn(item.paths[0]) : null);
}

export function sizeBar(frac, tint) {
  return h('div.sizebar', h('i', { style: { width: `${Math.max(2, Math.min(100, frac * 100))}%`, background: tint } }));
}

/** Collapsible categories of items with a select-all checkbox. */
export function categoryList(cats, onChange) {
  return h('div.list', cats.map((c) => {
    const total = c.items.reduce((a, i) => a + i.size, 0);
    const body = h('div.cat-body');
    const all = () => c.items.length && c.items.every((i) => i.selected);
    const box = checkbox(all(), (v) => { c.items.forEach((i) => (i.selected = v)); paint(); onChange(); });
    const paint = () => { box.checked = all(); body.replaceChildren(...c.items.map((i) => itemRow(i, () => { box.checked = all(); onChange(); }))); };
    const head = h('div.cat-head', { onclick: () => { el.classList.toggle('open'); if (el.classList.contains('open') && !body.children.length) paint(); } },
      box, h('div.cat-ic', icon(mapIcon(c.icon), 18)),
      h('div.row-main', h('div.row-name', h('b', c.name)), h('div.row-detail', c.info)),
      h('div.cat-total', h('b', bytes(total)), h('small', `${c.items.length} élément${c.items.length > 1 ? 's' : ''}`)),
      icon('chevron', 16, 'chev'));
    const el = h('div.cat', head, body);
    return el;
  }));
}

const ICON_MAP = { internaldrive: 'disk', 'doc.text': 'file', shippingbox: 'box', hammer: 'wrench', 'clock.arrow.circlepath': 'clock', 'camera.viewfinder': 'eye',
  paperclip: 'file', message: 'inbox', iphone: 'memory', 'apple.logo': 'appx', windows: 'appx', 'folder.badge.gearshape': 'folder', brain: 'brain',
  'exclamationmark.triangle': 'warn', globe: 'globe', clock: 'clock', cookie: 'cookie', 'rectangle.stack': 'copy', 'character.cursor.ibeam': 'file', terminal: 'terminal',
  'arrow.down.circle': 'download', network: 'globe', memorychip: 'memory', magnifyingglass: 'search', 'square.stack.3d.up': 'box', eye: 'eye', stethoscope: 'shield',
  'arrow.clockwise': 'refresh', 'trash.circle': 'trash', 'arrow.down.app': 'download', 'arrow.triangle.2.circlepath': 'refresh', 'square.grid.2x2': 'copy',
  textformat: 'file', photo: 'eye', 'trash.slash': 'trash', 'moon.zzz': 'moon', archivebox: 'box', icloud: 'cloud', bolt: 'bolt', waveform: 'wave', mug: 'box',
  cup: 'box', hexagon: 'hexagon', 'chevron.left.forwardslash.chevron.right': 'code' };
export const mapIcon = (n) => ICON_MAP[n] || (P[n] ? n : 'box');

// ------------------------------------------------------------------ dialogs & toasts

export function confirmDialog(title, message, buttons) {
  return new Promise((resolve) => {
    const close = (v) => { bg.classList.add('out'); setTimeout(() => bg.remove(), 180); resolve(v); };
    const bg = h('div.modal-bg', { onclick: (e) => e.target === bg && close(null) },
      h('div.modal', h('h3', title), message ? h('p', message) : null,
        h('div.modal-btns', button('Annuler', () => close(null)),
          buttons.map((b) => button(b.label, () => close(b.value ?? true), { kind: b.kind || 'primary' })))));
    document.body.append(bg);
  });
}

export function toast(text, kind = 'ok') {
  const t = h(`div.toast.${kind}`, icon(kind === 'err' ? 'warn' : 'check', 16), text);
  document.body.append(t);
  setTimeout(() => t.classList.add('out'), 4200);
  setTimeout(() => t.remove(), 4600);
}

/** Calls a command, shows errors as a toast. */
export async function call(cmd, args, okMsg) {
  try {
    const r = await invoke(cmd, args);
    if (okMsg) toast(typeof okMsg === 'function' ? okMsg(r) : okMsg);
    return r;
  } catch (e) {
    toast(String(e).slice(0, 300), 'err');
    throw e;
  }
}

export async function trashItems(items) {
  const paths = [], sizes = [];
  for (const i of items) i.paths.forEach((p, k) => { paths.push(p); sizes.push(k === 0 ? i.size : 0); });
  return invoke('trash_paths', { paths, sizes });
}

export function trashSummary(r) {
  let s = `${bytes(r.freed)} déplacés dans la Corbeille`;
  if (r.errors?.length) s += ` · ${r.errors.length} élément(s) ignoré(s) (protégés ou en cours d'utilisation)`;
  return s;
}

export const trashName = () => (app.os === 'windows' ? 'Corbeille' : 'Corbeille');

/** Purgo's mark: a porthole with a water line. */
export function logo(size = 30) {
  const ns = 'http://www.w3.org/2000/svg';
  const s = document.createElementNS(ns, 'svg');
  s.setAttribute('viewBox', '0 0 32 32');
  s.setAttribute('width', size);
  s.setAttribute('height', size);
  s.setAttribute('class', 'logo-mark');
  s.innerHTML = '<circle cx="16" cy="16" r="15" fill="#e6e9ec"/><circle cx="16" cy="16" r="11.5" fill="#1a1e23"/>'
    + '<clipPath id="lg"><circle cx="16" cy="16" r="9.5"/></clipPath><g clip-path="url(#lg)"><rect x="4" y="4" width="24" height="24" fill="#3b434c"/>'
    + '<path d="M4 18.5c2-1.6 4-1.6 6 0s4 1.6 6 0 4-1.6 6 0 4 1.6 6 0V28H4z" fill="#2c6bed"/></g>'
    + '<path d="M8.6 10.2a9 9 0 0 1 4.4-3.4" stroke="#fff" stroke-opacity=".5" stroke-width="1.6" fill="none" stroke-linecap="round"/>';
  return s;
}
