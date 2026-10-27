// The drum: Purgo's porthole. Flat shapes only, a little physics.
// idle → still drum, calm water · scanning → the drum turns, found files tumble inside
// cleaning → spin cycle, files pinned to the wall then drained · done → drum settles, bubbles.

const TAU = Math.PI * 2;
const CHIP_COLORS = ['#2c6bed', '#f2b705', '#27a567', '#e5484d', '#8e5cd9', '#f07c2a', '#14a3b8'];

export class Drum {
  constructor(size, tint = '#2c6bed', opts = {}) {
    this.machine = !!opts.machine;
    if (this.machine) {
      // size = machine width; the porthole sits under the control panel
      this.mw = size;
      this.mh = Math.round(size * 1.18);
      const m = this.layout();
      this.size = Math.floor(Math.min((m.x1 - m.x0) * 0.8, (m.y1 - m.pb) * 0.9));
    } else {
      this.size = this.mw = this.mh = size;
    }
    this.canvas = document.createElement('canvas');
    this.canvas.className = 'drum-canvas';
    this.dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.canvas.width = this.mw * this.dpr;
    this.canvas.height = this.mh * this.dpr;
    this.canvas.style.width = `${this.mw}px`;
    this.canvas.style.height = `${this.mh}px`;
    this.dial = 0;
    this.progress = null; // 0..1 when the task reports it, null → estimated
    this.autoP = 0;
    this.vib = { x: 0, y: 0, r: 0 };
    this.ctx = this.canvas.getContext('2d');
    this.phase = 'idle';
    this.angle = 0;
    this.omega = 0;
    this.settle = 0;
    this.shake = 0;
    this.level = 0.12;
    this.slosh = 0;
    this.t = 0;
    this.hover = 0;
    this.reduce = false;
    this.chips = [];
    this.bubbles = [];
    this.tint = tint;
    for (let i = 0; i < 4; i++) this.addChip(null, true);
    this.wasConnected = false;
    this.last = performance.now();
    this.frame = this.frame.bind(this);
    requestAnimationFrame(this.frame);
  }

  layout() {
    const x0 = 4, x1 = this.mw - 4, y0 = 6, y1 = this.mh - 16;
    return { x0, x1, y0, y1, pb: y0 + (y1 - y0) * 0.19 };
  }

  center() {
    if (!this.machine) return [this.size / 2, this.size / 2];
    const m = this.layout();
    return [this.mw / 2, m.pb + (m.y1 - m.pb) / 2];
  }

  get R() { return this.size / 2 - 4; }
  get G() { return this.R * 0.72; }

  setTint(c) { this.tint = c; }

  setPhase(p) {
    if (p === this.phase) return;
    const prev = this.phase;
    this.phase = p;
    if (p === 'scanning' || p === 'cleaning') { this.progress = null; this.autoP = 0; if (this.dial > TAU - 0.1) this.dial = 0; }
    if (p === 'done' && prev !== 'idle') this.burst();
    if (p === 'scanning') this.chips = this.chips.slice(-4);
  }

  /** Task progress 0..1: drives the water level and the program dial. */
  setProgress(v) { this.progress = Math.max(0, Math.min(1, v)); }

  /** Door "clunk" when the drum is clicked. */
  pulse() { this.shake = 1; }

  burst() {
    this.settle = 0.35;
    for (let i = 0; i < 26; i++) this.bubble(true);
  }

  bubble(anywhere) {
    const G = this.G;
    this.bubbles.push({ x: (Math.random() - 0.5) * G * 1.4, y: anywhere ? G * Math.random() * 0.9 : G * 0.9, r: 2 + Math.random() * 5, v: 20 + Math.random() * 50, life: 1 });
  }

