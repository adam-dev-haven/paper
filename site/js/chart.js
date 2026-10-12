/**
 * Hand-rolled SVG charts. No library, no build step, no 300KB of bundle.
 *
 * Two axes, two units, and the difference is load-bearing. The equity curve is
 * the account, which is kept in dollars and is labelled in dollars — that `$` is
 * correct and deliberate. The price chart is an instrument, which is quoted in
 * whatever its exchange quotes it in, and goes through `price()`.
 */

import { price } from './format.js';

const NS = 'http://www.w3.org/2000/svg';

function el(name, attrs = {}) {
  const n = document.createElementNS(NS, name);
  for (const [k, v] of Object.entries(attrs)) if (v != null) n.setAttribute(k, String(v));
  return n;
}

function path(points, close, y0) {
  if (!points.length) return '';
  let d = `M ${points[0][0].toFixed(2)} ${points[0][1].toFixed(2)}`;
  for (let i = 1; i < points.length; i++) d += ` L ${points[i][0].toFixed(2)} ${points[i][1].toFixed(2)}`;
  if (close) d += ` L ${points[points.length - 1][0].toFixed(2)} ${y0} L ${points[0][0].toFixed(2)} ${y0} Z`;
  return d;
}

/** A sparkline sized for a table cell. Coloured by net direction over the window. */
export function sparkline(values, { w = 74, h = 24, pad = 2 } = {}) {
  const svg = el('svg', { class: 'spark', viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: 'none' });
  const vals = values.filter((v) => v != null && isFinite(v));
  if (vals.length < 2) return svg;

  const min = Math.min(...vals);
  const max = Math.max(...vals);
  const span = max - min || 1;
  const pts = vals.map((v, i) => [
    (i / (vals.length - 1)) * w,
    h - pad - ((v - min) / span) * (h - pad * 2),
  ]);

  const rising = vals[vals.length - 1] >= vals[0];
  const color = rising ? 'var(--up)' : 'var(--down)';
  const id = 'sg' + Math.random().toString(36).slice(2, 8);

  const grad = el('linearGradient', { id, x1: '0', y1: '0', x2: '0', y2: '1' });
  grad.append(
    el('stop', { offset: '0%', 'stop-color': color, 'stop-opacity': '0.28' }),
    el('stop', { offset: '100%', 'stop-color': color, 'stop-opacity': '0' }),
  );
  const defs = el('defs');
  defs.append(grad);
  svg.append(defs);
  svg.append(el('path', { d: path(pts, true, h), fill: `url(#${id})` }));
  svg.append(el('path', { d: path(pts), fill: 'none', stroke: color, 'stroke-width': 1.4, 'stroke-linejoin': 'round', 'vector-effect': 'non-scaling-stroke' }));
  return svg;
}

/**
 * The equity curve. The baseline is starting capital, so being under water is
 * visible as red area below the line rather than as a number you have to read.
 */
