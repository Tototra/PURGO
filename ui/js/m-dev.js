import { app, h, icon, invoke, bytes, rel, header, notice, empty, button, badge, checkbox, toast, confirmDialog, itemRow, tilde, sizeBar,
  revealBtn, trashSummary, categoryList, daysSince } from './core.js';
import { rerender, runScan, runClean, listModule, seg, busyLine } from './kit.js';

// ------------------------------------------------------------------ Python

const PY = { report: null, tab: 'envs', filter: 'all', sort: 'size', search: '', sel: null, pkgSearch: '', busy: null, msg: null };
export const python = { id: 'python', title: 'Python', icon: 'code', tint: '#3776cc', st: PY };

python.scan = async () => {
  const r = await runScan(python, { text: 'Recherche des environnements Python…', cmd: 'python_scan', label: 'dans les venv' });
  PY.report = r;
  if (r) for (const e of r.envs) e.selected = false;
  rerender(python);
};

const multiProjects = () => {
  const c = {};
  for (const e of PY.report.envs) if (e.project) c[e.project] = (c[e.project] || 0) + 1;
  return new Set(Object.keys(c).filter((k) => c[k] > 1));
};

function dupPackages() {
  const map = {};
  for (const e of PY.report.envs) for (const p of e.packages) {
    const k = p.name.toLowerCase().replace(/_/g, '-');
    (map[k] ||= { name: p.name, entries: [] }).entries.push({ env: e, version: p.version, size: p.size });
  }
  return Object.values(map).filter((d) => d.entries.length > 1 && d.entries.reduce((a, x) => a + x.size, 0) > 5e6)
    .map((d) => ({ ...d, total: d.entries.reduce((a, x) => a + x.size, 0) })).sort((a, b) => b.total - a.total);
}

async function pyBusy(label, fn) {
  PY.busy = label; rerender(python);
  try { const r = await fn(); return r; } catch (e) { toast(String(e), 'err'); } finally { PY.busy = null; rerender(python); }
}

async function refreshEnv(e) {
  const n = await invoke('python_refresh_env', { path: e.path, kind: e.kind });
  const i = PY.report.envs.findIndex((x) => x.path === e.path);
  if (i >= 0) PY.report.envs[i] = { ...n, selected: false };
  return n;
}

async function uninstallPkg(env, pkg) {
  const ok = await confirmDialog(`Désinstaller ${pkg.name} de ${env.name} ?`, 'Purgo utilise pip (ou uv) de cet environnement, comme dans le terminal.', [{ label: 'Désinstaller', kind: 'danger' }]);
  if (!ok) return;
  await pyBusy(`Désinstallation de ${pkg.name}…`, async () => {
    await invoke('python_uninstall', { env: env.path, package: pkg.name });
    PY.msg = `${pkg.name} désinstallé de ${env.name} · ${bytes(pkg.size)} libérés`;
    await refreshEnv(env);
  });
}

async function trashEnvs(list) {
  const choice = await confirmDialog(`Supprimer ${list.length} environnement(s) ?`,
    'Ils partent dans la Corbeille. Avec la sauvegarde, un fichier requirements-…-purgo.txt est écrit dans chaque projet pour pouvoir tout réinstaller.',
    [{ label: 'Sauvegarder puis supprimer', value: 'save' }, { label: 'Supprimer sans sauvegarder', value: 'nosave', kind: 'danger' }]);
  if (!choice) return;
  await pyBusy('Suppression…', async () => {
    const r = await invoke('python_trash_envs', { envs: list, save: choice === 'save' });
    PY.msg = `${list.length} environnement(s) supprimé(s) · ${trashSummary(r)}` + (choice === 'save' ? ' · requirements sauvegardés dans les projets' : '');
    const gone = new Set(list.map((e) => e.path));
    PY.report.envs = PY.report.envs.filter((e) => !gone.has(e.path));
    if (PY.sel && gone.has(PY.sel)) PY.sel = null;
  });
}