  addChip(_label, resting = false) {
    const G = this.G;
    const kind = ['shirt', 'sock', 'towel', 'shirt'][(Math.random() * 4) | 0];
    const sc = this.size / 300;
    const w = (kind === 'towel' ? 34 : kind === 'sock' ? 12 : 30) * sc * (0.9 + Math.random() * 0.25);
    const h = (kind === 'towel' ? 22 : kind === 'sock' ? 26 : 28) * sc * (0.9 + Math.random() * 0.25);
    const label = null;
    this.chips.push({ kind,
      x: resting ? (Math.random() - 0.5) * G : (Math.random() - 0.5) * G * 0.6,
      y: resting ? G * 0.6 : -G * 0.7,
      vx: (Math.random() - 0.5) * 60, vy: 0, rot: Math.random() * TAU, vr: (Math.random() - 0.5) * 4,
      w, h, label, color: CHIP_COLORS[(Math.random() * CHIP_COLORS.length) | 0], life: 1, age: 0,
    });
    if (this.chips.length > 11) this.chips.shift();
  }

  /** A found file drops into the drum. */
  feed(text) {
    if (!text) return;
    const now = performance.now();
    if (now - (this.lastFeed || 0) < 350) return;
    this.lastFeed = now;
    this.addChip(null);
  }

  frame(now) {
    const connected = this.canvas.isConnected;
    if (connected) this.wasConnected = true;
    else if (this.wasConnected) return;
    const dt = Math.min(0.033, (now - this.last) / 1000);
    this.last = now;
    if (connected) { this.step(dt); this.draw(); }
    requestAnimationFrame(this.frame);
  }

  step(dt) {
    const p = this.phase, G = this.G, k = this.reduce ? 0.3 : 1;
    const target = { idle: 0.25 + this.hover * 0.5, scanning: 3.4, cleaning: 11, done: 0 }[p] * k;
    const acc = p === 'cleaning' ? 2.2 : 3;
    const prevOmega = this.omega;
    this.omega += (target - this.omega) * Math.min(1, dt * acc);
    this.angle += this.omega * dt;
    this.slosh += (((this.omega - prevOmega) / Math.max(dt, 1e-3)) * 0.004 - this.slosh) * Math.min(1, dt * 2);
    // without a real progress value, creep towards 92 % so the drum never looks stuck
    const busy = p === 'scanning' || p === 'cleaning';
    if (busy) this.autoP += (0.92 - this.autoP) * Math.min(1, dt * 0.35);
    const prog = p === 'done' ? 1 : busy ? Math.max(this.progress ?? 0, this.progress == null ? this.autoP : 0) : 0;
    this.prog = prog;
    // water fills with the task: empty-ish at start, full at the end
    const lvl = busy || p === 'done' ? 0.06 + prog * 0.5 : 0.12;
    this.level += (lvl - this.level) * Math.min(1, dt * 2.2);
    this.settle *= Math.pow(0.04, dt);
    this.shake *= Math.pow(0.002, dt);
    this.t += dt;
    if (this.machine) {
      // program knob: 12 o'clock → full turn back to 12 as the task completes
      const dialTarget = this.prog * TAU;
      this.dial += (dialTarget - this.dial) * Math.min(1, dt * (p === 'idle' ? 3 : 5));
      const amp = (p === 'cleaning' ? Math.min(3.2, this.omega * 0.32) : p === 'scanning' ? 0.9 : 0) * k + this.shake * 2 + this.settle * 4;
      this.vib.x = Math.sin(this.t * 53) * amp + Math.sin(this.t * 7.3) * amp * 0.5;
      this.vib.y = Math.abs(Math.sin(this.t * 41)) * -amp * 0.7;
      this.vib.r = p === 'cleaning' ? Math.sin(this.t * 4.1) * amp * 0.35 : Math.sin(this.t * 9) * this.settle * 2;
      const host = this.canvas.parentElement;
      if (host) host.style.transform = `translate(${this.vib.x.toFixed(2)}px, ${this.vib.y.toFixed(2)}px) rotate(${this.vib.r.toFixed(3)}deg)`;
    }

    const g = 900 * (this.size / 300);
    const waterY = G - this.level * G * 2;
    for (const c of this.chips) {
      c.age += dt;
      c.vy += g * dt;
      if (c.y > waterY) { c.vx *= 0.94; c.vy *= 0.9; c.vy -= g * 0.75 * dt; }
      c.x += c.vx * dt;
      c.y += c.vy * dt;
      c.rot += c.vr * dt;
      const lim = G - Math.max(c.w, c.h) * 0.45;
      const d = Math.hypot(c.x, c.y);
      if (d > lim) {
        const nx = c.x / d, ny = c.y / d;
        c.x = nx * lim; c.y = ny * lim;
        const vn = c.vx * nx + c.vy * ny;
        if (vn > 0) { c.vx -= vn * nx * 1.35; c.vy -= vn * ny * 1.35; }
        const tx = -ny, ty = nx;
        const vt = c.vx * tx + c.vy * ty;
        const dv = (this.omega * lim * 1.15 - vt) * Math.min(1, dt * 12);
        c.vx += dv * tx; c.vy += dv * ty;
        c.vr += (this.omega - c.vr) * dt * 3;
      }
      if (p === 'cleaning' && c.age > 0.6) c.life -= dt * 0.9;
    }
    // keep chips from overlapping
    const ch = this.chips;
    for (let i = 0; i < ch.length; i++) {
      for (let j = i + 1; j < ch.length; j++) {
        const a = ch[i], b = ch[j];
        const dx = b.x - a.x, dy = b.y - a.y;
        const dist = Math.hypot(dx, dy) || 0.01;
        const min = (Math.min(a.w, a.h * 2) + Math.min(b.w, b.h * 2)) * 0.42;
        if (dist < min) {
          const push = (min - dist) / 2, nx = dx / dist, ny = dy / dist;
          a.x -= nx * push; a.y -= ny * push; b.x += nx * push; b.y += ny * push;
        }
      }
    }
    this.chips = this.chips.filter((c) => c.life > 0);
    if (p === 'idle' && this.chips.length < 3) this.addChip(null, true);

    if ((p === 'cleaning' || p === 'scanning') && Math.random() < dt * (p === 'cleaning' ? 14 : 3)) this.bubble(false);
    for (const b of this.bubbles) { b.y -= b.v * dt; b.x += Math.sin(this.t * 3 + b.r) * 0.3; b.life -= dt * 0.55; }
    this.bubbles = this.bubbles.filter((b) => b.life > 0 && b.y > -G);
  }

