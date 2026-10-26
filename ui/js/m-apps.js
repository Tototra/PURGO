import { app, h, icon, invoke, bytes, rel, header, notice, empty, button, badge, checkbox, toast, confirmDialog, itemRow, tilde, mapIcon, scanning, onProgress } from './core.js';
import { rerender, seg, busyLine } from './kit.js';

// ------------------------------------------------------------------ uninstaller

const U = { apps: null, search: '', sort: 'size', sel: null, left: null, finding: false, mode: 'apps', orphans: null, busy: null, msg: null };
export const uninstaller = { id: 'uninstaller', title: 'Désinstallateur', icon: 'appx', tint: '#2f7cf6', st: U };

const loadApps = async () => {
  U.apps = null; rerender(uninstaller);
  U.apps = await invoke('apps_list');
  rerender(uninstaller);
};
uninstaller.onShow = () => { if (!U.apps) loadApps(); };

async function pick(a) {
  U.sel = a; U.left = null; U.finding = true; rerender(uninstaller);
  U.left = await invoke('app_leftovers', { id: a.id });
  U.finding = false;
  if (U.sel?.id === a.id) rerender(uninstaller);
}

async function doUninstall(a, keepApp) {
  const what = keepApp ? 'Réinitialiser' : 'Désinstaller';
  const ok = await confirmDialog(`${what} ${a.name} ?`, keepApp
    ? 'L\'application est conservée ; ses réglages et données sélectionnés partent dans la Corbeille.'
    : (app.os === 'windows' && !a.id.startsWith('appx:') ? 'Le désinstallateur de l\'application va s\'ouvrir. Une fois terminé, Purgo met ses restes sélectionnés à la Corbeille.' : 'L\'application et ses fichiers sélectionnés partent dans la Corbeille (ou sont désinstallés par leur gestionnaire de paquets).'),
    [{ label: what, kind: 'danger' }]);
  if (!ok) return;
  U.busy = `${what} ${a.name}…`; rerender(uninstaller);
  try {
    U.msg = await invoke('app_uninstall', { id: a.id, extra: (U.left || []).filter((i) => i.selected).flatMap((i) => i.paths), keepApp });
    if (!keepApp) { U.apps = U.apps.filter((x) => x.id !== a.id); U.sel = null; U.left = null; }
    else await pick(a);
  } catch (e) { toast(String(e), 'err'); }
  U.busy = null; rerender(uninstaller);
}

