import { reviewDelete, deleteSummary } from './deleter.js';
import { app, h, icon, invoke, bytes, rel, header, notice, empty, button, badge, checkbox, toast, confirmDialog, itemRow, tilde, sizeBar, revealBtn, trashItems, trashSummary, daysSince } from './core.js';
import { rerender, runScan, runClean, seg } from './kit.js';

const pickFolder = (start) => invoke('pick_folder', { start });

// ------------------------------------------------------------------ space lens

const L = { roots: null, stack: [], nodes: null, loading: false, msg: null };
export const lens = { id: 'lens', title: 'Explorateur d\'espace', icon: 'pie', tint: '#8b5cf6', st: L };

async function openDir(path, push = true) {
  if (push) L.stack.push(path);
  L.loading = true; L.nodes = null; rerender(lens);
  const nodes = await invoke('dir_children', { path });
  if (L.stack[L.stack.length - 1] === path) { L.nodes = nodes; L.loading = false; rerender(lens); }
}
lens.onShow = async () => {
  if (!L.roots) { L.roots = await invoke('lens_roots'); openDir(L.roots[0][1]); }
};
lens.view = () => {
  const cur = L.stack[L.stack.length - 1];
  const parts = [header(lens, 'Visualise ce qui occupe ton disque, dossier par dossier.',
    (L.roots || []).map(([label, p]) => button(label, () => { L.stack = []; openDir(p); }, { kind: 'small' })),
    button('Choisir…', async () => { const p = await pickFolder(cur); if (p) { L.stack = []; openDir(p); } }, { kind: 'small', icon: 'folder' }))];
  if (L.msg) parts.push(notice(L.msg));
  const crumbs = h('div.crumbs', L.stack.map((p, i) => [i ? icon('chevron', 12) : null,
    h('button', { onclick: () => { L.stack = L.stack.slice(0, i + 1); openDir(p, false); } }, i === 0 ? (p === app.home ? 'Accueil' : p) : p.split(/[\\/]/).pop())]));
  const total = (L.nodes || []).reduce((a, n) => a + n.size, 0);
  parts.push(h('div.toolbar', crumbs, h('div.spacer'), L.loading ? h('span.busy', h('span.spinner'), 'Calcul des tailles…') : h('b', `Total : ${bytes(total)}`)));
  if (!L.nodes) return [...parts, h('div.empty', h('span.spinner'))];
  const max = Math.max(1, ...L.nodes.map((n) => n.size));
  parts.push(h('div.list', L.nodes.map((n) => h('div.row', { ondblclick: () => n.is_dir && openDir(n.path), style: { cursor: n.is_dir ? 'pointer' : 'default' } },
    h('div.cat-ic', icon(n.is_dir ? 'folder' : 'file', 16)),
    h('div.row-main', h('div.row-name', h('span', n.name))),
    sizeBar(n.size / max, lens.tint), h('span.size', bytes(n.size)),
    h('button.icon-btn', { title: 'Mettre à la Corbeille', onclick: async () => {
      const r = await reviewDelete({ items: [{ id: n.path, name: n.name, paths: [n.path], size: n.size, detail: n.path }] });
      if (!r) return;
      L.msg = deleteSummary(r); L.nodes = L.nodes.filter((x) => !r.doneIds.has(x.path)); rerender(lens);
    } }, icon('trash', 15)),
    revealBtn(n.path),
    n.is_dir ? h('button.icon-btn', { title: 'Ouvrir', onclick: () => openDir(n.path) }, icon('chevron', 16)) : null))));
  return parts;
};

// ------------------------------------------------------------------ large & old files

const LF = { root: null, items: null, minMb: 100, kind: 'all', age: 0 };
export const large = { id: 'large', title: 'Gros et anciens fichiers', icon: 'file', tint: '#7c3aed', st: LF };
const KINDS = [['all', 'Tous'], ['video', 'Vidéos'], ['audio', 'Audio'], ['archive', 'Archives et images disque'], ['image', 'Images'], ['document', 'Documents'], ['other', 'Autres']];
const AGES = [[0, 'Peu importe'], [30, 'Pas ouverts depuis 1 mois'], [182, 'Depuis 6 mois'], [365, 'Depuis 1 an']];

