import { app, h, icon, invoke, bytes, pct, orb, ticker, countUp, onProgress, header, notice, empty, button, badge, checkbox, revealBtn,
  confirmDialog, toast, trashItems, trashSummary, ring, mapIcon, tilde } from './core.js';
import { categoryModule, rerender, runScan, runClean } from './kit.js';
import { reviewDelete, deleteSummary, trashRun } from './deleter.js';

// ------------------------------------------------------------------ system junk

function trashButton() {
  const b = button('Corbeille', async () => {
    const ok = await confirmDialog('Vider définitivement la Corbeille ?', 'C\'est la seule action irréversible de Purgo : les fichiers seront supprimés pour de bon.', [{ label: 'Vider la Corbeille', kind: 'danger' }]);
    if (!ok) return;
    try { await invoke('empty_trash'); toast('Corbeille vidée'); paint(); } catch (e) { toast(String(e), 'err'); }
  }, { icon: 'trash' });
  const paint = () => invoke('trash_info').then((t) => {
    const label = t.size != null ? `Corbeille · ${bytes(t.size)}` : t.count != null ? `Corbeille · ${t.count} élément(s)` : 'Corbeille';
    b.lastChild.textContent = label;
  }).catch(() => {});
  paint();
  return b;
}

export const junk = categoryModule({
  id: 'junk', title: 'Nettoyage système', icon: 'trash', tint: '#14b8a6',
  subtitle: 'Caches, journaux, fichiers temporaires, installeurs et fichiers de développement inutiles.',
  scanCmd: 'scan_junk', scanningText: 'Recherche des fichiers inutiles…',
  emptyTitle: 'Fais de la place',
  emptyMessage: 'Purgo repère les fichiers temporaires que le système et tes applications accumulent. Tout part dans la Corbeille : rien n\'est perdu tant que tu ne la vides pas.',
  trailing: () => [trashButton()],
});

// ------------------------------------------------------------------ privacy

export const privacy = categoryModule({
  id: 'privacy', title: 'Confidentialité', icon: 'lock', tint: '#0ea5a4',
  subtitle: 'Historique, cookies et traces de navigation de tes navigateurs et du système.',
  scanCmd: 'scan_privacy', scanningText: 'Recherche des traces de navigation…', actionTitle: 'Effacer',
  emptyTitle: 'Protège ta vie privée',
  emptyMessage: 'Efface l\'historique, les cookies et les caches de Chrome, Edge, Brave, Firefox, Opera, Vivaldi, Safari et les traces du système.',
  renderCats: (m, paintBar) => h('div.scroll.stack', m.st.cats.map((c) => {
    const running = c.items.some((i) => i.badges?.some((b) => b.text === 'Navigateur ouvert'));
    return h('div.card',
      h('div', { style: { display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '8px' } },
        icon('globe', 18), h('b', c.name), running ? badge('Ouvert', 'orange') : null, h('div.spacer'),
        running ? button(`Quitter ${c.name}`, async () => { await invoke('quit_browser', { id: c.id }); setTimeout(() => m.scan(), 1500); }, { kind: 'small' }) : null),
      c.info ? h('p', c.info) : null,
      c.items.map((i) => h('div.row', checkbox(i.selected, (v) => { i.selected = v; paintBar(); }, running),
        icon(mapIcon(i.meta?.icon || 'eye'), 16), h('div.row-main', i.name), h('span.size', bytes(i.size)))));
  })),
});

// ------------------------------------------------------------------ security