function insights() {
  const r = PY.report;
  const total = r.envs.reduce((a, e) => a + e.size, 0);
  const broken = r.envs.filter((e) => e.broken).length;
  const inactive = r.envs.filter((e) => daysSince(e.last_used) > 90 && !e.tool_owned);
  const dp = dupPackages()[0];
  const unused = r.interpreters.filter((i) => i.removable && !i.used_by.length).length;
  const caches = r.caches.reduce((a, c) => a + c.items.reduce((s, i) => s + i.size, 0), 0);
  const chip = (ic, text, color, fn) => h('button.pill', { style: { cursor: 'pointer', color, border: 'none', background: `color-mix(in srgb, ${color} 14%, transparent)` }, onclick: fn }, icon(ic, 15), text);
  return h('div.toolbar', { style: { gap: '8px' } },
    chip('box', `${r.envs.length} environnements · ${bytes(total)}`, python.tint, () => { PY.tab = 'envs'; PY.filter = 'all'; rerender(python); }),
    broken ? chip('warn', `${broken} cassé(s)`, 'var(--red)', () => { PY.tab = 'envs'; PY.filter = 'broken'; rerender(python); }) : null,
    inactive.length ? chip('moon', `${inactive.length} inactif(s) · ${bytes(inactive.reduce((a, e) => a + e.size, 0))}`, 'var(--orange)', () => { PY.tab = 'envs'; PY.filter = 'inactive'; rerender(python); }) : null,
    dp ? chip('copy', `${dp.name} ×${dp.entries.length} · ${bytes(dp.total)}`, '#9333ea', () => { PY.tab = 'packages'; rerender(python); }) : null,
    unused ? chip('terminal', `${unused} Python inutilisé(s)`, '#0d9488', () => { PY.tab = 'interp'; rerender(python); }) : null,
    caches ? chip('trash', `Caches · ${bytes(caches)}`, 'var(--muted)', () => { PY.tab = 'caches'; rerender(python); }) : null);
}