large.scan = async () => {
  LF.root = LF.root || app.home;
  const r = await runScan(large, { text: 'Exploration des fichiers…', cmd: 'large_files', args: { root: LF.root, minMb: 10 }, showBytes: false });
  LF.items = r || [];
  rerender(large);
};
large.view = () => {
  const parts = [header(large, 'Les fichiers volumineux et ceux que tu n\'as pas ouverts depuis longtemps.',
    button(`Dossier : ${!LF.root || LF.root === app.home ? 'Accueil' : LF.root.split(/[\\/]/).pop()}`, async () => { const p = await pickFolder(LF.root || app.home); if (p) { LF.root = p; large.scan(); } }, { icon: 'folder' }),
    LF.items && !LF.scanning ? button('Réanalyser', large.scan, { icon: 'refresh' }) : null)];
  if (LF.result) parts.push(notice(LF.result));
  if (LF.scanning || LF.cleaning) return [...parts, LF.scan.el];
  if (!LF.items) return [...parts, empty({ icon: 'file', title: 'Trouve ce qui prend de la place', message: 'Purgo liste tous tes fichiers de plus de 10 Mo. Filtre ensuite par taille, type et date de dernière ouverture.', action: 'Analyser', onAction: large.scan })];
  const visible = LF.items.filter((i) => i.size >= LF.minMb * 1e6 && (LF.kind === 'all' || i.meta.kind === LF.kind) && (!LF.age || daysSince(i.meta.accessed) > LF.age));
  const mbLabel = h('span', `≥ ${bytes(LF.minMb * 1e6)}`);
  parts.push(h('div.toolbar',
    h('label', 'Taille ', h('input', { type: 'range', min: 10, max: 5000, value: LF.minMb, oninput: (e) => (mbLabel.textContent = `≥ ${bytes(e.target.value * 1e6)}`), onchange: (e) => { LF.minMb = Number(e.target.value); rerender(large); } }), mbLabel),
    h('select', { onchange: (e) => { LF.kind = e.target.value; rerender(large); } }, KINDS.map(([v, l]) => h('option', { value: v, selected: LF.kind === v }, l))),
    h('select', { onchange: (e) => { LF.age = Number(e.target.value); rerender(large); } }, AGES.map(([v, l]) => h('option', { value: v, selected: LF.age === v }, l)))));
  if (!visible.length) return [...parts, empty({ icon: 'search', title: 'Aucun fichier', message: 'Assouplis les filtres.' })];
  const bar = h('div');
  const paint = () => {
    const s = LF.items.filter((i) => i.selected);
    bar.replaceChildren(h('footer.action-bar', h('span.ab-text', `${s.length} fichier(s) · ${bytes(s.reduce((a, i) => a + i.size, 0))}`), h('div.spacer'),
      button('Mettre à la Corbeille', async () => {
        const kinds = { video: 'Vidéos', audio: 'Audio', archive: 'Archives et images disque', image: 'Images', document: 'Documents', other: 'Autres' };
        const r = await reviewDelete({ items: s, groupBy: (i) => kinds[i.meta.kind] || 'Autres' });
        if (!r) return;
        LF.result = deleteSummary(r);
        LF.items = LF.items.filter((i) => !r.doneIds.has(i.id));
        rerender(large);
      }, { kind: 'primary', disabled: !s.length })));
  };
  paint();
  parts.push(h('div.list', visible.slice(0, 600).map((i) => {
    i.detail = `${tilde(i.paths[0].replace(/[\\/][^\\/]*$/, ''))} · ouvert ${rel(i.meta.accessed)}`;
    return itemRow(i, paint);
  })), bar);
  return parts;
};