export const security = {
  id: 'security', title: 'Sécurité', icon: 'shield', tint: '#22a35a',
  st: { report: null },
};
security.scan = async () => {
  const r = await runScan(security, { text: 'Analyse de sécurité en cours…', cmd: 'scan_security', showBytes: false });
  security.st.report = r || { threats: [] };
  rerender(security);
};
security.remove = async () => {
  const sel = security.st.report.threats.filter((t) => t.selected).map((t) => ({ ...t, group: t.detail.split(' · ').pop() }));
  if (!sel.length) return;
  const r = await reviewDelete({ title: 'Neutraliser les menaces', items: sel, run: threatRun, mode: 'remove',
    note: 'Les fichiers vont dans la Corbeille ; les entrées de démarrage et les tâches planifiées sont retirées.' });
  if (!r) return;
  security.st.result = deleteSummary(r);
  security.st.report.threats = security.st.report.threats.filter((t) => !r.doneIds.has(t.id));
  rerender(security);
};
security.view = () => {
  const st = security.st;
  const parts = [header(security, 'Adwares connus, démarrages suspects, tâches planifiées, extensions malveillantes et antivirus du système.',
    st.report && !st.scanning ? button('Réanalyser', security.scan, { icon: 'refresh' }) : null)];
  if (st.result) parts.push(notice(st.result));
  if (st.scanning || st.cleaning) return [...parts, st.scan.el];
  if (!st.report) return [...parts, empty({ icon: 'shield', title: 'Analyse de sécurité',
    message: 'Purgo vérifie ce qui se lance tout seul, les tâches planifiées, tes extensions de navigateur et les logiciels indésirables connus, et te montre l\'état de l\'antivirus du système.', action: 'Analyser', onAction: security.scan })];
  const r = st.report;
  parts.push(h('div.cards', h('div.card', h('h4', icon('shield', 18), 'Protection du système'),
    h('p', r.antivirus || '—'), r.antivirus_ok === false ? badge('À vérifier', 'orange') : r.antivirus_ok ? badge('Actif', 'green') : null,
    r.can_scan ? h('div', { style: { marginTop: '8px' } }, button(app.os === 'windows' ? 'Analyse rapide Defender' : 'Analyser les Téléchargements', async (e) => {
      e.target.disabled = true; e.target.textContent = 'Analyse en cours…';
      try { const out = await invoke('antivirus_scan'); await confirmDialog('Résultat de l\'analyse', out, []); } catch (er) { toast(String(er), 'err'); }
      e.target.disabled = false; e.target.textContent = 'Relancer l\'analyse';
    }, { kind: 'small' })) : null)));
  if (!r.threats.length) return [...parts, empty({ icon: 'check', title: 'Aucune menace détectée', message: 'Rien de suspect au démarrage, dans les tâches planifiées ni dans tes extensions.' })];
  const bar = h('div');
  const paint = () => {
    const n = r.threats.filter((t) => t.selected).length;
    bar.replaceChildren(h('footer.action-bar', h('span.ab-text', `${n} élément(s) sélectionné(s)`), h('div.spacer'), button('Supprimer', () => security.remove(), { kind: 'danger', disabled: !n })));
  };
  paint();
  parts.push(h('div.list', r.threats.map((t) => h('div.row', checkbox(t.selected, (v) => { t.selected = v; paint(); }),
    icon(t.meta.severity === 'info' ? 'eye' : 'warn', 18, ''),
    h('div.row-main', h('div.row-name', h('b', t.name), ...t.badges.map((b) => badge(b.text, b.color))), h('div.row-detail', t.detail),
      t.paths[0] ? h('div.row-detail.mono', tilde(t.paths[0])) : null),
    t.paths[0] ? revealBtn(t.paths[0]) : null))), bar);
  return parts;
};

// ------------------------------------------------------------------ smart scan

const S = { phase: 'idle', steps: {}, cards: 0, freed: 0, cleaned: false, line: null };

export const smart = { id: 'smart', title: 'Analyse intelligente', icon: 'drum', tint: '#2c6bed', st: S };

let statsTimer = null;
smart.onShow = () => {
  clearInterval(statsTimer);
  statsTimer = setInterval(() => { if (app.module !== 'smart') return clearInterval(statsTimer); S.paintStats?.(); }, 3000);
};

