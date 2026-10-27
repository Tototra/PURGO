// Reusable module patterns: re-rendering, the generic "scan a list, trash the selection" module,
// and the categories module (junk-like).

import { reviewDelete, deleteSummary } from './deleter.js';
import { app, h, header, notice, empty, scanning, onProgress, button, itemRow, actionBar, bytes, invoke, trashItems,
  trashSummary, confirmDialog, categoryList, toast } from './core.js';

export function rerender(m) {
  if (app.module !== m.id) return;
  // a re-render rebuilds the view: keep the field being typed in focused, and lists where they were scrolled
  const main = document.querySelector('main');
  const a = document.activeElement;
  const typing = a && main?.contains(a) && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA') && a.type !== 'checkbox' && a.type !== 'range'
    ? { ph: a.placeholder, start: a.selectionStart, end: a.selectionEnd } : null;
  const scrolled = main ? [...main.querySelectorAll('*')].filter((e) => e.scrollTop > 0).map((e) => [e.className, e.scrollTop]) : [];
  app.mount(m, false);
  if (!main) return;
  for (const [cls, top] of scrolled) {
    const e = [...main.querySelectorAll('*')].find((x) => x.className === cls && x.scrollHeight > x.clientHeight);
    if (e) e.scrollTop = top;
  }
  if (typing) {
    const field = [...main.querySelectorAll('input, textarea')].find((x) => x.placeholder === typing.ph);
    if (field) {
      field.focus({ preventScroll: true });
      try { field.setSelectionRange(typing.start, typing.end); } catch {}
    }
  }
}

export function busyLine(text) {
  return text ? h('div.busy', h('span.spinner'), text) : null;
}

/** Runs a scan with the orb screen, progress, and re-render. */
export async function runScan(m, { text, progressKey, cmd, args, showBytes = true, label }) {
  const st = m.st;
  st.scanning = true;
  st.result = null;
  st.scan = scanning(text, { showBytes, label });
  const off = onProgress(progressKey || m.id, (t, b) => st.scan.update(t, b));
  rerender(m);
  try {
    const t0 = performance.now();
    const r = await invoke(cmd, args || {});
    const left = 2200 - (performance.now() - t0);
    if (left > 0 && !app.settings.reduce_motion) await new Promise((res) => setTimeout(res, left));
    if (app.module === m.id && !app.settings.reduce_motion) {
      st.scan.finish('Analyse terminée');
      await new Promise((res) => setTimeout(res, 900));
    }
    return r;
  } catch (e) {
    toast(String(e), 'err');
    return null;
  } finally {
    off();
    st.scanning = false;
  }
}

/** Shows the "cleaning" orb while `work` runs. */
export async function runClean(m, text, work) {
  const st = m.st;
  st.cleaning = true;
  st.scan = scanning(text, { cleaning: true, showBytes: false });
  rerender(m);
  try {
    return await work();
  } finally {
    st.cleaning = false;
  }
}

