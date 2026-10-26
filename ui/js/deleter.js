// One review + progress sheet for every deletion in Purgo.
// Step 1 (review): everything that will be removed, grouped, with paths and sizes; untick what to keep.
// Step 2 (progress): live bar, freed counter, current item, status per row; pause, stop, minimize.
// Step 3 (summary): freed space, failures with their reason, open the Trash.

import { app, h, icon, invoke, bytes, tilde, button, badge, checkbox, countUp } from './core.js';
import { Drum } from './drum.js';

export const trashRun = async (item) => {
  const r = await invoke('trash_paths', { paths: item.paths, sizes: item.paths.map((_, k) => (k === 0 ? item.size : 0)) });
  return { freed: r.freed, error: r.errors?.length ? r.errors.join(' · ') : null };
};

const fmtTime = (s) => (s < 60 ? `${Math.max(1, Math.round(s))} s` : `${Math.floor(s / 60)} min ${Math.round(s % 60)} s`);

/**
 * @param {object} o
 * @param {Array} o.items  {id, name, detail?, paths?, size, badges?, group?}
 * @param {Function} [o.run] async (item) => ({freed, error})
 * @returns {Promise<null | {freed, doneIds:Set, errors:Array, cancelled}>}
 */
export function reviewDelete({ title, subtitle, items, groupBy, action = 'Mettre à la Corbeille', mode = 'trash', note, run = trashRun, onStart, onItem }) {
  return new Promise((resolve) => {
    const list = items.map((i) => ({ ...i, keep: false, status: 'pending', msg: null }));
    const group = groupBy || ((i) => i.group || '');
    const groups = [...new Set(list.map(group))];
    let phase = 'review';
    let paused = false, stopped = false, minimized = false;
    let resumeWait = null;
    const result = { freed: 0, doneIds: new Set(), errors: [], cancelled: false };
    let filter = '';

    const tint = getComputedStyle(document.documentElement).getPropertyValue('--tint').trim() || '#2c6bed';
    const drum = new Drum(74, tint);
    drum.reduce = !!app.settings.reduce_motion;

    const chosen = () => list.filter((i) => !i.keep);
    const total = () => chosen().reduce((a, i) => a + i.size, 0);

    // ---- header
    const titleEl = h('h3', title || 'Avant de supprimer');
    const subEl = h('p.sheet-sub', subtitle || 'Vérifie la liste. Décoche ce que tu veux garder.');
    const chips = h('div.sheet-chips');
    const paintChips = () => chips.replaceChildren(
      badge(`${chosen().length} élément${chosen().length > 1 ? 's' : ''}`, 'gray'),
      badge(bytes(total()), 'tint'),
      mode === 'trash' ? badge('Va dans la Corbeille, récupérable', 'green')
        : mode === 'uninstall' ? badge('Désinstallation', 'orange') : mode === 'remove' ? badge('Retrait', 'orange') : badge('Définitif', 'red'));

    // ---- progress block
    const bar = h('i');
    const barWrap = h('div.sheet-bar', bar);
    const freedEl = h('b.count', bytes(0));
    freedEl.dataset.v = 0;
    const countEl = h('span');
    const etaEl = h('span.muted');
    const currentEl = h('div.sheet-current');
    const progress = h('div.sheet-progress', { hidden: true },
      h('div.sheet-led', freedEl, h('small', 'libérés')),
      h('div', { style: { flex: 1, minWidth: 0 } }, barWrap, h('div.sheet-meta', countEl, etaEl), currentEl));

    // ---- list
    const rowsById = new Map();
    const statusCell = (i) => {
      if (i.status === 'running') return h('span.spinner');
      if (i.status === 'done') return h('span.st-ok', icon('check', 16, 'bold'));
      if (i.status === 'error') return h('span.st-err', { title: i.msg || '' }, icon('x', 16, 'bold'));
      if (i.status === 'skipped') return h('span.muted', 'gardé');
      return h('span.st-wait');
    };
    const body = h('div.sheet-list');
    const paintList = () => {
      rowsById.clear();
      const f = filter.toLowerCase();
      body.replaceChildren(...groups.map((g) => {
        const rows = list.filter((i) => group(i) === g && (!f || i.name.toLowerCase().includes(f) || (i.detail || '').toLowerCase().includes(f)));
        if (!rows.length) return null;
        const size = rows.filter((i) => !i.keep).reduce((a, i) => a + i.size, 0);
        const allOn = rows.every((i) => !i.keep);
        return h('div.sheet-group',
          g ? h('div.sheet-ghead',
            phase === 'review' ? checkbox(allOn, (v) => { rows.forEach((i) => (i.keep = !v)); paintAll(); }) : null,
            h('b', g), h('span.muted', `${rows.length} · ${bytes(size)}`)) : null,
          rows.map((i) => {
            const st = h('div.st', statusCell(i));
            const r = h('div.sheet-row', { class: `${i.keep ? 'kept' : ''} ${i.status}` },
              phase === 'review' ? checkbox(!i.keep, (v) => { i.keep = !v; r.classList.toggle('kept', i.keep); paintTotals(); }) : null,
              h('div.row-main',
                h('div.row-name', h('span', i.name), ...(i.badges || []).map((b) => badge(b.text, b.color))),
                h('div.row-detail', i.status === 'error' && i.msg ? i.msg : tilde(i.detail || i.paths?.[0] || ''))),
              h('span.size', bytes(i.size)), st);
            rowsById.set(i.id, { r, st });
            return r;
          }));
      }));
    };
    const updateRow = (i) => {
      const x = rowsById.get(i.id);
      if (!x) return;
      x.r.className = `sheet-row ${i.status}`;
      x.st.replaceChildren(statusCell(i));
      if (i.status === 'error' && i.msg) x.r.querySelector('.row-detail').textContent = i.msg;
      if (i.status === 'running' && !minimized) x.r.scrollIntoView({ block: 'nearest', behavior: app.settings.reduce_motion ? 'auto' : 'smooth' });
    };

    const search = h('input', { type: 'search', placeholder: 'Filtrer la liste', oninput: (e) => { filter = e.target.value; paintList(); } });
    const tools = h('div.sheet-tools', search,
      button('Tout cocher', () => { list.forEach((i) => (i.keep = false)); paintAll(); }, { kind: 'small' }),
      button('Tout décocher', () => { list.forEach((i) => (i.keep = true)); paintAll(); }, { kind: 'small' }));

    // ---- footer
    const foot = h('div.sheet-foot');
    const paintFoot = () => {
      if (phase === 'review') {
        const n = chosen().length;
        foot.replaceChildren(note ? h('span.sheet-note', note) : h('span'), h('div.spacer'),
          button('Annuler', () => close(null)),
          button(`${action} · ${n} élément${n > 1 ? 's' : ''} · ${bytes(total())}`, start, { kind: mode === 'trash' ? 'primary' : 'danger', disabled: !n }));
      } else if (phase === 'running') {
        foot.replaceChildren(h('span.sheet-note', 'Tu peux réduire cette fenêtre et continuer à utiliser Purgo.'), h('div.spacer'),
          button('Réduire', minimize, { kind: 'small' }),
          button(paused ? 'Reprendre' : 'Pause', togglePause, { kind: 'small' }),
          button('Arrêter', () => { stopped = true; if (paused) togglePause(); }, { kind: 'small' }));
      } else {
        foot.replaceChildren(h('span'), h('div.spacer'),
          mode === 'trash' ? button('Ouvrir la Corbeille', () => invoke('open_trash'), { kind: 'small' }) : null,
          button('Fermer', () => close(result), { kind: 'primary' }));
      }
    };
    const paintTotals = () => { paintChips(); paintFoot(); };
    const paintAll = () => { paintList(); paintTotals(); };

    // ---- minimized pill
    const pillRing = h('i');
    const pillText = h('span');
    const pill = h('button.del-pill', { onclick: () => restore() }, h('span.del-pill-bar', pillRing), pillText);

    const sheet = h('div.sheet',
      h('div.sheet-head', h('div.sheet-drum', drum.canvas), h('div', { style: { flex: 1, minWidth: 0 } }, titleEl, subEl, chips)),
      progress, tools, body, foot);
    const bg = h('div.modal-bg.sheet-bg', { onclick: (e) => { if (e.target === bg && phase !== 'running') close(phase === 'done' ? result : null); } }, sheet);

    function close(v) {
      bg.classList.add('out');
      pill.remove();
      setTimeout(() => bg.remove(), 160);
      document.removeEventListener('keydown', onKey);
      resolve(v);
    }
    function minimize() { minimized = true; bg.style.display = 'none'; document.body.append(pill); }
    function restore() { minimized = false; bg.style.display = ''; pill.remove(); }
    function togglePause() {
      paused = !paused;
      drum.setPhase(paused ? 'idle' : 'cleaning');
      if (!paused && resumeWait) { resumeWait(); resumeWait = null; }
      paintFoot();
    }
    const onKey = (e) => { if (e.key === 'Escape' && phase === 'review') close(null); };
    document.addEventListener('keydown', onKey);

    async function start() {
      const todo = chosen();
      if (!todo.length) return;
      list.filter((i) => i.keep).forEach((i) => (i.status = 'skipped'));
      phase = 'running';
      sheet.classList.add('running');
      titleEl.textContent = 'Suppression en cours';
      subEl.textContent = mode === 'trash' ? 'Chaque élément part dans la Corbeille. Tu pourras tout récupérer tant qu\'elle n\'est pas vidée.' : 'Purgo traite les éléments un par un.';
      progress.hidden = false;
      tools.hidden = true;
      drum.setPhase('cleaning');
      onStart?.();
      paintList();
      paintFoot();
      const totalBytes = todo.reduce((a, i) => a + i.size, 0) || 1;
      let done = 0, processedBytes = 0;
      const t0 = performance.now();
      const paintProgress = (cur) => {
        const k = Math.max(done / todo.length, processedBytes / totalBytes);
        bar.style.width = `${(k * 100).toFixed(1)}%`;
        countEl.textContent = `${done} / ${todo.length} élément${todo.length > 1 ? 's' : ''}`;
        const el = (performance.now() - t0) / 1000;
        etaEl.textContent = done > 0 && done < todo.length ? `environ ${fmtTime((el / done) * (todo.length - done))} restantes` : '';
        if (cur) currentEl.textContent = tilde(cur.paths?.[0] || cur.name);
        countUp(freedEl, result.freed, { duration: 350 });
        pillText.textContent = `Suppression ${done}/${todo.length} · ${bytes(result.freed)}`;
        pillRing.style.width = `${(k * 100).toFixed(1)}%`;
      };
      paintProgress(todo[0]);
      const pool = todo.length > 60 ? 4 : 1;
      let next = 0;
      const worker = async () => {
        while (next < todo.length) {
          if (stopped) return;
          if (paused) await new Promise((r) => (resumeWait = r));
          if (stopped) return;
          const i = todo[next++];
          i.status = 'running';
          updateRow(i);
          paintProgress(i);
          drum.feed(i.name);
          try {
            const r = await run(i);
            result.freed += r?.freed || 0;
            if (r?.error) { i.status = 'error'; i.msg = r.error; result.errors.push({ id: i.id, name: i.name, msg: r.error }); }
            else { i.status = 'done'; result.doneIds.add(i.id); }
          } catch (e) {
            i.status = 'error'; i.msg = String(e); result.errors.push({ id: i.id, name: i.name, msg: String(e) });
          }
          done++;
          processedBytes += i.size;
          onItem?.(i, result.freed);
          updateRow(i);
          paintProgress(null);
        }
      };
      await Promise.all(Array.from({ length: pool }, worker));
      result.cancelled = stopped;
      phase = 'done';
      sheet.classList.remove('running');
      sheet.classList.add('finished');
      drum.setPhase('done');
      currentEl.textContent = '';
      etaEl.textContent = '';
      bar.style.width = '100%';
      titleEl.textContent = stopped ? 'Suppression arrêtée' : result.errors.length ? 'Terminé, avec des éléments ignorés' : 'Terminé';
      subEl.textContent = `${bytes(result.freed)} libérés · ${result.doneIds.size} élément(s) traité(s)`
        + (result.errors.length ? ` · ${result.errors.length} ignoré(s) : survole la croix rouge pour voir pourquoi.` : '')
        + (stopped ? ' · les autres n\'ont pas été touchés.' : '');
      list.filter((i) => i.status === 'pending').forEach((i) => { i.status = 'skipped'; updateRow(i); });
      paintFoot();
      if (minimized) { pillText.textContent = `Terminé · ${bytes(result.freed)} libérés`; pill.classList.add('done'); }
    }

    paintAll();
    document.body.append(bg);
  });
}

export function deleteSummary(r) {
  let s = `${bytes(r.freed)} libérés · ${r.doneIds.size} élément(s) traité(s)`;
  if (r.errors.length) s += ` · ${r.errors.length} ignoré(s) (protégés ou en cours d'utilisation)`;
  if (r.cancelled) s += ' · arrêté avant la fin';
  return s;
}