async function runSmart() {
  S.phase = 'scanning';
  S.count = null;
  S.cleaned = false;
  S.line = null;
  S.cards = 0;
  S.steps = { junk: 'running', security: 'running', startup: 'running' };
  rerender(smart);
  const offJ = onProgress('junk', (t, b) => { S.tick?.set(t); S.orb?.lo.feed(t); if (b) countUp(S.count, b, { duration: 500 }); });
  const offS = onProgress('security', (t) => { if (S.steps.junk === 'done') { S.tick?.set(t); S.orb?.lo.feed(t); } });
  const done = (k) => { S.steps[k] = 'done'; S.paintSteps?.(); };
  // keep the drum turning (and the water rising) long enough to be seen
  const minSpin = new Promise((r) => setTimeout(r, app.settings.reduce_motion ? 0 : 5200));
  const loader = setInterval(() => S.orb?.lo.feed('·'), 700);
  await Promise.all([
    minSpin,
    invoke('scan_junk').then((c) => { junk.st.cats = c; done('junk'); }),
    invoke('scan_security').then((r) => { security.st.report = r; done('security'); }),
    invoke('startup_list').then((l) => { S.startup = l; done('startup'); }),
  ]).catch((e) => toast(String(e), 'err'));
  clearInterval(loader);
  offJ(); offS();
  await new Promise((r) => setTimeout(r, 450));
  S.phase = 'done';
  rerender(smart);
}

const threatRun = async (t) => {
  const [ok, errs] = await invoke('remove_threats', { items: [t] });
  return { freed: 0, error: ok ? null : (errs[0] || 'Impossible à retirer') };
};

async function cleanSmart() {
  const junkItems = (junk.st.cats || []).flatMap((c) => c.items.filter((i) => i.selected).map((i) => ({ ...i, group: c.name, kind: 'file' })));
  const threats = (security.st.report?.threats || []).filter((t) => t.selected).map((t) => ({ ...t, group: 'Menaces', kind: 'threat' }));
  const before = (await invoke('system_stats')).disk_free;
  let freedLive = 0;
  const r = await reviewDelete({
    title: 'Nettoyer et protéger',
    subtitle: 'Voici tout ce que Purgo va retirer. Décoche ce que tu veux garder.',
    items: [...threats, ...junkItems],
    note: 'Réduis cette fenêtre pour voir la machine essorer.',
    run: (i) => (i.kind === 'threat' ? threatRun(i) : trashRun(i)),
    onStart: () => { S.phase = 'cleaning'; S.count = null; rerender(smart); },
    onItem: (i, freed) => { freedLive = freed; S.orb?.lo.feed(i.name); S.tick?.set(i.paths?.[0] || i.name); if (S.count) countUp(S.count, freed, { duration: 350 }); },
  });
  if (!r) { if (S.phase === 'cleaning') { S.phase = 'done'; rerender(smart); } return; }
  for (const c of junk.st.cats || []) c.items = c.items.filter((i) => !r.doneIds.has(i.id));
  junk.st.cats = (junk.st.cats || []).filter((c) => c.items.length);
  if (security.st.report) security.st.report.threats = security.st.report.threats.filter((t) => !r.doneIds.has(t.id));
  const after = (await invoke('system_stats')).disk_free;
  S.freed = Math.max(r.freed || freedLive, after - before);
  S.cleaned = true;
  S.line = deleteSummary(r);
  S.phase = 'done';
  rerender(smart);
}