  drawMachine(c) {
    const { x0, x1, y0, y1, pb } = this.layout();
    const w = x1 - x0, p = this.phase;
    // floor shadow & feet
    c.fillStyle = 'rgba(21,25,29,0.10)';
    c.beginPath(); c.ellipse(this.mw / 2, y1 + 9, w * 0.46, 6, 0, 0, TAU); c.fill();
    c.fillStyle = '#2a3037';
    roundRect(c, x0 + 16, y1 - 4, 26, 12, 3); c.fill();
    roundRect(c, x1 - 42, y1 - 4, 26, 12, 3); c.fill();
    // body
    c.fillStyle = '#f7f8f9';
    roundRect(c, x0, y0, w, y1 - y0, 20); c.fill();
    c.lineWidth = 2; c.strokeStyle = '#c3c9cf'; c.stroke();
    // control panel band
    c.save();
    roundRect(c, x0, y0, w, y1 - y0, 20); c.clip();
    c.fillStyle = '#e3e7ea';
    c.fillRect(x0, y0, w, pb - y0);
    c.fillStyle = '#c3c9cf';
    c.fillRect(x0, pb - 1, w, 2);
    // kick plate
    c.fillStyle = '#eceff1';
    c.fillRect(x0, y1 - (y1 - y0) * 0.07, w, (y1 - y0) * 0.07);
    c.fillStyle = '#d5dade';
    c.fillRect(x0, y1 - (y1 - y0) * 0.07, w, 1.5);
    c.restore();
    // detergent drawer
    const bh = pb - y0;
    c.fillStyle = '#d3d9de';
    roundRect(c, x0 + 14, y0 + bh * 0.22, w * 0.27, bh * 0.44, 6); c.fill();
    c.fillStyle = '#b4bcc4';
    roundRect(c, x0 + 14 + w * 0.06, y0 + bh * 0.38, w * 0.15, bh * 0.1, 3); c.fill();
    // program LEDs
    for (let i = 0; i < 5; i++) {
      let on;
      if (p === 'scanning') on = Math.floor(this.t * 5) % 5 === i;
      else if (p === 'cleaning') on = Math.floor(this.t * 6) % 2 === 0;
      else if (p === 'done') on = true;
      else on = i === 0;
      c.fillStyle = on ? (p === 'done' ? '#1f9d5b' : '#ffb000') : '#c3c9cf';
      c.beginPath(); c.arc(x0 + 20 + i * 11, y0 + bh * 0.82, 3, 0, TAU); c.fill();
    }
    // program dial
    const dx = x0 + w * 0.43, dy = y0 + bh * 0.5, dr = bh * 0.33;
    c.strokeStyle = '#9aa3ab'; c.lineWidth = 1.5;
    for (let i = 0; i < 12; i++) {
      const a = -Math.PI / 2 + (i / 12) * TAU;
      c.strokeStyle = i / 12 < this.dial / TAU - 0.001 || (i === 0 && this.dial > TAU - 0.05) ? this.tint : '#9aa3ab';
      c.lineWidth = i % 3 ? 1.5 : 2.5;
      c.beginPath();
      c.moveTo(dx + Math.cos(a) * (dr + 4), dy + Math.sin(a) * (dr + 4));
      c.lineTo(dx + Math.cos(a) * (dr + 8), dy + Math.sin(a) * (dr + 8));
      c.stroke();
    }
    c.fillStyle = '#c3c9cf'; c.beginPath(); c.arc(dx, dy, dr, 0, TAU); c.fill();
    c.fillStyle = '#f2f4f6'; c.beginPath(); c.arc(dx, dy, dr - 4, 0, TAU); c.fill();
    c.strokeStyle = '#15191d'; c.lineWidth = 3; c.lineCap = 'round';
    const da = this.dial - Math.PI / 2;
    c.beginPath(); c.moveTo(dx + Math.cos(da) * dr * 0.2, dy + Math.sin(da) * dr * 0.2); c.lineTo(dx + Math.cos(da) * (dr - 7), dy + Math.sin(da) * (dr - 7)); c.stroke();
  }