export function equityChart(curve, baseline, { h = 200 } = {}) {
  const w = 900;
  const padL = 8, padR = 58, padT = 12, padB = 22;
  const pts = curve.filter((p) => isFinite(p.equity));

  // One reading is not a curve. Collapse to a single line of text rather than
  // reserving a screen's worth of empty chart for it.
  if (pts.length < 2) {
    const svg = el('svg', { viewBox: `0 0 ${w} 44`, preserveAspectRatio: 'none', role: 'img', 'aria-label': 'Portfolio equity over time' });
    const t = el('text', { x: w / 2, y: 26, fill: 'var(--text-faint)', 'font-size': 13, 'text-anchor': 'middle' });
    t.textContent = 'The curve starts after more than one hourly reading.';
    svg.append(t);
    return svg;
  }

  const vals = pts.map((p) => p.equity);
  const last = vals[vals.length - 1];
  const change = baseline ? ((last - baseline) / baseline) * 100 : 0;
  const changeText = (change >= 0 ? '+' : '\u2212') + Math.abs(change).toFixed(2) + '%';

  const svg = el('svg', { viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: 'none', role: 'img',
    'aria-label': `Portfolio equity over time, ${changeText} since the start` });

  // The scale never zooms in tighter than ±2% of starting capital — two full
  // stops at the default risk. Fitted to the data alone, a $3 dip on a $1,000
  // account filled the whole chart and read as a crash.
  const lo = Math.min(...vals, baseline);
  const hi = Math.max(...vals, baseline);
  const mid = (hi + lo) / 2;
  const half = Math.max(((hi - lo) / 2) * 1.14, baseline * 0.02) || 1;
  const min = mid - half, max = mid + half, span = max - min;

  const X = (i) => padL + (i / (pts.length - 1)) * (w - padL - padR);
  const Y = (v) => padT + (1 - (v - min) / span) * (h - padT - padB);

  // Gridlines and the right-hand price scale.
  for (let i = 0; i <= 3; i++) {
    const v = min + (span * i) / 3;
    const y = Y(v);
    svg.append(el('line', { x1: padL, y1: y, x2: w - padR, y2: y, stroke: 'var(--line)', 'stroke-width': 1, 'vector-effect': 'non-scaling-stroke' }));
    const t = el('text', { x: w - padR + 8, y: y + 3.5, fill: 'var(--text-faint)', 'font-size': 10, 'font-family': 'var(--mono)' });
    // Dollars, correctly: this is the account's equity, and the ledger settles
    // in dollars whatever the positions are quoted in.
    t.textContent = '$' + Math.round(v).toLocaleString('en-US');
    svg.append(t);
  }

  // Starting capital — the line the whole exercise is measured against.
  const yBase = Y(baseline);
  svg.append(el('line', { x1: padL, y1: yBase, x2: w - padR, y2: yBase, stroke: 'var(--text-faint)', 'stroke-width': 1, 'stroke-dasharray': '3 4', 'vector-effect': 'non-scaling-stroke', opacity: .65 }));

  const coords = pts.map((p, i) => [X(i), Y(p.equity)]);
  const color = last >= baseline ? 'var(--up)' : 'var(--down)';
  const id = 'eg' + Math.random().toString(36).slice(2, 8);
  const defs = el('defs');
  const grad = el('linearGradient', { id, x1: '0', y1: '0', x2: '0', y2: '1' });
  grad.append(
    el('stop', { offset: '0%', 'stop-color': color, 'stop-opacity': '0.22' }),
    el('stop', { offset: '100%', 'stop-color': color, 'stop-opacity': '0' }),
  );
  defs.append(grad);
  svg.append(defs);
  svg.append(el('path', { d: path(coords, true, h - padB), fill: `url(#${id})` }));
  svg.append(el('path', { d: path(coords), fill: 'none', stroke: color, 'stroke-width': 1.8, 'stroke-linejoin': 'round', 'vector-effect': 'non-scaling-stroke' }));

  const [lx, ly] = coords[coords.length - 1];
  svg.append(el('circle', { cx: lx, cy: ly, r: 3, fill: color }));

  // The move since the start, in words, beside the point it describes — the
  // shape of the line says which way, this says how far.
  const label = el('text', {
    x: lx - 8, y: ly < padT + 18 ? ly + 16 : ly - 9, fill: color,
    'font-size': 11, 'font-family': 'var(--mono)', 'text-anchor': 'end',
  });
  label.textContent = `${changeText} since start`;
  svg.append(label);
  return svg;
}

/**
 * The price chart with the trade plan drawn on it. Seeing entry, target and
 * stop as bands against real price action is the fastest way to understand why
 * the levels sit where they do.
 *
 * `symbol` decides what the axis is denominated in. Every number on this chart —
 * the bars, the entry, the target, the stop — is in the instrument's own
 * currency, so a Stockholm listing draws a kronor axis. The labels used to be
 * built with a hardcoded `$`, which put a dollar sign on a kronor price at the
 * one place in the app where the number is read off a scale rather than a
 * sentence, and where being out by a factor of ten looks exactly like being
 * right.
 */