function envsPane() {
  const multi = multiProjects();
  let list = PY.report.envs.filter((e) => ({ all: true, broken: e.broken, inactive: daysSince(e.last_used) > 90 && !e.tool_owned,
    multiple: e.project && multi.has(e.project), tools: e.tool_owned })[PY.filter]);
  if (PY.search) list = list.filter((e) => e.path.toLowerCase().includes(PY.search.toLowerCase()));
  list.sort(PY.sort === 'size' ? (a, b) => b.size - a.size : PY.sort === 'used' ? (a, b) => (a.last_used || 0) - (b.last_used || 0) : (a, b) => a.name.localeCompare(b.name));
  const sel = PY.report.envs.filter((e) => e.selected);
  const left = h('div',
    h('div.toolbar', { style: { padding: '10px' } },
      h('input', { type: 'search', placeholder: 'Rechercher un chemin', value: PY.search, style: { flex: 1 }, oninput: (e) => { PY.search = e.target.value; clearTimeout(PY.t); PY.t = setTimeout(() => rerender(python), 200); } }),
      h('select', { onchange: (e) => { PY.filter = e.target.value; rerender(python); } }, [['all', 'Tous'], ['broken', 'Cassés'], ['inactive', 'Inactifs (+3 mois)'], ['multiple', 'Plusieurs par projet'], ['tools', 'Outils']].map(([v, l]) => h('option', { value: v, selected: PY.filter === v }, l))),
      h('select', { onchange: (e) => { PY.sort = e.target.value; rerender(python); } }, [['size', 'Taille'], ['used', 'Dernière utilisation'], ['name', 'Nom']].map(([v, l]) => h('option', { value: v, selected: PY.sort === v }, l)))),
    h('div.list', { style: { padding: '0 8px' } }, list.map((e) => h('div.row.pick-row', { class: PY.sel === e.path ? 'on' : '', onclick: () => { PY.sel = e.path; rerender(python); } },
      checkbox(e.selected, (v) => { e.selected = v; rerender(python); }),
      h('div.row-main', h('div.row-name', h('span', e.name), badge(e.kind, 'tint'), e.version ? badge(`py ${e.version}`, 'gray') : null,
        e.broken ? badge('Cassé', 'red') : null, e.tool_owned ? badge('Outil', 'gray') : null, e.project && multi.has(e.project) ? badge('Doublon projet', 'purple') : null),
        h('div.row-detail', { style: { color: daysSince(e.last_used) > 90 ? 'var(--orange)' : '' } }, `${tilde(e.path.replace(/[\\/][^\\/]*$/, ''))} · utilisé ${rel(e.last_used)}`)),
      h('span.size', bytes(e.size))))),
    h('footer.action-bar', h('span.ab-text', sel.length ? `${sel.length} sélectionné(s) · ${bytes(sel.reduce((a, e) => a + e.size, 0))}` : 'Coche des environnements pour les supprimer'),
      h('div.spacer'), button('Supprimer', () => trashEnvs(sel), { kind: 'danger', disabled: !sel.length || !!PY.busy })));

  const e = PY.report.envs.find((x) => x.path === PY.sel);
  let right;
  if (!e) right = h('div', empty({ icon: 'hand', title: 'Choisis un environnement', message: 'Tu verras ses paquets, l\'interpréteur utilisé, et tu pourras le sauvegarder, le recréer ou le supprimer.' }));
  else {
    const max = Math.max(1, e.packages[0]?.size || 1);
    const pk = e.packages.filter((p) => !PY.pkgSearch || p.name.toLowerCase().includes(PY.pkgSearch.toLowerCase()));
    right = h('div',
      h('div', { style: { padding: '16px' } },
        h('div', { style: { display: 'flex', alignItems: 'center' } }, h('h3', { style: { margin: 0, flex: 1 } }, e.name), h('b', bytes(e.size))),
        h('div.mono.muted', tilde(e.path)),
        h('div.muted', { style: { margin: '6px 0' } }, `Python ${e.version || '?'} · ${e.packages.length} paquets · utilisé ${rel(e.last_used)}`),
        e.base_home ? h('div.muted', { style: { fontSize: '12px' } }, `Créé avec : ${tilde(e.base_home)}`) : null,
        e.broken ? notice('Cet environnement est cassé : l\'interpréteur Python qui a servi à le créer n\'existe plus. Recrée-le ou supprime-le.', 'warn') : null,
        e.tool_owned ? h('p', { style: { color: 'var(--orange)', fontSize: '12.5px' } }, 'Cet environnement appartient à une application (dossier caché). Le supprimer peut la casser.') : null,
        h('div', { style: { display: 'flex', gap: '6px', flexWrap: 'wrap', marginTop: '8px' } },
          button('Terminal', () => invoke('open_terminal', { path: e.project || e.path }), { kind: 'small', icon: 'terminal' }),
          button('Copier l\'activation', async () => { const c = await invoke('activate_command', { env: e }); await navigator.clipboard.writeText(c); toast(`Copié : ${c}`); }, { kind: 'small', icon: 'copy' }),
          button('Sauvegarder', () => pyBusy('Sauvegarde…', async () => { const f = await invoke('python_save_requirements', { env: e }); PY.msg = `Requirements sauvegardés : ${tilde(f)}`; invoke('reveal', { path: f }); }), { kind: 'small', icon: 'download' }),
          e.project && e.kind === 'venv' ? button('Recréer', () => pyBusy(`Recréation de ${e.name}… (quelques minutes)`, async () => { PY.msg = await invoke('python_recreate', { env: e }); await refreshEnv(e); }), { kind: 'small', icon: 'refresh', title: 'Sauvegarde les paquets, remplace l\'environnement par un neuf et réinstalle tout' }) : null,
          revealBtn(e.path), h('div.spacer'), button('Supprimer', () => trashEnvs([e]), { kind: 'small' }))),
      h('div', { style: { padding: '0 16px 8px' } }, h('input', { type: 'search', placeholder: 'Filtrer les paquets', value: PY.pkgSearch, style: { width: '100%' }, oninput: (ev) => { PY.pkgSearch = ev.target.value; clearTimeout(PY.t2); PY.t2 = setTimeout(() => rerender(python), 200); } })),
      h('div.list', pk.map((p) => h('div.row', h('div.row-main', h('div.row-name', h('span', p.name), h('span.muted', p.version))),
        sizeBar(p.size / max, python.tint), h('span.size', bytes(p.size)),
        h('button.icon-btn', { title: 'Désinstaller', disabled: e.broken, onclick: () => uninstallPkg(e, p) }, icon('trash', 15))))));
  }
  return h('div.split', left, right);
}