/** A module that lists items and trashes the selected ones. */
export function listModule(def) {
  const m = { ...def, st: { items: null } };
  const st = m.st;

  async function scan() {
    const r = await runScan(m, { text: def.scanningText, cmd: def.scanCmd, progressKey: def.progressKey });
    st.items = r || [];
    rerender(m);
  }

  async function clean() {
    const sel = st.items.filter((i) => i.selected);
    const r = await reviewDelete({ items: sel, run: def.runItem, mode: def.mode || 'trash', groupBy: def.groupBy, note: def.note });
    if (!r) return;
    st.result = deleteSummary(r);
    st.items = st.items.filter((i) => !r.doneIds.has(i.id));
    rerender(m);
  }

  m.view = () => {
    const parts = [header(m, def.subtitle, st.items && !st.scanning ? button('Réanalyser', scan, { icon: 'refresh' }) : null)];
    if (st.result) parts.push(notice(st.result));
    if (st.scanning || st.cleaning) return [...parts, st.scan.el];
    if (!st.items) return [...parts, empty({ icon: m.icon, title: def.emptyTitle, message: def.emptyMessage, action: 'Analyser', onAction: scan })];
    if (!st.items.length) return [...parts, empty({ icon: 'check', title: 'Rien à signaler', message: def.nothing || 'Rien trouvé ici, tout est propre.' })];
    if (def.note) parts.push(notice(def.note, 'info'));
    const max = Math.max(1, ...st.items.map((i) => i.size));
    const bar = h('div');
    const paintBar = () => {
      const sel = st.items.filter((i) => i.selected);
      const s = sel.reduce((a, i) => a + i.size, 0);
      const t = st.items.reduce((a, i) => a + i.size, 0);
      bar.replaceChildren(actionBar(`${bytes(s)} sélectionnés sur ${bytes(t)}`, def.actionTitle || 'Mettre à la Corbeille', clean, { disabled: !sel.length }));
    };
    paintBar();
    parts.push(h('div.list', st.items.map((i) => itemRow(i, paintBar, { bar: i.size / max, tint: m.tint }))), bar);
    return parts;
  };
  m.scan = scan;
  return m;
}

/** A module whose scan returns categories of items (like system junk). */
export function categoryModule(def) {
  const m = { ...def, st: { cats: null } };
  const st = m.st;

  m.scan = async () => {
    const r = await runScan(m, { text: def.scanningText, cmd: def.scanCmd, progressKey: def.progressKey });
    st.cats = r || [];
    rerender(m);
  };

  m.clean = async () => {
    const sel = st.cats.flatMap((c) => c.items.filter((i) => i.selected).map((i) => ({ ...i, group: c.name })));
    if (!sel.length) return null;
    const r = await reviewDelete({ items: sel, note: 'Ferme les applications concernées pour un meilleur résultat.' });
    if (!r) return null;
    st.result = deleteSummary(r);
    for (const c of st.cats) c.items = c.items.filter((i) => !r.doneIds.has(i.id));
    st.cats = st.cats.filter((c) => c.items.length);
    rerender(m);
    return r;
  };

  m.view = () => {
    const trailing = [...(def.trailing ? def.trailing(m) : [])];
    if (st.cats && !st.scanning) trailing.push(button('Réanalyser', m.scan, { icon: 'refresh' }));
    const parts = [header(m, def.subtitle, trailing)];
    if (st.result) parts.push(notice(st.result));
    if (st.scanning || st.cleaning) return [...parts, st.scan.el];
    if (!st.cats) return [...parts, empty({ icon: m.icon, title: def.emptyTitle, message: def.emptyMessage, action: 'Analyser', onAction: m.scan })];
    if (!st.cats.length) return [...parts, empty({ icon: 'check', title: 'Tout est propre', message: 'Rien à nettoyer ici.' })];
    if (def.extra) parts.push(def.extra(m));
    const bar = h('div');
    const paintBar = () => {
      const all = st.cats.flatMap((c) => c.items);
      const s = all.filter((i) => i.selected).reduce((a, i) => a + i.size, 0);
      const t = all.reduce((a, i) => a + i.size, 0);
      bar.replaceChildren(actionBar(`${bytes(s)} sélectionnés sur ${bytes(t)}`, def.actionTitle || 'Nettoyer', () => m.clean(), { disabled: !s }));
    };
    paintBar();
    parts.push(def.renderCats ? def.renderCats(m, paintBar) : categoryList(st.cats, paintBar), bar);
    return parts;
  };
  return m;
}

export function seg(options, value, onChange) {
  return h('div.seg', options.map(([v, label]) => h('button', { class: v === value ? 'on' : '', onclick: () => onChange(v) }, label)));
}

export function toggle(checked, onChange) {
  return h('label.switch', h('input', { type: 'checkbox', checked, onchange: (e) => onChange(e.target.checked) }), h('span'));
}
