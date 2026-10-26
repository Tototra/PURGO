import { app, h, icon, invoke, bytes, rel, header, notice, empty, button, badge, checkbox, toast, confirmDialog, tilde, sizeBar, ring, revealBtn, trashSummary, mapIcon } from './core.js';
import { rerender, runScan, seg, busyLine } from './kit.js';
import { dups } from './m-files.js';

// ------------------------------------------------------------------ cloud drive

const C = { report: null, busy: null, msg: null };
export const cloud = { id: 'cloud', title: 'Cloud', icon: 'cloud', tint: '#0891b2', st: C };
Object.defineProperty(cloud, 'navTitle', { get: () => (app.os === 'macos' ? 'iCloud Drive' : app.os === 'windows' ? 'OneDrive' : 'Cloud') });

cloud.scan = async () => {
  const r = await runScan(cloud, { text: 'Lecture du cloud…', cmd: 'cloud_scan', showBytes: false });
  C.report = r;
  if (r) for (const f of r.folders) f.selected = f.local > 50e6;
  rerender(cloud);
};

cloud.view = () => {
  const name = C.report?.name || (app.os === 'macos' ? 'iCloud Drive' : app.os === 'windows' ? 'OneDrive' : 'le cloud');
  const parts = [header({ ...cloud, title: name === 'le cloud' ? 'Cloud' : name }, 'Ce qui est dans le cloud mais occupe encore de la place sur ton disque.',
    app.cloud ? button(`Envoyer un dossier vers ${name}…`, async () => {
      const p = await invoke('pick_folder', { start: app.home });
      if (!p) return;
      C.busy = 'Déplacement…'; rerender(cloud);
      try { const d = await invoke('cloud_send', { src: p }); C.msg = `Déplacé dans ${tilde(d)}. Une fois envoyé, libère sa copie locale ici.`; } catch (e) { toast(String(e), 'err'); }
      C.busy = null; cloud.scan();
    }, { icon: 'cloud' }) : null,
    C.report && !C.scanning ? button('Actualiser', cloud.scan, { icon: 'refresh' }) : null)];
  if (C.msg) parts.push(notice(C.msg));
  if (C.busy) parts.push(busyLine(C.busy));
  if (C.scanning) return [...parts, C.scan.el];
  if (!app.cloud) return [...parts, empty({ icon: 'cloud', title: 'Aucun cloud « à la demande » détecté',
    message: app.os === 'linux' ? 'Linux n\'a pas de service cloud intégré avec fichiers à la demande. Le module Rangement peut quand même archiver tes vieux fichiers dans le dossier de ton choix (Nextcloud, Dropbox, disque externe…).'
      : 'Connecte-toi à OneDrive (Windows) ou iCloud Drive (macOS) pour garder tes fichiers en ligne sans qu\'ils occupent ton disque.' })];
  if (!C.report) return [...parts, empty({ icon: 'cloud', title: 'Garde tout, sans rien stocker',
    message: `Les fichiers de ${name} peuvent rester uniquement en ligne : ils restent visibles et se téléchargent quand tu les ouvres. Purgo te montre ce qui occupe encore ton disque.`, action: 'Analyser', onAction: cloud.scan })];
  const local = C.report.folders.reduce((a, f) => a + f.local, 0);
  const total = C.report.folders.reduce((a, f) => a + f.total, 0);
  parts.push(h('div.toolbar', { style: { gap: '20px' } },
    h('div.gauge', { style: { width: '96px', height: '96px' } }, ring(total ? local / total : 0, cloud.tint, 96, 9), h('div.label', h('b', { style: { fontSize: '14px' } }, bytes(local)), h('small', 'en local'))),
    h('div', h('b', `${bytes(total)} dans ${name}, dont ${bytes(local)} aussi stockés sur cet ordinateur.`),
      h('p.muted', { style: { margin: '4px 0 0' } }, app.os === 'windows' ? 'Les fichiers pas encore envoyés ne peuvent pas être libérés tant que la synchronisation n\'est pas terminée.' : 'Les fichiers en cours d\'envoi seront libérés une fois synchronisés.'))));
  parts.push(h('div.list', C.report.folders.map((f) => h('div.row', checkbox(f.selected, (v) => { f.selected = v; rerender(cloud); }, !f.local),
    h('div.cat-ic', icon('folder', 16)), h('div.row-main', h('div.row-name', h('span', f.name)), h('div.row-detail', f.local ? `${Math.round((f.local / Math.max(1, f.total)) * 100)} % stocké en local` : 'Entièrement dans le cloud')),
    sizeBar(f.total ? f.local / f.total : 0, cloud.tint), h('span.size', { style: { minWidth: '150px' } }, `${bytes(f.local)} / ${bytes(f.total)}`), revealBtn(f.path)))));
  const sel = C.report.folders.filter((f) => f.selected);
  parts.push(h('footer.action-bar', h('span.ab-text', `${bytes(sel.reduce((a, f) => a + f.local, 0))} libérables`), h('div.spacer'),
    button('Libérer les copies locales', async () => {
      C.busy = 'Libération des copies locales…'; rerender(cloud);
      const before = sel.reduce((a, f) => a + f.local, 0);
      const res = await invoke('cloud_free', { paths: sel.map((f) => f.path) });
      for (const r of res) { const f = C.report.folders.find((x) => x.path === r.path); if (f) Object.assign(f, r, { selected: false }); }
      const after = res.reduce((a, r) => a + r.local, 0);
      C.busy = null;
      C.msg = `${bytes(before - after)} libérés sur ton disque. Les fichiers restent en ligne et se retéléchargent quand tu les ouvres.`;
      rerender(cloud);
    }, { kind: 'primary', disabled: !sel.length || !!C.busy })));
  return parts;
};