function packagesPane() {
  const d = dupPackages();
  if (!d.length) return empty({ icon: 'check', title: 'Aucun gros paquet en double', message: 'Chaque gros paquet n\'est installé qu\'une fois.' });
  return h('div.scroll.stack',
    notice('Les mêmes paquets sont recopiés dans chaque venv. Avec uv, les environnements partagent les fichiers (liens physiques) : un seul exemplaire de torch sur le disque, même pour 10 projets.', 'info'),
    d.map((x) => h('div.card', h('div', { style: { display: 'flex', alignItems: 'center', gap: '8px' } }, h('b', x.name), badge(`${x.entries.length} environnements`, 'purple'), h('div.spacer'), h('b', bytes(x.total))),
      x.entries.map((en) => h('div.row', h('div.row-main', h('span', en.env.name), h('span.muted', ` ${en.version}`)), h('span.size', bytes(en.size)),
        button('Désinstaller ici', () => uninstallPkg(en.env, { name: x.name, size: en.size }), { kind: 'small', disabled: !!PY.busy }))))));
}

function interpPane() {
  return h('div.list', PY.report.interpreters.map((i) => h('div.row',
    h('div.cat-ic', icon('terminal', 16)),
    h('div.row-main', h('div.row-name', h('b', `Python ${i.version}`), badge(i.source, 'tint'),
      !i.removable ? badge('Système', 'gray') : !i.used_by.length ? badge('Utilisé par aucun venv', 'green') : null),
      h('div.row-detail.mono', tilde(i.binary)),
      i.used_by.length ? h('div.row-detail', `Utilisé par : ${i.used_by.join(', ')}`) : null),
    h('span.size', bytes(i.size)),
    button('Supprimer', async () => {
      const ok = await confirmDialog(`Supprimer Python ${i.version} (${i.source}) ?`,
        i.used_by.length ? `⚠️ ${i.used_by.length} environnement(s) l'utilisent et seront cassés : ${i.used_by.join(', ')}.` : 'Aucun environnement ne l\'utilise.', [{ label: 'Supprimer', kind: 'danger' }]);
      if (!ok) return;
      await pyBusy(`Suppression de Python ${i.version}…`, async () => {
        PY.msg = await invoke('python_remove_interpreter', { root: i.root, source: i.source, size: i.size });
        PY.report.interpreters = PY.report.interpreters.filter((x) => x.root !== i.root);
      });
    }, { kind: 'small', disabled: !i.removable || !!PY.busy }))));
}

function cachesPane() {
  const cats = PY.report.caches;
  if (!cats.length) return empty({ icon: 'check', title: 'Aucun cache Python', message: 'Rien à nettoyer de ce côté.' });
  const bar = h('div');
  const paint = () => {
    const s = cats.flatMap((c) => c.items).filter((i) => i.selected);
    bar.replaceChildren(h('footer.action-bar', h('span.ab-text', `${bytes(s.reduce((a, i) => a + i.size, 0))} sélectionnés`), h('div.spacer'),
      button('Nettoyer', () => pyBusy('Nettoyage des caches…', async () => {
        const r = await invoke('trash_paths', { paths: s.flatMap((i) => i.paths), sizes: s.map((i) => i.size) });
        PY.msg = trashSummary(r);
        for (const c of cats) c.items = c.items.filter((i) => !i.selected);
        PY.report.caches = cats.filter((c) => c.items.length);
      }), { kind: 'primary', disabled: !s.length })));
  };
  paint();
  return h('div', { style: { display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0 } }, categoryList(cats, paint), bar);
}

