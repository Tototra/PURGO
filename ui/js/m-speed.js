import { reviewDelete, deleteSummary } from './deleter.js';
import { app, h, icon, invoke, bytes, header, notice, button, badge, checkbox, ring, toast, confirmDialog, tilde, mapIcon, empty } from './core.js';
import { rerender, seg, toggle, busyLine } from './kit.js';

// ------------------------------------------------------------------ monitor

const M = { history: Array(60).fill(0), byMem: false, timer: null };
export const monitor = { id: 'monitor', title: 'Moniteur', icon: 'gauge', tint: '#e8890c', st: M };

function fmtUptime(s) {
  const d = Math.floor(s / 86400), hh = Math.floor((s % 86400) / 3600), mm = Math.floor((s % 3600) / 60);
  return d ? `${d} j ${hh} h` : hh ? `${hh} h ${mm} min` : `${mm} min`;
}

function gauge(value, color, label) {
  const r = ring(value, color, 104, 10);
  const pctEl = h('b', `${Math.round(value * 100)} %`);
  const g = h('div.gauge', r, h('div.label', pctEl, h('small', label)));
  g.update = (v) => { r.update(v); pctEl.textContent = `${Math.round(v * 100)} %`; };
  return g;
}

function drawSpark(canvas, data, color) {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth, hgt = canvas.clientHeight;
  if (!w) return;
  canvas.width = w * dpr; canvas.height = hgt * dpr;
  const c = canvas.getContext('2d');
  c.scale(dpr, dpr);
  const pts = data.map((v, i) => [i / (data.length - 1) * w, hgt - Math.min(1, v) * (hgt - 6) - 3]);
  const grad = c.createLinearGradient(0, 0, 0, hgt);
  grad.addColorStop(0, color + '55'); grad.addColorStop(1, color + '00');
  c.beginPath(); c.moveTo(0, hgt);
  pts.forEach(([x, y]) => c.lineTo(x, y));
  c.lineTo(w, hgt); c.fillStyle = grad; c.fill();
  c.beginPath(); pts.forEach(([x, y], i) => (i ? c.lineTo(x, y) : c.moveTo(x, y)));
  c.strokeStyle = color; c.lineWidth = 2; c.lineJoin = 'round'; c.stroke();
}

monitor.onShow = () => {
  clearInterval(M.timer);
  const tick = async () => {
    if (app.module !== 'monitor') return clearInterval(M.timer);
    try {
      const s = await invoke('system_stats');
      M.history.push(s.cpu / 100); M.history.shift();
      M.paint?.(s);
      M.procs?.();
    } catch {}
  };
  tick();
  M.timer = setInterval(tick, 2000);
};
monitor.onHide = () => clearInterval(M.timer);