// ------------------------------------------------------------------ organizer

const O = { folder: null, mode: 'sort', days: 60, includeFolders: false, plans: null, msg: null, canUndo: false };
export const organizer = { id: 'organizer', title: 'Rangement', icon: 'inbox', tint: '#06b6d4', st: O };
organizer.onShow = async () => { O.folder ||= `${app.home}${app.os === 'windows' ? '\\' : '/'}Downloads`; O.canUndo = await invoke('organize_can_undo'); rerender(organizer); };
const plan = async () => { O.plans = await invoke('organize_plan', { folder: O.folder, mode: O.mode, days: O.days, includeFolders: O.includeFolders }); rerender(organizer); };
organizer.view = () => {
  const sep = app.os === 'windows' ? '\\' : '/';
  const dl = `${app.home}${sep}Downloads`, desk = `${app.home}${sep}Desktop`;
  const parts = [header(organizer, 'Range Téléchargements et Bureau en un clic, ou archive l\'ancien dans le cloud.',
    O.canUndo ? button('Annuler le dernier rangement', async () => { const n = await invoke('organize_undo'); O.msg = `${n} élément(s) remis à leur place`; O.canUndo = false; if (O.plans) plan(); else rerender(organizer); }, { icon: 'refresh' }) : null)];
  if (O.msg) parts.push(notice(O.msg));
  parts.push(h('div.toolbar',
    h('select', { onchange: async (e) => { if (e.target.value === '*') { const p = await invoke('pick_folder', { start: O.folder }); if (p) O.folder = p; } else O.folder = e.target.value; O.plans = null; rerender(organizer); } },
      h('option', { value: dl, selected: O.folder === dl }, 'Téléchargements'), h('option', { value: desk, selected: O.folder === desk }, 'Bureau'),
      ![dl, desk].includes(O.folder) && O.folder ? h('option', { value: O.folder, selected: true }, O.folder.split(/[\\/]/).pop()) : null, h('option', { value: '*' }, 'Autre dossier…')),
    seg([['sort', 'Trier par type'], ['archive', app.cloud ? `Archiver l'ancien dans ${app.cloud}` : 'Archiver l\'ancien']], O.mode, (v) => { O.mode = v; O.plans = null; rerender(organizer); }),
    O.mode === 'archive' ? h('label', 'Plus de ', h('input', { type: 'number', min: 7, max: 1000, value: O.days, style: { width: '70px' }, onchange: (e) => { O.days = Number(e.target.value); } }), ' jours')
      : h('label', h('input', { type: 'checkbox', checked: O.includeFolders, onchange: (e) => { O.includeFolders = e.target.checked; } }), 'Inclure les dossiers'),
    h('div.spacer'), button('Prévisualiser', plan, { kind: 'primary' })));
  if (!O.plans) return [...parts, empty({ icon: 'inbox', title: 'Un dossier enfin rangé',
    message: `Trier par type : chaque fichier va dans un sous-dossier (Documents, Images, Audio, Installeurs…). Archiver : ce que tu n'as pas touché depuis longtemps part ${app.cloud ? `dans ${app.cloud}` : 'dans ~/Archives'}, classé par mois. Tout est réversible.`,
    action: 'Prévisualiser', onAction: plan })];
  if (!O.plans.length) return [...parts, empty({ icon: 'check', title: 'Déjà rangé', message: 'Rien à déplacer dans ce dossier.' })];
  const groups = [...new Set(O.plans.map((p) => p.category))];
  const bar = h('div');
  const paint = () => {
    const s = O.plans.filter((p) => p.selected);
    bar.replaceChildren(h('footer.action-bar', h('span.ab-text', `${s.length} élément(s) · ${bytes(s.reduce((a, p) => a + p.size, 0))}`), h('div.spacer'),
      button(O.mode === 'sort' ? 'Ranger' : 'Archiver', async () => {
        const [moved, errors] = await invoke('organize_apply', { plans: O.plans });
        O.msg = `${moved} élément(s) rangé(s)` + (errors ? ` · ${errors} échec(s)` : '') + (O.mode === 'archive' && app.cloud ? `. Libère leurs copies locales dans le module ${app.cloud} une fois envoyés.` : '.');
        O.canUndo = true; plan();
      }, { kind: 'primary', disabled: !s.length })));
  };
  paint();
  parts.push(h('div.list', groups.map((g) => [h('div.section-title', `${g} (${O.plans.filter((p) => p.category === g).length})`),
    O.plans.filter((p) => p.category === g).map((p) => h('div.row', checkbox(p.selected, (v) => { p.selected = v; paint(); }),
      h('div.row-main', h('div.row-name', h('span', p.src.split(/[\\/]/).pop())), h('div.row-detail', `→ ${tilde(p.dest.replace(/[\\/][^\\/]*$/, ''))}`)),
      h('span.size', bytes(p.size))))])), bar);
  return parts;
};

