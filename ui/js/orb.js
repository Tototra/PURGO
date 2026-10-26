// The liquid orb: an iridescent, wobbling sphere drawn on a canvas.
// idle → slow liquid, leans toward the cursor · scanning → orbit rings, file names fall into it
// cleaning → vortex · done → shockwave, sparks, calm crystal.

const TAU = Math.PI * 2;

function hexToRgb(hex) {
  const m = hex.replace('#', '').match(/.{2}/g) || ['80', '80', 'ff'];
  return m.map((x) => parseInt(x, 16));
}
const rgba = ([r, g, b], a) => `rgba(${r},${g},${b},${a})`;
const mix = (a, b, k) => a.map((v, i) => Math.round(v + (b[i] - v) * k));

export class LiquidOrb {
  constructor(size, tint = '#8a5cff') {
    this.size = size;
    this.pad = Math.round(size * 0.55);
    this.full = size + this.pad * 2;
    this.canvas = document.createElement('canvas');
    this.canvas.className = 'orb-canvas';
    this.dpr = Math.min(window.devicePixelRatio || 1, 2);
    this.canvas.width = this.full * this.dpr;
    this.canvas.height = this.full * this.dpr;
    this.canvas.style.width = this.canvas.style.height = `${this.full}px`;
    this.ctx = this.canvas.getContext('2d');
    this.phase = 'idle';
    this.energy = 0;          // smoothed 0..1 activity
    this.spin = 0;
    this.t = Math.random() * 100;
    this.particles = [];
    this.labels = [];
    this.waves = [];
    this.sparks = [];
    this.hover = 0;
    this.lean = { x: 0, y: 0 };
    this.target = { x: 0, y: 0 };
    this.reduce = false;
    this.setTint(tint);
    this.canvas.addEventListener('pointermove', (e) => {
      const r = this.canvas.getBoundingClientRect();
      this.target.x = ((e.clientX - r.left) / r.width - 0.5) * 2;
      this.target.y = ((e.clientY - r.top) / r.height - 0.5) * 2;
    });
    this.canvas.addEventListener('pointerleave', () => { this.target.x = this.target.y = 0; });
    this.wasConnected = false;
    this.last = performance.now();
    this.frame = this.frame.bind(this);
    requestAnimationFrame(this.frame);
  }

  setTint(hex) {
    const t = hexToRgb(hex);
    this.tint = t;
    this.palette = [t, [62, 242, 208], [138, 92, 255], [255, 92, 168], [92, 200, 255], mix(t, [255, 255, 255], 0.5)];
  }

  setPhase(p) {
    if (p === this.phase) return;
    const prev = this.phase;
    this.phase = p;
    if (p === 'done' && prev !== 'idle') this.burst();
  }

  /** A clicked ripple. */
  pulse() {
    this.waves.push({ r: this.size / 2, a: 0.9, w: 6 });
  }

  /** Celebrate: shockwaves and sparks. */
  burst() {
    for (let k = 0; k < 3; k++) this.waves.push({ r: this.size / 2 - k * 18, a: 1, w: 10 - k * 3 });
    for (let i = 0; i < 70; i++) {
      const a = Math.random() * TAU;
      const s = 2 + Math.random() * 7;
      this.sparks.push({ x: Math.cos(a) * this.size * 0.45, y: Math.sin(a) * this.size * 0.45, vx: Math.cos(a) * s, vy: Math.sin(a) * s,
        life: 1, c: this.palette[i % this.palette.length], r: 1.2 + Math.random() * 2.4 });
    }
  }

  /** A file name that drifts into the orb. */
  feed(text) {
    if (!text || this.labels.length > 9) return;
    const name = text.split(/[\\/]/).filter(Boolean).pop() || text;
    const a = Math.random() * TAU;
    const d = this.size / 2 + this.pad * (0.55 + Math.random() * 0.35);
    this.labels.push({ text: name.length > 26 ? name.slice(0, 25) + '…' : name, a, d, life: 1, spin: (Math.random() - 0.5) * 0.6 });
  }