monitor.view = () => {
  const cpuG = gauge(0, '#e8890c', 'CPU'), memG = gauge(0, '#2f7cf6', 'RAM'), diskG = gauge(0, '#8b5cf6', 'Disque'), batG = gauge(0, '#22a35a', 'Batterie');
  const spark = h('canvas.spark');
  const memKv = h('div.kv'), diskKv = h('div.kv'), batKv = h('div.kv');
  const uptime = h('span.muted');
  const procList = h('div');
  const kv = (el, rows) => el.replaceChildren(...rows.flatMap(([k, v]) => [h('span', k), h('span', v)]));
  M.paint = (s) => {
    cpuG.update(s.cpu / 100);
    drawSpark(spark, M.history, '#e8890c');
    memG.update(s.mem_used / s.mem_total);
    kv(memKv, [['Utilisée', bytes(s.mem_used)], ['Totale', bytes(s.mem_total)], ['Swap', `${bytes(s.swap_used)} / ${bytes(s.swap_total)}`]]);
    diskG.update(s.disk_total ? 1 - s.disk_free / s.disk_total : 0);
    kv(diskKv, [['Disque', s.disk_name], ['Disponible', bytes(s.disk_free)], ['Capacité', bytes(s.disk_total)]]);
    if (s.battery) {
      batG.update(s.battery.percent / 100);
      kv(batKv, [['État', s.battery.charging ? 'En charge' : s.battery.plugged ? 'Branché' : 'Sur batterie'],
        ['Santé', s.battery.health != null ? `${Math.round(s.battery.health * 100)} %` : '—'], ['Cycles', s.battery.cycles ?? '—']]);
    } else kv(batKv, [['Batterie', 'Aucune (ordinateur de bureau)']]);
    uptime.textContent = `${s.os} · allumé depuis ${fmtUptime(s.uptime)}`;
  };
  M.procs = async () => {
    const list = await invoke('processes', { byMemory: M.byMem });
    procList.replaceChildren(...list.map((p) => h('div.row',
      h('div.row-main', p.name), h('span.size', `${p.cpu.toFixed(1)} %`), h('span.size', bytes(p.mem)),
      h('button.icon-btn', { title: 'Quitter', onclick: async () => {
        const ok = await confirmDialog(`Quitter ${p.name} ?`, 'Les données non enregistrées de cette application peuvent être perdues.', [{ label: 'Quitter', kind: 'danger' }]);
        if (ok) { await invoke('kill_process', { name: p.name }); M.procs(); }
      } }, icon('x', 15)))));
  };
  const freeBtn = app.os !== 'windows' ? button('Libérer la mémoire', async (e) => {
    e.target.disabled = true;
    try { toast(await invoke('free_ram')); } catch (er) { toast(String(er), 'err'); }
    e.target.disabled = false;
  }, { kind: 'small', icon: 'memory' }) : null;
  const procSeg = h('div');
  const paintSeg = () => procSeg.replaceChildren(seg([[false, 'Processeur'], [true, 'Mémoire']], M.byMem, (v) => { M.byMem = v; paintSeg(); M.procs(); }));
  paintSeg();
  return [header(monitor, 'Processeur, mémoire, disque, batterie et applications gourmandes en temps réel.', uptime),
    h('div.mon',
      h('div.card', cpuG, spark),
      h('div.card', memG, h('div', memKv, h('div', { style: { marginTop: '8px' } }, freeBtn))),
      h('div.card', diskG, diskKv),
      h('div.card', batG, batKv),
      h('div.card.procs', h('div', { style: { display: 'flex', alignItems: 'center', marginBottom: '8px' } }, h('b', 'Applications les plus gourmandes'), h('div.spacer'), procSeg), procList))];
};

// ------------------------------------------------------------------ maintenance

const MT = { tasks: null, sel: new Set(), status: {}, out: {}, running: false };
export const maintenance = { id: 'maintenance', title: 'Maintenance', icon: 'wrench', tint: '#f08c00', st: MT };
maintenance.onShow = async () => {
  if (!MT.tasks) { MT.tasks = await invoke('maintenance_tasks'); rerender(maintenance); }
};
maintenance.view = () => {
  const parts = [header(maintenance, 'Les petites réparations qui gardent le système rapide et stable.')];
  if (!MT.tasks) return parts;
  const runSel = async () => {
    MT.running = true;
    for (const t of MT.tasks.filter((t) => MT.sel.has(t.id))) {
      MT.status[t.id] = 'running'; MT.out[t.id] = ''; rerender(maintenance);
      try { MT.out[t.id] = await invoke('run_task', { id: t.id }); MT.status[t.id] = 'done'; }
      catch (e) { MT.out[t.id] = String(e); MT.status[t.id] = 'failed'; }
      rerender(maintenance);
    }
    MT.running = false; rerender(maintenance);
  };
  parts.push(h('div.list', MT.tasks.map((t) => h('div.row',
    checkbox(MT.sel.has(t.id), (v) => { v ? MT.sel.add(t.id) : MT.sel.delete(t.id); rerender(maintenance); }, MT.running),
    h('div.cat-ic', icon(mapIcon(t.icon), 18)),
    h('div.row-main', h('div.row-name', h('b', t.name), t.admin ? badge('Droits administrateur', 'gray') : null),
      h('div.row-detail', { style: { whiteSpace: 'normal' } }, t.info),
      MT.out[t.id] ? h('div.row-detail.mono', { style: { whiteSpace: 'pre-wrap' } }, MT.out[t.id].slice(-300)) : null),
    MT.status[t.id] === 'running' ? h('span.spinner') : MT.status[t.id] === 'done' ? h('span', { style: { color: 'var(--green)' } }, icon('check', 20, 'bold')) : MT.status[t.id] === 'failed' ? h('span', { style: { color: 'var(--red)' } }, icon('x', 20, 'bold')) : null))));
  parts.push(h('footer.action-bar', h('span.ab-text', `${MT.sel.size} tâche(s) sélectionnée(s)`), h('div.spacer'),
    button(MT.running ? 'En cours…' : 'Exécuter', runSel, { kind: 'primary', disabled: !MT.sel.size || MT.running })));
  return parts;
};