export function priceChart(bars, { plan, sma20, sma50, symbol, h = 260 } = {}) {
  const w = 900;
  const padL = 8, padR = 62, padT = 12, padB = 24;
  const svg = el('svg', { viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: 'none', role: 'img', 'aria-label': 'Price history with the trade plan overlaid' });
  if (!bars || bars.length < 2) return svg;

  const closes = bars.map((b) => b.c);
  const levels = plan ? [plan.entry, plan.target, plan.stop].filter((n) => isFinite(n)) : [];
  const lo = Math.min(...bars.map((b) => b.l), ...levels);
  const hi = Math.max(...bars.map((b) => b.h), ...levels);
  const pad = (hi - lo) * 0.07 || hi * 0.02;
  const min = lo - pad, max = hi + pad, span = max - min || 1;

  const X = (i) => padL + (i / (closes.length - 1)) * (w - padL - padR);
  const Y = (v) => padT + (1 - (v - min) / span) * (h - padT - padB);

  for (let i = 0; i <= 3; i++) {
    const v = min + (span * i) / 3;
    const y = Y(v);
    svg.append(el('line', { x1: padL, y1: y, x2: w - padR, y2: y, stroke: 'var(--line)', 'stroke-width': 1, 'vector-effect': 'non-scaling-stroke' }));
    const t = el('text', { x: w - padR + 8, y: y + 3.5, fill: 'var(--text-faint)', 'font-size': 10, 'font-family': 'var(--mono)' });
    t.textContent = price(v, symbol);
    svg.append(t);
  }

  // Plan zones first, so price draws on top of them.
  if (plan && isFinite(plan.entry)) {
    const zone = (from, to, fill) => {
      const y1 = Y(Math.max(from, to)), y2 = Y(Math.min(from, to));
      svg.append(el('rect', { x: padL, y: y1, width: w - padL - padR, height: Math.max(1, y2 - y1), fill, opacity: .5 }));
    };
    if (isFinite(plan.target)) zone(plan.entry, plan.target, 'var(--up-soft)');
    if (isFinite(plan.stop)) zone(plan.stop, plan.entry, 'var(--down-soft)');

    const line = (v, color, label, dash) => {
      if (!isFinite(v)) return;
      const y = Y(v);
      svg.append(el('line', { x1: padL, y1: y, x2: w - padR, y2: y, stroke: color, 'stroke-width': 1.2, 'stroke-dasharray': dash, 'vector-effect': 'non-scaling-stroke' }));
      const t = el('text', { x: w - padR + 8, y: y + 3.5, fill: color, 'font-size': 9.5, 'font-weight': 600, 'font-family': 'var(--mono)' });
      t.textContent = label;
      svg.append(t);
    };
    line(plan.target, 'var(--up)', 'TGT', '4 3');
    line(plan.entry, 'var(--accent)', 'ENT', null);
    line(plan.stop, 'var(--down)', 'STP', '4 3');
  }

  const drawMa = (period, color) => {
    if (!period || closes.length < period) return;
    const pts = [];
    for (let i = period - 1; i < closes.length; i++) {
      let s = 0;
      for (let j = i - period + 1; j <= i; j++) s += closes[j];
      pts.push([X(i), Y(s / period)]);
    }
    svg.append(el('path', { d: path(pts), fill: 'none', stroke: color, 'stroke-width': 1, opacity: .55, 'vector-effect': 'non-scaling-stroke' }));
  };
  if (sma50) drawMa(50, '#8b7ad6');
  if (sma20) drawMa(20, '#d6a87a');

  const coords = closes.map((c, i) => [X(i), Y(c)]);
  svg.append(el('path', { d: path(coords), fill: 'none', stroke: 'var(--text)', 'stroke-width': 1.5, 'stroke-linejoin': 'round', 'vector-effect': 'non-scaling-stroke' }));
  const [lx, ly] = coords[coords.length - 1];
  svg.append(el('circle', { cx: lx, cy: ly, r: 3, fill: 'var(--text)' }));
  return svg;
}