// ------------------------------------------------------------------ duplicates

const D = { root: null, groups: null, minKb: 500 };
export const dups = { id: 'dups', title: 'Doublons', icon: 'copy', tint: '#9333ea', st: D };
dups.scan = async () => {
  D.root = D.root || app.home;
  const r = await runScan(dups, { text: 'Recherche des doublons…', cmd: 'duplicates', args: { root: D.root, minKb: D.minKb }, showBytes: false });
  D.groups = r || [];
  rerender(dups);
};
dups.setRoot = (p) => { D.root = p; };
dups.view = () => {
  const parts = [header(dups, 'Fichiers identiques au bit près (empreinte SHA-256), même avec des noms différents.',
    button(`Dossier : ${!D.root || D.root === app.home ? 'Accueil' : D.root.split(/[\\/]/).pop()}`, async () => { const p = await pickFolder(D.root || app.home); if (p) { D.root = p; if (D.groups) dups.scan(); else rerender(dups); } }, { icon: 'folder' }),
    D.groups && !D.scanning ? button('Réanalyser', dups.scan, { icon: 'refresh' }) : null)];
  if (D.result) parts.push(notice(D.result));
  if (D.scanning || D.cleaning) return [...parts, D.scan.el];
  if (!D.groups) {
    const kbLabel = h('span', bytes(D.minKb * 1000));
    return [...parts, empty({ icon: 'copy', title: 'Débusque les doublons', message: 'Dans chaque groupe, la copie la plus ancienne est gardée par défaut.', action: 'Analyser', onAction: dups.scan }),
      h('div.toolbar', { style: { justifyContent: 'center', paddingBottom: '30px' } }, h('label', 'Ignorer les fichiers de moins de ', kbLabel,
        h('input', { type: 'range', min: 1, max: 50000, value: D.minKb, oninput: (e) => { D.minKb = Number(e.target.value); kbLabel.textContent = bytes(D.minKb * 1000); } })))];
  }
  if (!D.groups.length) return [...parts, empty({ icon: 'check', title: 'Aucun doublon', message: 'Chaque fichier est unique dans ce dossier.' })];
  const wasted = D.groups.reduce((a, g) => a + g.size * (g.files.length - 1), 0);
  const bar = h('div');
  const paint = () => {
    const sel = D.groups.flatMap((g) => g.files.filter((f) => f.selected).length < g.files.length ? g.files.filter((f) => f.selected) : []);
    bar.replaceChildren(h('footer.action-bar', h('span.ab-text', `${bytes(sel.reduce((a, f) => a + f.size, 0))} sélectionnés · ${bytes(wasted)} en double au total`), h('div.spacer'),
      button('Supprimer les copies', async () => {
        const r = await reviewDelete({ title: 'Supprimer les copies', subtitle: 'L\'original de chaque groupe est conservé. Vérifie les copies à supprimer.',
          items: sel, groupBy: (f) => D.groups.find((g) => g.files.includes(f))?.files.find((x) => !x.selected)?.name || 'Copies' });
        if (!r) return;
        D.result = deleteSummary(r);
        const gone = r.doneIds;
        D.groups = D.groups.map((g) => ({ ...g, files: g.files.filter((f) => !gone.has(f.id)) })).filter((g) => g.files.length > 1);
        rerender(dups);
      }, { kind: 'primary', disabled: !sel.length })));
  };
  paint();
  parts.push(h('div.list', D.groups.slice(0, 400).map((g) => [h('div.section-title', `${g.files.length} copies · ${bytes(g.size)} chacune · ${bytes(g.size * (g.files.length - 1))} récupérables`),
    g.files.map((f) => itemRow(f, () => {
      if (g.files.every((x) => x.selected)) { f.selected = false; toast('Garde au moins un exemplaire de chaque fichier', 'err'); rerender(dups); return; }
      paint();
    }))])), bar);
  return parts;
};