// ------------------------------------------------------------------ startup

const SU = { items: null, busy: null };
export const startup = { id: 'startup', title: 'Démarrage', icon: 'power', tint: '#e8590c', st: SU };
const loadStartup = async () => { SU.items = await invoke('startup_list'); rerender(startup); };
startup.onShow = () => { if (!SU.items) loadStartup(); };
startup.view = () => {
  const parts = [header(startup, 'Ce qui se lance tout seul au démarrage et ralentit ton ordinateur.',
    button('Réglages du système', () => invoke('open_startup_settings'), { icon: 'external' }), button('Actualiser', loadStartup, { icon: 'refresh' }))];
  if (SU.busy) parts.push(busyLine(SU.busy));
  if (!SU.items) return [...parts, h('div.empty', h('span.spinner'))];
  if (!SU.items.length) return [...parts, empty({ icon: 'check', title: 'Rien ne se lance au démarrage', message: 'Ton démarrage est déjà léger.' })];
  const groups = [...new Set(SU.items.map((i) => i.group))];
  const act = async (label, cmd, args) => {
    SU.busy = label; rerender(startup);
    try { await invoke(cmd, args); } catch (e) { toast(String(e), 'err'); }
    SU.busy = null; await loadStartup();
  };
  parts.push(h('div.list', groups.map((g) => [h('div.section-title', `${g} (${SU.items.filter((i) => i.group === g).length})`),
    SU.items.filter((i) => i.group === g).map((i) => h('div.row',
      h('div.cat-ic', icon(i.kind.startsWith('systemd') || i.kind.startsWith('launchd') ? 'gear' : 'power', 16)),
      h('div.row-main', h('div.row-name', h('b', i.name), i.enabled ? null : badge('Désactivé', 'gray')),
        h('div.row-detail', tilde(i.command || i.location))),
      i.can_toggle ? toggle(i.enabled, (v) => act(v ? `Activation de ${i.name}…` : `Désactivation de ${i.name}…`, 'startup_toggle', { id: i.id, on: v })) : null,
      i.path ? h('button.icon-btn', { title: 'Afficher', onclick: () => invoke('reveal', { path: i.path }) }, icon('search', 15)) : null,
      i.can_remove ? h('button.icon-btn', { title: 'Retirer du démarrage', onclick: async () => {
        const r = await reviewDelete({ title: `Retirer ${i.name} du démarrage`, subtitle: 'L\'application elle-même n\'est pas désinstallée.', mode: 'remove', action: 'Retirer',
          items: [{ id: i.id, name: i.name, detail: i.command || i.location, size: 0, group: i.group }],
          run: async () => { try { await invoke('startup_remove', { id: i.id }); return { freed: 0 }; } catch (e) { return { freed: 0, error: String(e) }; } } });
        if (r) loadStartup();
      } }, icon('trash', 15)) : null))])));
  return parts;
};