python.view = () => {
  const parts = [header(python, 'Tous tes venv, interpréteurs, paquets et caches Python au même endroit.',
    PY.report && !PY.scanning ? button('Réanalyser', python.scan, { icon: 'refresh' }) : null)];
  if (PY.msg) parts.push(notice(PY.msg, 'info'));
  if (PY.busy) parts.push(busyLine(PY.busy));
  if (PY.scanning) return [...parts, PY.scan.el];
  if (!PY.report) return [...parts, empty({ icon: 'code', title: 'Fini le chaos des venv',
    message: 'Purgo retrouve chaque venv, environnement Conda, Poetry, pipx, pyenv ou tox, les interpréteurs installés, les paquets en double et tous les caches Python.', action: 'Analyser', onAction: python.scan })];
  parts.push(insights(), h('div.toolbar', seg([['envs', 'Environnements'], ['packages', 'Paquets en double'], ['interp', 'Interpréteurs'], ['caches', 'Caches']], PY.tab, (v) => { PY.tab = v; rerender(python); })));
  parts.push({ envs: envsPane, packages: packagesPane, interp: interpPane, caches: cachesPane }[PY.tab]());
  return parts;
};

// ------------------------------------------------------------------ Node.js

export const node = listModule({
  id: 'node', title: 'Node.js', icon: 'hexagon', tint: '#3c873a', scanCmd: 'node_scan',
  subtitle: 'Les dossiers node_modules de tes projets, les versions de Node et les caches npm, Yarn, pnpm.',
  scanningText: 'Recherche des node_modules…',
  emptyTitle: 'Le trou noir des node_modules',
  emptyMessage: 'Chaque projet JavaScript embarque des centaines de Mo de dépendances. Purgo les retrouve tous ; ceux des projets inactifs depuis 3 mois sont présélectionnés.',
  note: 'Un « npm install » dans le projet recrée son dossier node_modules en quelques secondes. Astuce : pnpm partage les paquets entre projets au lieu de les copier.',
});

// ------------------------------------------------------------------ AI models

export const ai = listModule({
  id: 'ai', title: 'Modèles d\'IA', icon: 'brain', tint: '#9a5cf0', scanCmd: 'ai_scan',
  subtitle: 'Les modèles téléchargés : Ollama, Hugging Face, LM Studio, Whisper, GPT4All, PyTorch.',
  scanningText: 'Recherche des modèles d\'IA…',
  emptyTitle: 'Des Go de poids neuronaux',
  emptyMessage: 'Un modèle local pèse souvent 2 à 40 Go. Purgo les liste tous avec leur date de dernière utilisation. Rien n\'est présélectionné.',
  note: 'Supprimer un modèle Ollama retire aussi ses fichiers de poids, sauf ceux partagés avec un autre modèle. Il se retélécharge avec « ollama pull ».',
  deleteFn: (sel) => invoke('ai_delete', { paths: sel.map((i) => i.paths[0]), sizes: sel.map((i) => i.size) }),
});

// ------------------------------------------------------------------ Git

