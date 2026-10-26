import { app, h, icon, invoke, bytes, button, toast, logo } from './core.js';
import { toggle } from './kit.js';
import { installFx, moveNavIndicator, stagger } from './fx.js';
import * as clean from './m-clean.js';
import * as speed from './m-speed.js';
import * as apps from './m-apps.js';
import * as files from './m-files.js';
import * as dev from './m-dev.js';
import * as storage from './m-storage.js';

const GROUPS = [
  ['', [clean.smart]],
  ['Nettoyage', [clean.junk, clean.privacy]],
  ['Protection', [clean.security]],
  ['Vitesse', [speed.monitor, speed.maintenance, speed.startup]],
  ['Applications', [apps.uninstaller, apps.packages]],
  ['Fichiers', [files.lens, files.large, files.dups]],
  ['Stockage', [storage.cloud, storage.organizer, storage.music, storage.tips]],
  ['Développeurs', [dev.python, dev.node, dev.docker, dev.git, dev.ai]],
];
const ALL = GROUPS.flatMap(([, ms]) => ms);
export const byId = (id) => ALL.find((m) => m.id === id);
app.go = (id) => {
  app.module = id;
  for (const el of document.querySelectorAll('.nav-item')) el.classList.toggle('active', el.dataset.id === id);
  moveNavIndicator(true);
  app.mount(byId(id));
};

const main = document.getElementById('main');

app.mount = (m, animate = true) => {
  main.style.setProperty('--tint', m.tint);
  document.documentElement.style.setProperty('--tint', m.tint);
  const old = main.querySelector('.view');
  const v = h('div.view', { class: animate ? '' : 'noanim', style: animate ? null : { animation: 'none' } }, m.view(m));
  if (old) old.replaceWith(v); else main.append(v);
  if (animate) stagger(v);
  if (animate) m.onShow?.(m);
};

function buildNav() {
  const nav = document.getElementById('nav');
  nav.replaceChildren(...GROUPS.flatMap(([title, ms]) => {
    const visible = ms.filter((m) => !m.os || m.os.includes(app.os));
    if (!visible.length) return [];
    return [title ? h('h6', title) : null, ...visible.map((m) =>
      h('div.nav-item', { 'data-id': m.id, class: app.module === m.id ? 'active' : '', style: { '--tint': m.tint }, onclick: () => { if (app.module !== m.id) { const prev = byId(app.module); prev?.onHide?.(prev); app.go(m.id); } } },
        icon(m.icon, 18), h('span', m.navTitle || m.title)))];
  }));
}

async function openSettings() {
  const s = await invoke('get_settings');
  let auto = false;
  try { auto = await invoke('autostart_get'); } catch {}
  const save = (patch) => invoke('set_settings', { patch }).then((r) => { app.settings = r; document.body.classList.toggle('reduce-motion', !!r.reduce_motion); });
  const gbLabel = h('b', `${Math.round(s.alert_gb)} Go`);
  const close = () => bg.remove();
  const bg = h('div.modal-bg', { onclick: (e) => e.target === bg && close() },
    h('div.modal',
      h('h3', 'Réglages de Purgo'),
      h('div.settings-row', h('div', 'Me prévenir quand le disque est presque plein', h('small', 'Une notification quand l\'espace libre passe sous le seuil.')), toggle(s.alerts_enabled, (v) => save({ alerts_enabled: v }))),
      h('div.settings-row', h('div', 'Seuil d\'alerte ', gbLabel),
        h('input', { type: 'range', min: 5, max: 50, step: 5, value: s.alert_gb, oninput: (e) => (gbLabel.textContent = `${e.target.value} Go`), onchange: (e) => save({ alert_gb: Number(e.target.value) }) })),
      h('div.settings-row', h('div', 'Nettoyer les caches et journaux chaque semaine', h('small', 'En arrière-plan, tant que Purgo tourne (même fenêtre fermée).')), toggle(s.auto_clean, (v) => save({ auto_clean: v }))),
      h('div.settings-row', h('div', 'Lancer Purgo au démarrage', h('small', 'Il reste discret dans la zone de notification pour surveiller le disque.')),
        toggle(auto, (v) => invoke('autostart_set', { on: v }).catch((e) => toast(String(e), 'err')))),
      h('div.settings-row', h('div', 'Réduire les animations', h('small', 'Pour les ordinateurs plus anciens ou par confort.')), toggle(!!s.reduce_motion, (v) => save({ reduce_motion: v }))),
      h('div.settings-row', h('div', 'Espace récupéré grâce à Purgo'), h('b', bytes(s.lifetime_freed))),
      h('p', { style: { marginTop: '12px', fontSize: '12px' } }, 'Purgo signale aussi quand une version de Python disparaît (après une mise à jour), car tes environnements virtuels peuvent casser.'),
      h('div.modal-btns', button('Fermer', close, { kind: 'primary' }))));
  document.body.append(bg);
}

async function start() {
  document.getElementById('logo').append(logo(32));
  try {
    const p = await invoke('platform_info');
    Object.assign(app, p);
    app.settings = await invoke('get_settings');
  } catch (e) {
    console.error(e);
  }
  document.body.classList.add(`os-${app.os}`);
  document.body.classList.toggle('reduce-motion', !!app.settings.reduce_motion);
  const foot = document.getElementById('side-foot');
  foot.append(button('Réglages', openSettings, { icon: 'gear' }));
  buildNav();
  installFx();
  app.go('smart');
  requestAnimationFrame(() => moveNavIndicator(false));
}

start();