// ------------------------------------------------------------------ music

const MU = { projects: null, busy: null };
export const music = { id: 'music', title: 'Musique', icon: 'music', tint: '#db2777', st: MU };
music.scan = async () => {
  const r = await runScan(music, { text: 'Recherche des projets musicaux…', cmd: 'music_scan', showBytes: false });
  MU.projects = (r || []).map((p) => ({ ...p, selected: false }));
  rerender(music);
};
music.view = () => {
  const parts = [header(music, 'Tes projets Ableton Live, leurs sauvegardes automatiques, les backups de FL Studio et les vieux projets à archiver.',
    button('Samples en double', () => { const sep = app.os === 'windows' ? '\\' : '/'; dups.setRoot(`${app.home}${sep}Music`); app.go('dups'); dups.scan(); }, { icon: 'copy' }),
    MU.projects && !MU.scanning ? button('Réanalyser', music.scan, { icon: 'refresh' }) : null)];
  if (MU.result) parts.push(notice(MU.result));
  if (MU.busy) parts.push(busyLine(MU.busy));
  if (MU.scanning) return [...parts, MU.scan.el];
  if (!MU.projects) return [...parts, empty({ icon: 'music', title: 'Range ton studio',
    message: 'Purgo retrouve tes projets, mesure leurs dossiers Backup (des copies automatiques de chaque sauvegarde) et t\'aide à archiver les vieux projets.', action: 'Analyser', onAction: music.scan })];
  if (!MU.projects.length) return [...parts, empty({ icon: 'music', title: 'Aucun projet trouvé', message: 'Aucun projet Ableton Live ni sauvegarde FL Studio dans ton dossier personnel.' })];
  const backups = MU.projects.reduce((a, p) => a + p.backup, 0);
  parts.push(h('div.cards',
    h('div.card', h('h4', icon('clock', 16), 'Sauvegardes automatiques'), h('div.big', bytes(backups)),
      h('p', 'Les DAW gardent une copie de chaque version de tes projets. Tes projets actuels ne sont pas touchés.'),
      button('Mettre les sauvegardes à la Corbeille', async () => {
        const list = MU.projects.filter((p) => p.backup_path);
        const r = await invoke('trash_paths', { paths: list.map((p) => p.backup_path), sizes: list.map((p) => p.backup) });
        MU.result = `Sauvegardes : ${trashSummary(r)}`;
        for (const p of list) { p.size -= p.backup; p.backup = 0; p.backup_path = null; }
        MU.projects = MU.projects.filter((p) => p.daw !== 'FL Studio' || p.size > 0);
        rerender(music);
      }, { kind: 'small', disabled: !backups })),
    h('div.card', h('h4', icon('bulb', 16), 'Astuce Ableton'), h('p', 'Avant d\'archiver, fais Fichier › Rassembler et enregistrer : tous les samples utilisés sont copiés dans le projet, il restera complet même déplacé.'))));
  const sel = MU.projects.filter((p) => p.selected && p.daw !== 'FL Studio');
  parts.push(h('div.list', MU.projects.map((p) => h('div.row', p.daw === 'FL Studio' ? h('span', { style: { width: '16px' } }) : checkbox(p.selected, (v) => { p.selected = v; rerender(music); }),
    h('div.cat-ic', icon('wave', 16)),
    h('div.row-main', h('div.row-name', h('span', p.name), badge(p.daw, 'tint')),
      h('div.row-detail', `${p.sets} ${p.daw === 'FL Studio' ? 'fichier(s)' : 'set(s)'} · modifié ${rel(p.modified)}` + (p.backup ? ` · sauvegardes ${bytes(p.backup)}` : ''))),
    h('span.size', bytes(p.size)), revealBtn(p.path)))));
  parts.push(h('footer.action-bar', h('span.ab-text', `${sel.length} projet(s) · ${bytes(sel.reduce((a, p) => a + p.size, 0))}`), h('div.spacer'),
    button(app.cloud ? `Archiver dans ${app.cloud}` : 'Archiver dans ~/Archives', async () => {
      MU.busy = 'Archivage…'; rerender(music);
      const n = await invoke('music_archive', { paths: sel.map((p) => p.path) }).catch((e) => { toast(String(e), 'err'); return 0; });
      MU.busy = null;
      MU.result = `${n} projet(s) déplacé(s) dans « Archives Musique »` + (app.cloud ? `. Libère leur copie locale dans le module ${app.cloud} une fois envoyés.` : '.');
      MU.projects = MU.projects.filter((p) => !p.selected);
      rerender(music);
    }, { kind: 'primary', disabled: !sel.length })));
  return parts;
};