const G = { repos: null, filter: 'all', busy: null };
export const git = { id: 'git', title: 'Dépôts Git', icon: 'branch', tint: '#f05033', st: G };
git.scan = async () => {
  const r = await runScan(git, { text: 'Inspection des dépôts Git…', cmd: 'git_scan', label: 'de projets' });
  G.repos = (r || []).map((x) => ({ ...x, selected: false }));
  rerender(git);
};
git.view = () => {
  const parts = [header(git, 'Tes dépôts Git : ceux que tu as abandonnés, et surtout ceux qui ne sont sauvegardés nulle part.',
    G.repos && !G.scanning ? button('Réanalyser', git.scan, { icon: 'refresh' }) : null)];
  if (G.result) parts.push(notice(G.result));
  if (G.busy) parts.push(busyLine(G.busy));
  if (G.scanning || G.cleaning) return [...parts, G.scan.el];
  if (!G.repos) return [...parts, empty({ icon: 'branch', title: 'Où sont tes projets ?',
    message: 'Purgo retrouve chaque dépôt Git, sa date de dernier commit, et vérifie s\'il est bien poussé sur un serveur. Un dépôt jamais poussé n\'existe que sur cet ordinateur : c\'est le premier à protéger, pas à supprimer.', action: 'Analyser', onAction: git.scan })];
  if (!G.repos.length) return [...parts, empty({ icon: 'check', title: 'Aucun dépôt Git', message: 'Aucun projet Git trouvé dans ton dossier personnel.' })];
  const stale = (r) => daysSince(r.last_commit) > 365;
  const list = G.repos.filter((r) => ({ all: true, stale: stale(r), unsaved: !r.saved, saved: r.saved })[G.filter]);
  parts.push(h('div.toolbar', seg([['all', 'Tous'], ['stale', 'Abandonnés (+1 an)'], ['unsaved', 'Non sauvegardés'], ['saved', 'Sauvegardés']], G.filter, (v) => { G.filter = v; rerender(git); })));
  const sel = G.repos.filter((r) => r.selected);
  parts.push(h('div.list', list.map((r) => h('div.row',
    checkbox(r.selected, (v) => { r.selected = v; rerender(git); }),
    h('span', { style: { color: r.saved ? 'var(--green)' : 'var(--orange)' } }, icon(r.saved ? 'cloud' : 'warn', 20)),
    h('div.row-main', h('div.row-name', h('b', r.name), badge(r.branch, 'gray'),
      !r.remote ? badge('Aucun serveur', 'red') : !r.upstream ? badge('Branche jamais poussée', 'orange') : null,
      r.ahead ? badge(`${r.ahead} commit(s) non poussé(s)`, 'orange') : null, r.dirty ? badge(`${r.dirty} modif. en cours`, 'yellow') : null,
      stale(r) ? badge('Abandonné', 'gray') : null),
      h('div.row-detail', `${tilde(r.path.replace(/[\\/][^\\/]*$/, ''))} · dernier commit ${rel(r.last_commit)} · .git ${bytes(r.git_size)}`)),
    h('span.size', bytes(r.size)),
    r.web ? h('button.icon-btn', { title: 'Ouvrir sur le serveur', onclick: () => invoke('open_url', { url: r.web }) }, icon('globe', 15)) : null,
    h('button.icon-btn', { title: 'Terminal', onclick: () => invoke('open_terminal', { path: r.path }) }, icon('terminal', 15)),
    revealBtn(r.path)))));
  parts.push(h('footer.action-bar', h('span.ab-text', sel.length ? `${sel.length} sélectionné(s) · ${bytes(sel.reduce((a, r) => a + r.size, 0))}` : `${G.repos.length} dépôts · ${G.repos.filter((r) => !r.saved).length} non sauvegardés`),
    h('div.spacer'),
    button('Compacter l\'historique', async () => {
      G.busy = 'Compactage (git gc)…'; rerender(git);
      let saved = 0;
      for (const r of sel) {
        const n = await invoke('git_gc', { path: r.path });
        saved += Math.max(0, r.git_size - n.git_size);
        Object.assign(r, n, { selected: false });
      }
      G.busy = null; G.result = `Historique compacté · ${bytes(saved)} gagnés, sans rien perdre`; rerender(git);
    }, { disabled: !sel.length || !!G.busy, title: 'git gc : réduit le dossier .git sans rien perdre' }),
    button('Mettre à la Corbeille', async () => {
      const unsaved = sel.filter((r) => !r.saved).length;
      const ok = await confirmDialog(`Mettre ${sel.length} dépôt(s) à la Corbeille ?`,
        unsaved ? `⚠️ ${unsaved} d'entre eux ont du travail qui n'existe que sur cet ordinateur (pas de serveur, commits non poussés ou modifications en cours).` : 'Tous sont sauvegardés sur un serveur : tu pourras les récupérer avec git clone.',
        [{ label: 'Mettre à la Corbeille', kind: 'danger' }]);
      if (!ok) return;
      const r = await runClean(git, 'Déplacement vers la Corbeille…', () => invoke('trash_paths', { paths: sel.map((x) => x.path), sizes: sel.map((x) => x.size) }));
      G.result = trashSummary(r);
      G.repos = G.repos.filter((x) => !x.selected);
      rerender(git);
    }, { kind: 'danger', disabled: !sel.length || !!G.busy })));
  return parts;
};

// ------------------------------------------------------------------ Docker