  draw() {
    const c = this.ctx, R = this.R, G = this.G;
    let [cx, cy] = this.center();
    if (!this.machine) cx += Math.sin(this.t * 60) * this.shake * 3;
    c.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    c.clearRect(0, 0, this.mw, this.mh);
    if (this.machine) this.drawMachine(c);

    const ring = (r, color) => { c.fillStyle = color; c.beginPath(); c.arc(cx, cy, r, 0, TAU); c.fill(); };
    ring(R, '#c3c9cf');
    ring(R - 5, '#e6e9ec');
    ring(R - 14, '#b0b7bf');
    c.strokeStyle = '#ffffff';
    c.lineWidth = 3;
    c.lineCap = 'round';
    c.beginPath(); c.arc(cx, cy, R - 9.5, Math.PI * 1.08, Math.PI * 1.45); c.stroke();
    ring(G + 12, '#262b31');
    ring(G + 4, '#1a1e23');

    c.save();
    c.beginPath(); c.arc(cx, cy, G, 0, TAU); c.clip();
    c.fillStyle = '#3b434c';
    c.fillRect(cx - G, cy - G, G * 2, G * 2);

    const a = this.angle + Math.sin(this.t * 9) * this.settle;
    c.fillStyle = '#2c333a';
    for (let ri = 0; ri < 4; ri++) {
      const rr = G * (0.3 + ri * 0.2);
      const n = 8 + ri * 6;
      for (let i = 0; i < n; i++) {
        const th = a + (i / n) * TAU + ri * 0.3;
        c.beginPath(); c.arc(cx + Math.cos(th) * rr, cy + Math.sin(th) * rr, 2.6, 0, TAU); c.fill();
      }
    }
    c.fillStyle = '#5d6772';
    for (let i = 0; i < 3; i++) {
      const th = a + (i / 3) * TAU;
      c.save();
      c.translate(cx + Math.cos(th) * (G - 9), cy + Math.sin(th) * (G - 9));
      c.rotate(th);
      roundRect(c, -9, -14, 18, 28, 6);
      c.fill();
      c.restore();
    }

    const water = (offset, alpha) => {
      const base = cy + G - this.level * G * 2;
      const amp = 3 + Math.min(10, Math.abs(this.omega) * 1.4);
      c.globalAlpha = alpha;
      c.fillStyle = this.tint;
      c.beginPath();
      c.moveTo(cx - G, cy + G);
      for (let x = -G; x <= G; x += 6) {
        c.lineTo(cx + x, base + Math.sin(x * 0.045 + this.t * 2.2 + offset) * amp + x * this.slosh * 0.6);
      }
      c.lineTo(cx + G, cy + G);
      c.closePath();
      c.fill();
      c.globalAlpha = 1;
    };
    water(2, 0.45);

    for (const ch of this.chips) {
      c.save();
      c.globalAlpha = Math.max(0, Math.min(1, ch.life));
      c.translate(cx + ch.x, cy + ch.y);
      c.rotate(ch.rot);
      drawCloth(c, ch);
      c.restore();
    }

    water(0, 0.3);

    c.strokeStyle = 'rgba(255,255,255,0.7)';
    c.lineWidth = 1.4;
    for (const b of this.bubbles) {
      c.globalAlpha = Math.max(0, b.life);
      c.beginPath(); c.arc(cx + b.x, cy + b.y, b.r, 0, TAU); c.stroke();
    }
    c.globalAlpha = 1;

    c.strokeStyle = 'rgba(255,255,255,0.22)';
    c.lineWidth = 10;
    c.beginPath(); c.arc(cx, cy, G * 0.78, Math.PI * 1.12, Math.PI * 1.38); c.stroke();
    c.lineWidth = 5;
    c.beginPath(); c.arc(cx, cy, G * 0.78, Math.PI * 1.43, Math.PI * 1.5); c.stroke();
    c.restore();
  }
}

