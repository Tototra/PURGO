// Interaction effects: the program indicator in the control panel and staggered entrances.

const reduce = () => document.body.classList.contains('reduce-motion') || matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Slides the program indicator next to the active item. */
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
  for (const el of root.querySelectorAll('.row, .cat, .card, .pill, .step')) {
    if (i > 28) break;
    el.style.setProperty('--i', i++);
  }
}

export function installFx() {
  window.addEventListener('resize', () => moveNavIndicator(false));
}
