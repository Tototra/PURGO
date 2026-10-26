// Interaction effects: liquid nav indicator, 3D tilt, ripples, cursor light, staggered entrances.

const reduce = () => document.body.classList.contains('reduce-motion') || matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Moves the glowing pill behind the active sidebar item (spring-like via CSS). */
export function moveNavIndicator(animate = true) {
  const nav = document.getElementById('nav');
  const active = nav?.querySelector('.nav-item.active');
  let ind = nav?.querySelector('.nav-ind');
  if (!nav) return;
  if (!ind) {
    ind = document.createElement('div');
    ind.className = 'nav-ind';
    nav.prepend(ind);
  }
  if (!active) { ind.style.opacity = 0; return; }
  if (!animate) ind.style.transition = 'none';
  ind.style.opacity = 1;
  ind.style.transform = `translateY(${active.offsetTop}px)`;
  ind.style.height = `${active.offsetHeight}px`;
  ind.style.setProperty('--tint', active.style.getPropertyValue('--tint'));
  if (!animate) requestAnimationFrame(() => (ind.style.transition = ''));
}

/** Gives rows/cards an index so CSS can cascade their entrance. */
export function stagger(root) {
  if (reduce()) return;
  let i = 0;
  for (const el of root.querySelectorAll('.row, .cat, .card, .pill, .step, .chip')) {
    if (i > 28) break;
    el.style.setProperty('--i', i++);
  }
}

export function installFx() {
  // cursor light in the main area
  const main = document.getElementById('main');
  main.addEventListener('pointermove', (e) => {
    const r = main.getBoundingClientRect();
    main.style.setProperty('--mx', `${e.clientX - r.left}px`);
    main.style.setProperty('--my', `${e.clientY - r.top}px`);
  });

  // 3D tilt + glare on cards
  let tilted = null;
  document.addEventListener('pointermove', (e) => {
    if (reduce()) return;
    const card = e.target.closest?.('.card.lift, .pill');
    if (tilted && tilted !== card) { tilted.style.setProperty('--rx', '0deg'); tilted.style.setProperty('--ry', '0deg'); tilted.classList.remove('tilting'); }
    tilted = card;
    if (!card) return;
    const r = card.getBoundingClientRect();
    const x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;
    const k = card.classList.contains('pill') ? 10 : 7;
    card.classList.add('tilting');
    card.style.setProperty('--rx', `${(0.5 - y) * k}deg`);
    card.style.setProperty('--ry', `${(x - 0.5) * k}deg`);
    card.style.setProperty('--gx', `${x * 100}%`);
    card.style.setProperty('--gy', `${y * 100}%`);
  });

  // ripple on buttons
  document.addEventListener('pointerdown', (e) => {
    const b = e.target.closest?.('.btn, .nav-item, .seg button');
    if (!b || b.disabled || reduce()) return;
    const r = b.getBoundingClientRect();
    const s = document.createElement('span');
    s.className = 'ripple';
    const d = Math.max(r.width, r.height) * 2.2;
    s.style.width = s.style.height = `${d}px`;
    s.style.left = `${e.clientX - r.left - d / 2}px`;
    s.style.top = `${e.clientY - r.top - d / 2}px`;
    b.append(s);
    setTimeout(() => s.remove(), 650);
  });

  // magnetic primary buttons
  document.addEventListener('pointermove', (e) => {
    if (reduce()) return;
    for (const b of document.querySelectorAll('.btn.primary')) {
      const r = b.getBoundingClientRect();
      const dx = e.clientX - (r.left + r.width / 2), dy = e.clientY - (r.top + r.height / 2);
      const dist = Math.hypot(dx, dy);
      if (dist < 90 && !b.disabled) b.style.translate = `${dx * 0.12}px ${dy * 0.18}px`;
      else if (b.style.translate) b.style.translate = '';
    }
  });

  window.addEventListener('resize', () => moveNavIndicator(false));
}
