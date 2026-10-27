import { Drum } from './js/drum.js';

const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;

// ------------------------------------------------------------------ the machine
const host = document.getElementById('machine');
const hint = document.getElementById('hint');
const width = Math.min(400, Math.max(260, document.documentElement.clientWidth - 64));
const drum = new Drum(width, '#2c6bed', { machine: true });
drum.reduce = reduce;
host.append(drum.canvas);

const m = drum.layout();
const w = m.x1 - m.x0, bh = m.pb - m.y0;
const display = document.createElement('div');
display.className = 'display';
Object.assign(display.style, {
  left: `${m.x0 + w * 0.57}px`, width: `${w * 0.43 - 16}px`,
  top: `${m.y0 + bh * 0.2}px`, height: `${bh * 0.6}px`,
  fontSize: `${Math.round(width / 25)}px`,
});
host.append(display);

const show = (html) => { display.innerHTML = html; };
show('&#9655; Départ');

let state = 'idle', timer = null;
function run() {
  if (state === 'running') return;
  if (state === 'done') {
    state = 'idle';
    drum.setPhase('idle');
    show('&#9655; Départ');
    hint.textContent = 'Appuie sur Départ pour relancer un cycle.';
    return;
  }
  state = 'running';
  drum.pulse();
  drum.setPhase('scanning');
  hint.textContent = 'Le tambour tourne, l\'eau monte avec l\'avancement.';
  const total = reduce ? 1500 : 6500;
  const t0 = performance.now();
  timer = setInterval(() => {
    const p = Math.min(1, (performance.now() - t0) / total);
    drum.setProgress(p);
    drum.feed('x');
    show(`<span class="dot"></span>${Math.round(p * 100)} %`);
    if (p >= 1) {
      clearInterval(timer);
      state = 'done';
      drum.setPhase('done');
      show('&#10003; Propre');
      hint.textContent = 'Cycle terminé. Dans l\'app, tu verrais maintenant tout ce qui a été trouvé.';
    }
  }, 120);
}
host.addEventListener('click', run);
host.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); run(); } });
host.addEventListener('pointerenter', () => (drum.hover = 1));
host.addEventListener('pointerleave', () => (drum.hover = 0));

// ------------------------------------------------------------------ downloads
const REPO = 'Tototra/PURGO';
const fmt = (n) => (n >= 1e6 ? `${(n / 1e6).toFixed(n >= 1e7 ? 0 : 1).replace('.', ',')} Mo` : `${Math.round(n / 1e3)} ko`);

async function detectOS() {
  const ua = navigator.userAgent;
  const plat = navigator.userAgentData?.platform || navigator.platform || '';
  if (/android|iphone|ipad/i.test(ua)) return { os: null };
  if (/win/i.test(plat) || /windows/i.test(ua)) return { os: 'windows' };
  if (/mac/i.test(plat) || /mac os x/i.test(ua)) {
    let arm = true;
    try {
      const v = await navigator.userAgentData?.getHighEntropyValues?.(['architecture']);
      if (v?.architecture) arm = v.architecture === 'arm';
      else {
        const gl = document.createElement('canvas').getContext('webgl');
        const ext = gl?.getExtension('WEBGL_debug_renderer_info');
        const r = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : '';
        if (/intel|amd|radeon/i.test(r)) arm = false;
      }
    } catch {}
    return { os: 'mac', arm };
  }
  if (/linux|x11/i.test(plat + ua)) return { os: 'linux' };
  return { os: null };
}

const LABEL = { windows: 'Télécharger pour Windows', linux: 'Télécharger pour Linux', mac: 'Télécharger pour macOS' };

async function setupDownloads() {
  const files = [...document.querySelectorAll('.file')];
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } });
    if (r.ok) {
      const rel = await r.json();
      document.getElementById('version').textContent = rel.tag_name;
      for (const a of files) {
        const asset = rel.assets.find((x) => x.name.endsWith(a.dataset.asset) && !x.name.endsWith('.tar.gz'));
        if (asset) { a.href = asset.browser_download_url; a.querySelector('em').textContent = fmt(asset.size); }
      }
    }
  } catch {}

  const { os, arm } = await detectOS();
  if (!os) return;
  const card = document.querySelector(`.os[data-os="${os}"]`);
  card.classList.add('here');
  let pick = card.querySelector('.file');
  if (os === 'mac' && arm === false) {
    pick = card.querySelector('[data-asset="x64.dmg"]');
    card.prepend(card.querySelector('h3'));
    card.querySelector('p').after(pick);
  }
  const main = document.getElementById('main-dl');
  main.href = pick.href;
  main.textContent = LABEL[os];
  // keep the button pointing at the freshest link once the API answered
  new MutationObserver(() => (main.href = pick.href)).observe(pick, { attributes: true, attributeFilter: ['href'] });
  if (os === 'mac') document.querySelector('.facts').textContent = `Version pour Mac ${pick.querySelector('b').textContent}. Gratuit et open source, environ 3 Mo.`;
}
setupDownloads();