  spawn(n, far) {
    for (let i = 0; i < n; i++) {
      const a = Math.random() * TAU;
      const d = this.size / 2 + (far ? this.pad * (0.4 + Math.random() * 0.6) : 12 + Math.random() * 30);
      this.particles.push({ a, d, v: 0.4 + Math.random() * 1.4, r: 0.8 + Math.random() * 2.2, c: this.palette[(Math.random() * 5) | 0], life: 1 });
    }
  }

  frame(now) {
    const connected = this.canvas.isConnected;
    if (connected) this.wasConnected = true;
    else if (this.wasConnected) return; // removed from the page: stop
    const dt = Math.min(0.05, (now - this.last) / 1000);
    this.last = now;
    if (connected) this.draw(dt);
    requestAnimationFrame(this.frame);
  }

  draw(dt) {
    const c = this.ctx, S = this.full, R = this.size / 2 - 18, cx = S / 2, cy = S / 2;
    const p = this.phase;
    const active = p === 'scanning' ? 1 : p === 'cleaning' ? 1.4 : p === 'done' ? 0.15 : 0.08 + this.hover * 0.25;
    this.energy += (active - this.energy) * Math.min(1, dt * 3);
    const speed = this.reduce ? 0.25 : 1;
    this.t += dt * (0.6 + this.energy * 1.6) * speed;
    this.spin += dt * (p === 'cleaning' ? -3.2 : 0.4 + this.energy * 2.4) * speed;
    this.lean.x += (this.target.x - this.lean.x) * Math.min(1, dt * 4);
    this.lean.y += (this.target.y - this.lean.y) * Math.min(1, dt * 4);
    const t = this.t, E = this.energy;

    c.setTransform(this.dpr, 0, 0, this.dpr, 0, 0);
    c.clearRect(0, 0, S, S);

    // ---- halo
    const halo = c.createRadialGradient(cx, cy, R * 0.6, cx, cy, R * (1.75 + E * 0.25));
    halo.addColorStop(0, rgba(this.tint, 0.42 + E * 0.18));
    halo.addColorStop(0.45, rgba(this.palette[2], 0.12 + E * 0.08));
    halo.addColorStop(1, rgba(this.tint, 0));
    c.fillStyle = halo;
    c.fillRect(0, 0, S, S);

    // ---- orbit rings (tilted ellipses with a bright comet head)
    if (E > 0.12) {
      const alpha = Math.min(1, (E - 0.12) * 1.6);
      for (let k = 0; k < 3; k++) {
        const tilt = [0.32, 0.55, 0.18][k];
        const rot = [0.4, -0.9, 1.6][k] + this.spin * [0.12, -0.08, 0.05][k];
        const rr = R + 22 + k * 16;
        c.save();
        c.translate(cx, cy);
        c.rotate(rot);
        c.scale(1, tilt);
        c.lineWidth = 1.2 / tilt * 0.6;
        c.strokeStyle = rgba(this.palette[k + 1], 0.16 * alpha);
        c.beginPath(); c.arc(0, 0, rr, 0, TAU); c.stroke();
        const head = this.spin * (1.4 + k * 0.5) * (k % 2 ? -1 : 1);
        for (let j = 0; j < 26; j++) {
          const a0 = head - j * 0.045 * (k % 2 ? -1 : 1);
          c.fillStyle = rgba(j === 0 ? [255, 255, 255] : this.palette[k + 1], alpha * (1 - j / 26) * 0.9);
          c.beginPath(); c.arc(Math.cos(a0) * rr, Math.sin(a0) * rr, (2.6 - j * 0.08) / Math.sqrt(tilt), 0, TAU); c.fill();
        }
        c.restore();
      }
    }

    // ---- particles flowing into the orb
    if (p === 'scanning' && Math.random() < 0.6 * speed) this.spawn(1, true);
    if (p === 'cleaning' && Math.random() < speed) this.spawn(3, true);
    if ((p === 'idle' || p === 'done') && this.particles.length < 14 && Math.random() < 0.05) this.spawn(1, false);
    c.globalCompositeOperation = 'lighter';
    for (const q of this.particles) {
      if (p === 'scanning' || p === 'cleaning') {
        const pull = p === 'cleaning' ? 120 : 55;
        q.d -= (pull + q.v * 40) * dt * speed;
        q.a += (p === 'cleaning' ? 2.4 : 0.5) * dt * speed * (1 + 60 / Math.max(q.d, 20));
        if (q.d < R * 0.92) q.life -= dt * 4;
      } else {
        q.a += 0.25 * dt * q.v;
        q.d += Math.sin(t * 2 + q.a * 3) * 0.15;
        q.life -= dt * 0.12;
      }
      const x = cx + Math.cos(q.a) * q.d, y = cy + Math.sin(q.a) * q.d;
      c.fillStyle = rgba(q.c, Math.max(0, q.life) * 0.95);
      c.beginPath(); c.arc(x, y, q.r, 0, TAU); c.fill();
    }
    this.particles = this.particles.filter((q) => q.life > 0 && q.d > 4);

    // ---- file names falling in
    c.globalCompositeOperation = 'source-over';
    c.textAlign = 'center';
    c.textBaseline = 'middle';
    for (const L of this.labels) {
      L.d -= (40 + (this.size / 2 + this.pad - L.d) * 0.9) * dt * speed;
      L.a += L.spin * dt;
      if (L.d < R * 1.05) L.life -= dt * 3.5;
      const x = cx + Math.cos(L.a) * L.d, y = cy + Math.sin(L.a) * L.d;
      const sc = Math.max(0.35, Math.min(1, (L.d - R * 0.8) / (this.pad)));
      c.font = `600 ${11 * sc + 1}px Manrope, system-ui, sans-serif`;
      c.fillStyle = `rgba(238,240,255,${Math.max(0, L.life) * 0.85 * Math.min(1, (this.size / 2 + this.pad - L.d) / 30)})`;
      c.fillText(L.text, x, y);
    }
    this.labels = this.labels.filter((L) => L.life > 0);

    // ---- liquid core (wobbly boundary, plasma inside)
    const ox = this.lean.x * 7, oy = this.lean.y * 7;
    const amp = 0.012 + E * 0.03;
    c.save();
    c.beginPath();
    for (let i = 0; i <= 96; i++) {
      const th = (i / 96) * TAU;
      const rr = R * (1 + amp * Math.sin(3 * th + t * 1.3) + amp * 0.7 * Math.sin(5 * th - t * 0.9) + amp * 0.5 * Math.sin(2 * th + t * 0.6)
        + (p === 'cleaning' ? 0.015 * Math.sin(8 * th - t * 6) : 0));
      const x = cx + Math.cos(th) * rr + ox * 0.3, y = cy + Math.sin(th) * rr + oy * 0.3;
      i ? c.lineTo(x, y) : c.moveTo(x, y);
    }
    c.closePath();
    const base = c.createRadialGradient(cx - R * 0.3, cy - R * 0.35, R * 0.1, cx, cy, R * 1.05);
    base.addColorStop(0, rgba(mix(this.tint, [255, 255, 255], 0.35), 1));
    base.addColorStop(0.55, rgba(this.tint, 1));
    base.addColorStop(1, rgba(mix(this.tint, [10, 6, 30], 0.6), 1));
    c.fillStyle = base;
    c.shadowColor = rgba(this.tint, 0.6);
    c.shadowBlur = 40;
    c.fill();
    c.shadowBlur = 0;
    c.clip();

    // plasma blobs
    c.globalCompositeOperation = 'screen';
    const blobs = 6;
    for (let i = 0; i < blobs; i++) {
      const ph = i * 1.7;
      const sp = 0.5 + i * 0.13;
      const x = cx + Math.cos(t * sp + ph) * R * 0.5 + ox * (1 + i * 0.2);
      const y = cy + Math.sin(t * sp * 1.3 + ph * 1.1) * R * 0.45 + oy * (1 + i * 0.2);
      const rad = R * (0.45 + 0.15 * Math.sin(t * 0.7 + i));
      const g = c.createRadialGradient(x, y, 0, x, y, rad);
      const col = this.palette[(i + 1) % this.palette.length];
      g.addColorStop(0, rgba(col, 0.72 + E * 0.15));
      g.addColorStop(1, rgba(col, 0));
      c.fillStyle = g;
      c.fillRect(cx - R * 1.2, cy - R * 1.2, R * 2.4, R * 2.4);
    }
    // vortex streaks while cleaning
    if (E > 0.6 && p === 'cleaning') {
      c.strokeStyle = 'rgba(255,255,255,0.18)';
      c.lineWidth = 2;
      for (let k = 0; k < 5; k++) {
        c.beginPath();
        for (let s = 0; s < 40; s++) {
          const a = -this.spin * 1.5 + k * (TAU / 5) + s * 0.12;
          const r = R * (1 - s / 44);
          const x = cx + Math.cos(a) * r, y = cy + Math.sin(a) * r;
          s ? c.lineTo(x, y) : c.moveTo(x, y);
        }
        c.stroke();
      }
    }
    // caustic wave band
    c.globalCompositeOperation = 'overlay';
    const band = c.createLinearGradient(cx - R, cy - R + Math.sin(t) * R * 0.3, cx + R, cy + R);
    band.addColorStop(0, 'rgba(255,255,255,0)');
    band.addColorStop(0.5 + 0.2 * Math.sin(t * 0.8), 'rgba(255,255,255,0.35)');
    band.addColorStop(1, 'rgba(255,255,255,0)');
    c.fillStyle = band;
    c.fillRect(cx - R, cy - R, R * 2, R * 2);
    c.restore();

    // glass highlight + rim
    c.globalCompositeOperation = 'source-over';
    const hl = c.createRadialGradient(cx - R * 0.38, cy - R * 0.45, 0, cx - R * 0.38, cy - R * 0.45, R * 0.55);
    hl.addColorStop(0, 'rgba(255,255,255,0.55)');
    hl.addColorStop(1, 'rgba(255,255,255,0)');
    c.fillStyle = hl;
    c.beginPath(); c.ellipse(cx - R * 0.35, cy - R * 0.42, R * 0.5, R * 0.32, -0.6, 0, TAU); c.fill();
    c.strokeStyle = 'rgba(255,255,255,0.35)';
    c.lineWidth = 1.2;
    c.beginPath(); c.arc(cx, cy, R * (1 + amp * 0.5), 0, TAU); c.stroke();

    // ---- shockwaves & sparks
    c.globalCompositeOperation = 'lighter';
    for (const w of this.waves) {
      w.r += 260 * dt; w.a -= dt * 0.9;
      c.strokeStyle = rgba(mix(this.tint, [255, 255, 255], 0.4), Math.max(0, w.a));
      c.lineWidth = w.w * Math.max(0.2, w.a);
      c.beginPath(); c.arc(cx, cy, w.r, 0, TAU); c.stroke();
    }
    this.waves = this.waves.filter((w) => w.a > 0);
    for (const s of this.sparks) {
      s.x += s.vx; s.y += s.vy; s.vx *= 0.94; s.vy *= 0.94; s.life -= dt * 0.8;
      c.fillStyle = rgba(s.c, Math.max(0, s.life));
      c.beginPath(); c.arc(cx + s.x, cy + s.y, s.r * (0.5 + s.life), 0, TAU); c.fill();
    }
    this.sparks = this.sparks.filter((s) => s.life > 0);
    c.globalCompositeOperation = 'source-over';
  }
}