function roundRect(c, x, y, w, h, r) {
  c.beginPath();
  c.moveTo(x + r, y);
  c.arcTo(x + w, y, x + w, y + h, r);
  c.arcTo(x + w, y + h, x, y + h, r);
  c.arcTo(x, y + h, x, y, r);
  c.arcTo(x, y, x + w, y, r);
  c.closePath();
}

/** Flat laundry: t-shirt, sock or striped towel. */
function drawCloth(c, ch) {
  const w = ch.w, h = ch.h;
  c.fillStyle = ch.color;
  if (ch.kind === 'shirt') {
    c.beginPath();
    c.moveTo(-w * 0.18, -h / 2);
    c.lineTo(-w * 0.5, -h * 0.3);
    c.lineTo(-w * 0.38, -h * 0.08);
    c.lineTo(-w * 0.26, -h * 0.16);
    c.lineTo(-w * 0.26, h / 2);
    c.lineTo(w * 0.26, h / 2);
    c.lineTo(w * 0.26, -h * 0.16);
    c.lineTo(w * 0.38, -h * 0.08);
    c.lineTo(w * 0.5, -h * 0.3);
    c.lineTo(w * 0.18, -h / 2);
    c.quadraticCurveTo(0, -h * 0.28, -w * 0.18, -h / 2);
    c.closePath();
    c.fill();
  } else if (ch.kind === 'sock') {
    c.beginPath();
    c.moveTo(-w / 2, -h / 2);
    c.lineTo(w / 2, -h / 2);
    c.lineTo(w / 2, h * 0.18);
    c.quadraticCurveTo(w / 2, h / 2, w * 0.1, h / 2);
    c.lineTo(-w * 1.1, h / 2);
    c.quadraticCurveTo(-w * 1.5, h * 0.3, -w * 1.1, h * 0.12);
    c.lineTo(-w / 2, h * 0.12);
    c.closePath();
    c.fill();
    c.fillStyle = 'rgba(255,255,255,0.6)';
    c.fillRect(-w / 2, -h / 2, w, h * 0.16);
  } else {
    roundRect(c, -w / 2, -h / 2, w, h, 3);
    c.fill();
    c.fillStyle = 'rgba(255,255,255,0.55)';
    c.fillRect(-w / 2, -h * 0.25, w, h * 0.12);
    c.fillRect(-w / 2, h * 0.12, w, h * 0.12);
  }
}