const DK = { status: null, loading: false, busy: null, msg: null };
export const docker = { id: 'docker', title: 'Docker', icon: 'container', tint: '#1d63ed', st: DK };
const loadDocker = async () => { DK.loading = true; rerender(docker); DK.status = await invoke('docker_status'); DK.loading = false; rerender(docker); };
docker.onShow = () => { if (!DK.status) loadDocker(); };
async function dockerRun(label, args) {
  DK.busy = label; rerender(docker);
  try { DK.msg = await invoke('docker_cmd', { args }); } catch (e) { toast(String(e).slice(0, 300), 'err'); }
  DK.busy = null; await loadDocker();
}
docker.view = () => {
  const parts = [header(docker, 'Images, conteneurs arrêtés, volumes et cache de build qui s\'accumulent.', DK.status?.running ? button('Actualiser', loadDocker, { icon: 'refresh' }) : null)];
  if (DK.msg) parts.push(notice(DK.msg));
  if (DK.busy) parts.push(busyLine(DK.busy));
  const s = DK.status;
  if (!s) return [...parts, h('div.empty', h('span.spinner'))];
  if (!s.installed) return [...parts, empty({ icon: 'container', title: 'Docker n\'est pas installé', message: 'Rien à nettoyer de ce côté. Si tu l\'installes un jour, Purgo surveillera ses images et ses volumes, qui grossissent vite.' })];
  if (!s.running) return [...parts, empty({ icon: 'container', title: 'Docker est arrêté',
    message: 'Lance Docker pour que Purgo puisse analyser les images et les volumes.' + (s.disk_image ? ` Son disque virtuel occupe déjà ${bytes(s.disk_image[1])}.` : ''),
    action: 'Lancer Docker', onAction: () => { invoke('docker_start'); setTimeout(loadDocker, 15000); } })];
  const names = { Images: 'Images', Containers: 'Conteneurs', 'Local Volumes': 'Volumes', 'Build Cache': 'Cache de build' };
  const cmds = { Images: ['image', 'prune', '-a', '-f'], Containers: ['container', 'prune', '-f'], 'Local Volumes': ['volume', 'prune', '-a', '-f'], 'Build Cache': ['builder', 'prune', '-a', '-f'] };
  parts.push(h('div.cards', s.usage.map((u) => h('div.card.lift', h('h4', icon('box', 16), names[u.Type] || u.Type), h('div.big', u.Size), h('p', `Récupérable : ${u.Reclaimable}`),
    cmds[u.Type] ? button('Nettoyer', () => dockerRun(`Nettoyage ${(names[u.Type] || '').toLowerCase()}…`, cmds[u.Type]), { kind: 'small', disabled: !!DK.busy }) : null))));
  if (s.disk_image) parts.push(notice(`Le disque virtuel de Docker occupe ${bytes(s.disk_image[1])} et ne rétrécit pas tout seul après un nettoyage : réduis sa taille dans Docker Desktop › Settings › Resources.`, 'info'));
  parts.push(h('div.list', s.items.map((i) => h('div.row', checkbox(i.selected, (v) => (i.selected = v)),
    h('div.row-main', h('div.row-name', h('span', i.name), ...i.badges.map((b) => badge(b.text, b.color))), h('div.row-detail', i.detail)), h('span.size', i.meta.size || '')))));
  parts.push(h('footer.action-bar', button('Tout nettoyer (system prune)', async () => {
    const ok = await confirmDialog('Tout nettoyer dans Docker ?', 'Supprime les conteneurs arrêtés, toutes les images inutilisées, les volumes orphelins et le cache de build. Les images se retéléchargent avec docker pull.', [{ label: 'Nettoyer', kind: 'danger' }]);
    if (ok) dockerRun('Nettoyage complet…', ['system', 'prune', '-a', '-f', '--volumes']);
  }), h('div.spacer'), button('Supprimer la sélection', async () => {
    const sel = s.items.filter((i) => i.selected);
    const c = sel.filter((i) => i.meta.kind === 'container').map((i) => i.meta.ref);
    const im = sel.filter((i) => i.meta.kind === 'image').map((i) => i.meta.ref);
    const v = sel.filter((i) => i.meta.kind === 'volume').map((i) => i.meta.ref);
    if (c.length) await dockerRun('Suppression des conteneurs…', ['rm', ...c]);
    if (im.length) await dockerRun('Suppression des images…', ['rmi', '-f', ...im]);
    if (v.length) await dockerRun('Suppression des volumes…', ['volume', 'rm', ...v]);
  }, { kind: 'primary' })));
  return parts;
};