uninstaller.view = () => {
  const parts = [header(uninstaller, 'Supprime les applications avec tous leurs fichiers cachés, ou nettoie les restes d\'apps déjà effacées.',
    seg([['apps', 'Applications'], ['orphans', 'Restes d\'apps supprimées']], U.mode, (v) => { U.mode = v; rerender(uninstaller); }),
    button('Actualiser', loadApps, { icon: 'refresh' }))];
  if (U.msg) parts.push(notice(U.msg));
  if (U.busy) parts.push(busyLine(U.busy));

  if (U.mode === 'orphans') {
    if (!U.orphans) return [...parts, empty({ icon: 'search', title: 'Restes d\'applications supprimées',
      message: app.os === 'linux' ? 'Les données des Flatpak et Snap désinstallés restent dans ~/.var/app et ~/snap. Purgo les retrouve.' : app.os === 'macos' ? 'Quand on glisse une app à la Corbeille, ses fichiers restent. Purgo les retrouve en comparant avec les apps installées.' : 'Cette recherche est surtout utile sous Linux et macOS. Sous Windows, les restes apparaissent dans la fiche de chaque application.',
      action: 'Rechercher', onAction: async () => { U.busy = 'Recherche…'; rerender(uninstaller); U.orphans = await invoke('app_orphans'); U.busy = null; rerender(uninstaller); } })];
    if (!U.orphans.length) return [...parts, empty({ icon: 'check', title: 'Rien à signaler', message: 'Aucun reste d\'application trouvé.' })];
    const bar = h('div');
    const paint = () => { const s = U.orphans.filter((i) => i.selected); bar.replaceChildren(h('footer.action-bar', h('span.ab-text', `${bytes(s.reduce((a, i) => a + i.size, 0))} sélectionnés`), h('div.spacer'),
      button('Mettre à la Corbeille', async () => { const r = await invoke('trash_paths', { paths: s.flatMap((i) => i.paths), sizes: s.map((i) => i.size) }); U.msg = `${bytes(r.freed)} mis à la Corbeille`; U.orphans = U.orphans.filter((i) => !i.selected); rerender(uninstaller); }, { kind: 'primary', disabled: !s.length }))); };
    paint();
    return [...parts, h('div.list', U.orphans.map((i) => itemRow(i, paint))), bar];
  }

  if (!U.apps) return [...parts, scanning('Inventaire des applications…', { showBytes: false }).el];
  let list = U.apps.filter((a) => !U.search || a.name.toLowerCase().includes(U.search.toLowerCase()));
  if (U.sort === 'size') list = [...list].sort((a, b) => b.size - a.size);
  if (U.sort === 'used') list = [...list].sort((a, b) => (a.last_used || a.installed || 0) - (b.last_used || b.installed || 0));
  const left = h('div',
    h('div.toolbar', { style: { padding: '10px' } },
      h('input', { type: 'search', placeholder: 'Rechercher', value: U.search, style: { flex: 1 }, oninput: (e) => { U.search = e.target.value; clearTimeout(U.t); U.t = setTimeout(() => rerender(uninstaller), 200); } }),
      h('select', { onchange: (e) => { U.sort = e.target.value; rerender(uninstaller); } },
        [['size', 'Taille'], ['name', 'Nom'], ['used', 'Moins utilisées']].map(([v, l]) => h('option', { value: v, selected: U.sort === v }, l)))),
    h('div.list', { style: { padding: '0 8px' } }, list.map((a) => h('div.row.pick-row', { class: U.sel?.id === a.id ? 'on' : '', onclick: () => pick(a) },
      h('div.cat-ic', icon('appx', 16)),
      h('div.row-main', h('div.row-name', h('span', a.name), badge(a.source, 'tint')),
        h('div.row-detail', a.last_used ? `Utilisée ${rel(a.last_used)}` : a.installed ? `Installée ${rel(a.installed)}` : a.version)),
      h('span.size', a.size ? bytes(a.size) : '—')))));
  let right;
  if (!U.sel) right = h('div', empty({ icon: 'appx', title: 'Choisis une application', message: 'Purgo trouvera ses réglages, caches, données et autres fichiers éparpillés sur le disque.' }));
  else {
    const a = U.sel;
    const total = () => a.size + (U.left || []).filter((i) => i.selected).reduce((s, i) => s + i.size, 0);
    const tot = h('b', `Total : ${bytes(total())}`);
    right = h('div',
      h('div', { style: { padding: '16px', display: 'flex', gap: '12px', alignItems: 'center' } }, h('div.mod-icon', { style: { width: '48px', height: '48px' } }, icon('appx', 24)),
        h('div', h('h3', { style: { margin: 0 } }, a.name), h('div.muted', [a.version && `Version ${a.version}`, a.publisher].filter(Boolean).join(' · ')),
          h('div.muted', a.last_used ? `Dernière utilisation ${rel(a.last_used)}` : a.installed ? `Installée ${rel(a.installed)}` : ''))),
      U.finding ? h('div.empty', h('span.spinner'), 'Recherche des fichiers associés…')
        : (U.left?.length ? h('div.list', h('div.section-title', 'Fichiers associés'), U.left.map((i) => itemRow(i, () => (tot.textContent = `Total : ${bytes(total())}`))))
          : h('div.empty', h('p', 'Aucun fichier associé trouvé : seule l\'application sera supprimée.'))),
      h('footer.action-bar', tot, h('div.spacer'),
        button('Réinitialiser', () => doUninstall(a, true), { disabled: !U.left?.some((i) => i.selected), title: 'Garde l\'app mais efface ses données' }),
        button('Désinstaller', () => doUninstall(a, false), { kind: 'danger' })));
  }
  return [...parts, h('div.split', left, right)];
};

// ------------------------------------------------------------------ packages & updates

const PK = { managers: null, scanning: false, busy: null, msg: null, brew: null };
export const packages = { id: 'packages', title: 'Paquets et mises à jour', navTitle: 'Mises à jour', icon: 'download', tint: '#1d6fe0', st: PK };

async function loadPackages() {
  PK.scanning = true;
  PK.scan = scanning('Interrogation des gestionnaires de paquets…', { showBytes: false });
  const off = onProgress('packages', (t) => PK.scan.update(t));
  rerender(packages);
  try {
    PK.managers = await invoke('packages_status');
    if (PK.managers.some((m) => m.id === 'brew')) PK.brew = await invoke('brew_installed');
  } finally { off(); PK.scanning = false; rerender(packages); }
}