// ------------------------------------------------------------------ tips

const TP = { tips: null };
export const tips = { id: 'tips', title: 'Conseils', icon: 'bulb', tint: '#d99a00', st: TP };
const loadTips = async () => { TP.tips = await invoke('tips_list'); rerender(tips); };
tips.onShow = loadTips;
tips.view = () => {
  const parts = [header(tips, 'Des réglages du système qui font de la place à ta place, pour de bon.')];
  if (!TP.tips) return [...parts, h('div.empty', h('span.spinner'))];
  parts.push(h('div.scroll.stack', TP.tips.map((t) => h('div.card.lift', h('div.tip',
    h('div.t-ic', icon(mapIcon(t.icon), 20)),
    h('div', { style: { flex: 1 } }, h('div', { style: { display: 'flex', gap: '8px', alignItems: 'center' } }, h('b', t.title), t.done ? badge('Déjà fait', 'green') : null),
      h('p', { style: { margin: '4px 0 0' } }, t.detail)),
    t.done ? h('span', { style: { color: 'var(--green)' } }, icon('check', 24, 'bold'))
      : t.action ? button(t.action, async (e) => {
        e.target.disabled = true;
        try { await invoke('tip_apply', { id: t.id }); toast('C\'est fait'); } catch (er) { toast(String(er), 'err'); }
        loadTips();
      }) : null)))));
  return parts;
};