smart.view = () => {
  const junkSel = (junk.st.cats || []).flatMap((c) => c.items).filter((i) => i.selected).reduce((a, i) => a + i.size, 0);
  const junkAll = (junk.st.cats || []).flatMap((c) => c.items).reduce((a, i) => a + i.size, 0);
  const threats = (security.st.report?.threats || []).filter((t) => t.meta.severity !== 'info').length;
  const enabled = (S.startup || []).filter((s) => s.enabled).length;

  const prevCount = S.count?.dataset.v || 0;
  S.count = h('b.count', bytes(prevCount));
  S.count.dataset.v = prevCount;
  let content;
  if (S.phase === 'idle') content = [icon('play', 13), h('b', 'Départ')];
  else if (S.phase === 'scanning') content = [h('span.blink'), S.count];
  else if (S.phase === 'cleaning') content = [h('span.blink'), S.count];
  else {
    const n = h('b', bytes(0));
    content = [icon('check', 18, 'bold'), n];
    setTimeout(() => countUp(n, S.cleaned ? S.freed : junkSel, { duration: 1200 }), 50);
  }
  if (!S.orb) S.orb = orb({ size: 300, onClick: runSmart, machine: true });
  S.orb.set(S.phase, content);
  const o = S.orb;
  const headline = { idle: 'Prêt pour une analyse intelligente', scanning: 'Analyse de ton ordinateur…', cleaning: 'Nettoyage et protection…', done: S.cleaned ? 'Ton ordinateur est tout propre ✨' : 'Analyse terminée' }[S.phase];

  const kids = [o, h('h2', headline)];
  if (S.phase === 'scanning' || S.phase === 'cleaning') {
    S.tick = ticker();
    kids.push(S.tick);
  } else if (S.line) kids.push(h('div.sub', S.line));
  else if (S.phase === 'idle') {
    kids.push(h('div.sub', 'Nettoyage, protection et vitesse en une seule analyse.'));
    if (app.settings.lifetime_freed > 0) kids.push(h('div.trophy', icon('trophy', 16), `Purgo t'a déjà fait gagner ${bytes(app.settings.lifetime_freed)}`));
  }

  if (S.phase === 'scanning') {
    const steps = h('div.steps');
    S.paintSteps = () => steps.replaceChildren(...[['junk', 'Fichiers inutiles'], ['security', 'Menaces'], ['startup', 'Démarrage']].map(([k, label]) =>
      h('div.step', { class: S.steps[k] }, h('span.dot', S.steps[k] === 'done' ? icon('check', 12, 'bold') : null), label)));
    S.paintSteps();
    kids.push(steps);
  }

  if (S.phase === 'done') {
    const card = (m, value, caption, delay) => h('div.card.lift', { style: { animationDelay: `${delay}s`, '--tint': m.tint } },
      h('h4', icon(m.icon, 18), m.title), h('div.big', value), h('p', caption), button('Voir le détail', () => app.go(m.id), { kind: 'link' }));
    kids.push(h('div.result-cards',
      card(junk, bytes(junkSel), `à nettoyer sur ${bytes(junkAll)} trouvés`, 0.15),
      card(security, threats ? String(threats) : 'Aucune', threats ? 'menace(s) ou élément(s) suspect(s)' : 'menace détectée', 0.3),
      card({ id: 'startup', title: 'Démarrage', icon: 'power', tint: '#e8890c' }, String(enabled), 'éléments lancés automatiquement', 0.45)));
    kids.push(h('div', { style: { display: 'flex', gap: '10px' } }, button('Nouvelle analyse', runSmart),
      !S.cleaned ? button('Nettoyer et protéger', cleanSmart, { kind: 'primary', disabled: !junkSel && !threats }) : null));
  }

  if (S.phase === 'idle') {
    const pills = h('div.pills');
    S.paintStats = async () => {
      try {
        const s = await invoke('system_stats');
        const used = s.disk_total ? 1 - s.disk_free / s.disk_total : 0;
        const pill = (ic, text, v, c) => h('div.pill', ring(v, c), icon(ic, 16), text);
        pills.replaceChildren(
          pill('disk', `${bytes(s.disk_free)} libres`, used, '#8b5cf6'),
          pill('memory', `RAM ${pct(s.mem_used / s.mem_total)}`, s.mem_used / s.mem_total, '#2f7cf6'),
          pill('cpu', `CPU ${Math.round(s.cpu)} %`, s.cpu / 100, '#e8890c'),
          s.battery ? pill('battery', `Batterie ${s.battery.percent} %`, s.battery.percent / 100, '#22a35a') : null);
      } catch {}
    };
    S.paintStats();
    kids.push(pills);
  }
  return h('div.smart', kids);
};