async function act(m, action, target, label) {
  PK.busy = label; rerender(packages);
  try { const out = await invoke('package_action', { manager: m.id, action, target }); PK.msg = `${label.replace('…', '')} : terminé`; if (out && out.length < 160) PK.msg += ` · ${out}`; }
  catch (e) { toast(String(e), 'err'); }
  PK.busy = null;
  await loadPackages();
}

packages.view = () => {
  const parts = [header(packages, 'Les mises à jour et le ménage de tous tes gestionnaires de paquets, au même endroit.',
    button(app.os === 'windows' ? 'Windows Update' : app.os === 'macos' ? 'Mise à jour de macOS' : 'Logithèque', () => invoke('open_os_updates'), { icon: 'external' }),
    PK.managers && !PK.scanning ? button('Actualiser', loadPackages, { icon: 'refresh' }) : null)];
  if (PK.msg) parts.push(notice(PK.msg));
  if (PK.busy) parts.push(busyLine(PK.busy));
  if (PK.scanning) return [...parts, PK.scan.el];
  if (!PK.managers) return [...parts, empty({ icon: 'download', title: 'Tout à jour, tout propre',
    message: app.os === 'windows' ? 'Purgo interroge winget, Scoop, Chocolatey et npm pour trouver les mises à jour et les caches à vider.'
      : app.os === 'linux' ? 'Purgo interroge APT, DNF, pacman, Flatpak, Snap, Homebrew et npm pour trouver les mises à jour et le ménage à faire.'
        : 'Purgo interroge Homebrew, npm, pipx et macOS pour trouver les mises à jour et le ménage à faire.', action: 'Vérifier', onAction: loadPackages })];
  if (!PK.managers.length) return [...parts, empty({ icon: 'download', title: 'Aucun gestionnaire de paquets', message: 'Aucun gestionnaire compatible n\'a été trouvé.' })];
  parts.push(h('div.scroll.stack', PK.managers.map((m) => h('div.card',
    h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px' } }, icon(mapIcon(m.icon), 20), h('b', { style: { fontSize: '16px' } }, m.name),
      m.outdated.length ? badge(`${m.outdated.length} mise(s) à jour`, 'blue') : badge('À jour', 'green'), h('div.spacer'),
      m.outdated.length && m.id !== 'macos' ? button('Tout mettre à jour', () => act(m, 'upgrade_all', null, `Mise à jour ${m.name}…`), { kind: 'small', disabled: !!PK.busy }) : null,
      m.id === 'macos' && m.outdated.length ? button('Ouvrir les Réglages', () => act(m, 'open', null, 'Réglages…'), { kind: 'small' }) : null),
    m.note ? h('p', m.note) : null,
    m.outdated.slice(0, 40).map((o) => h('div.row', h('div.row-main', h('div.row-name', h('span', o.name)), h('div.row-detail', `${o.current || '?'} → ${o.latest}`)),
      m.id !== 'macos' ? button('Mettre à jour', () => act(m, 'upgrade', o.id, `Mise à jour de ${o.name}…`), { kind: 'small', disabled: !!PK.busy }) : null)),
    m.outdated.length > 40 ? h('p', `… et ${m.outdated.length - 40} autres`) : null,
    m.actions.length ? h('div', { style: { display: 'flex', gap: '8px', flexWrap: 'wrap', marginTop: '10px' } }, m.actions.map((a) =>
      button(`${a.title}${a.estimate ? ` (${a.estimate})` : ''}`, () => act(m, a.id, null, `${a.title}…`), { kind: 'small', disabled: !!PK.busy, title: a.info }))) : null)),
    PK.brew?.length ? h('div.card', h('h4', icon('box', 18), 'Paquets Homebrew installés'), h('p', 'Ceux que tu as installés toi-même (sans leurs dépendances), du plus lourd au plus léger.'),
      PK.brew.map((i) => h('div.row', h('div.row-main', h('div.row-name', h('span', i.name), ...i.badges.map((b) => badge(b.text, b.color))), h('div.row-detail', `Installé ${rel(i.meta.installed)}`)),
        h('span.size', bytes(i.size)), button('Désinstaller', async () => {
          const ok = await confirmDialog(`Désinstaller ${i.name} ?`, 'Avec brew uninstall. Tu peux le réinstaller à tout moment.', [{ label: 'Désinstaller', kind: 'danger' }]);
          if (ok) act({ id: 'brew' }, i.meta.cask ? 'uninstall_cask' : 'uninstall', i.meta.name, `Désinstallation de ${i.name}…`);
        }, { kind: 'small' })))) : null));
  return parts;
};
