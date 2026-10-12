/**
 * Markets — the whole tradable universe, sortable, with the engine's read.
 *
 * The board spans two exchanges and three asset classes, so the filter does both:
 * what kind of thing it is, and where it trades. A Swedish reader looking for
 * something to buy before lunch wants the Stockholm list, not a mixed one with
 * two-thirds of it shut.
 */

import { store } from '../app.js';
import { morph, clearMorph } from '../morph.js';
import * as api from '../api.js';
import { price, pct, plainPct, dir, esc, compact, REGIME_LABEL, regimeClass, scoreColor, noteCurrencies } from '../format.js';

let sortKey = 'conviction';
let sortDir = -1;
let filter = 'all';

const FILTERS = [
  ['all', 'All', null],
  ['equity', 'Stocks', (r) => r.klass === 'equity'],
  ['crypto', 'Crypto', (r) => r.klass === 'crypto'],
  ['us', 'US', (r) => r.venue === 'us'],
  ['stockholm', 'Stockholm', (r) => r.venue === 'stockholm'],
];

const COLUMNS = [
  { key: 'symbol', label: 'Instrument', get: (r) => r.symbol },
  { key: 'price', label: 'Last', right: true, get: (r) => r.quote?.price ?? 0 },
  { key: 'day', label: 'Day', right: true, get: (r) => r.quote?.changePct ?? 0 },
  { key: 'ret1mo', label: '1 mo', right: true, get: (r) => r.metrics.ret1mo ?? 0 },
  { key: 'ret6mo', label: '6 mo', right: true, get: (r) => r.metrics.ret6mo ?? 0 },
  { key: 'regime', label: 'Trend', get: (r) => r.metrics.regime },
  { key: 'vol', label: 'Volatility', right: true, get: (r) => r.metrics.atrPct ?? 0 },
  { key: 'conviction', label: 'Engine read', right: true, get: (r) => r.metrics.conviction },
  { key: 'rr', label: 'Setup', right: true, get: (r) => (r.plan.rejected ? -1 : r.plan.rr) },
];

export async function renderMarkets(host, { force } = {}) {
  if (!store.markets || force) {
    host.innerHTML = `<section class="view"><div class="panel"><div class="empty">
      <div class="spinner"></div><div class="empty-sub">Pulling a year of bars for every instrument on the board…</div>
    </div></div></section>`;
    // Written straight to the host rather than patched, so the patcher is told to
    // forget it — otherwise identical markup on the far side of the fetch would be
    // taken for a no-op and the spinner would never come down.
    clearMorph(host);
    store.markets = await api.getMarkets();
  }
  // What every symbol on the board is quoted in, so prices are drawn with the
  // right sign everywhere in the app, not only on this tab.
  noteCurrencies(store.markets.rows);
  paint(host);
}

function paint(host) {
  const all = store.markets.rows;
  const test = FILTERS.find(([k]) => k === filter)?.[2];
  const rows = all
    .filter((r) => !test || test(r))
    .sort((a, b) => {
      const col = COLUMNS.find((c) => c.key === sortKey);
      const va = col.get(a), vb = col.get(b);
      return (typeof va === 'string' ? va.localeCompare(vb) : va - vb) * sortDir;
    });

  const eligible = all.filter((r) => !r.benchmark && !r.plan.rejected).length;
  const tradable = all.filter((r) => !r.benchmark).length;

  /* Eighty-nine rows, repriced every thirty seconds. Rebuilding the table threw
   * away the scroll position halfway down it and blinked every row to redraw the
   * handful whose price had actually moved. */
  morph(host, `
    <section class="view">
      <div class="section-head">
        <h2>Markets</h2>
        <span class="hint">${eligible} of ${tradable} instruments currently offer a setup this profile will fund.</span>
        <span class="spacer"></span>
        <div class="range-tabs">
          ${FILTERS.filter(([k]) => k !== 'stockholm' || all.some((r) => r.venue === 'stockholm'))
            .map(([k, l]) =>
              `<button data-filter="${k}" class="${filter === k ? 'is-active' : ''}">${l}</button>`).join('')}
        </div>
      </div>

      <div class="panel scroll-x">
        <table>
          <thead><tr>${COLUMNS.map((c) => `
            <th class="sortable ${c.right ? 'right' : ''} ${sortKey === c.key ? 'is-sorted' : ''}" data-sort="${c.key}">
              ${c.label}<span class="arrow">${sortKey === c.key ? (sortDir === -1 ? '↓' : '↑') : ''}</span>
            </th>`).join('')}</tr></thead>
          <tbody>${rows.map(row).join('')}</tbody>
        </table>
      </div>

      <div class="note accent" style="margin-top:16px">
        <span class="note-icon">›</span>
        <span><strong>Engine read</strong> blends trend, momentum, entry quality, risk, daily range and
        durability into one 0–100 score, weighted for the horizon the analyst was last run for. It ranks how
        well a setup matches the rules and is not a forecast; a 78 does not mean a 78% chance of anything, and
        a 78 for a day trade is not the same claim as a 78 for a five-year hold. <strong>Setup</strong> is
        reward-to-risk on the engine's plan, and anything under 1.5:1 is refused.
        Prices are in the currency each instrument's own exchange quotes it in — Stockholm listings are in
        kronor. Click any row for the full working.</span>
      </div>
    </section>`);

  /* Assigned rather than added: the nodes now survive a repaint, so a listener
   * added on each one would be added again on every poll. */
  host.querySelectorAll('[data-sort]').forEach((th) => {
    th.onclick = () => {
      if (sortKey === th.dataset.sort) sortDir *= -1;
      else { sortKey = th.dataset.sort; sortDir = -1; }
      paint(host);
    };
  });

  host.querySelectorAll('[data-filter]').forEach((b) => {
    b.onclick = () => { filter = b.dataset.filter; paint(host); };
  });
}

function row(r) {
  const m = r.metrics, q = r.quote, p = r.plan;
  return `<tr class="clickable${r.inUniverse ? '' : ' is-outside'}" data-symbol="${esc(r.symbol)}"
    title="${r.inUniverse
      ? (r.marketOpen ? '' : `${esc(r.name)} trades on a market that is closed right now. The price is the last one it printed.`)
      : `Outside this profile's universe. Shown for context; it cannot be bought.`}">
    <td><div class="sym">
      <span class="sym-ticker">${esc(r.symbol.replace('-USD', ''))}${r.benchmark ? ' <span class="chip ghost" style="font-size:9.5px">benchmark</span>' : ''}${r.inUniverse ? '' : ' <span class="chip ghost" style="font-size:9.5px">off-universe</span>'}</span>
      <span class="sym-name">${esc(r.name)} · ${esc(r.sector)}${r.currency !== 'USD' ? ` · quoted in ${esc(r.currency)}` : ''}</span>
    </div></td>
    <td class="right num">${price(q?.price, r.symbol)}</td>
    <td class="right num ${dir(q?.changePct)}">${pct(q?.changePct)}</td>
    <td class="right num ${dir(m.ret1mo)}">${pct(m.ret1mo, 1)}</td>
    <td class="right num ${dir(m.ret6mo)}">${pct(m.ret6mo, 1)}</td>
    <td><span class="chip ${regimeClass(m.regime)}">${REGIME_LABEL[m.regime]}</span></td>
    <td class="right num" title="Average daily range as a share of price. It sets the stop distance.">
      ${plainPct(m.atrPct)}</td>
    <td class="right">
      <div class="meter" style="justify-content:flex-end">
        <div class="meter-track"><div class="meter-fill" style="width:${m.conviction}%;background:${scoreColor(m.conviction)}"></div></div>
        <span class="meter-num">${m.conviction.toFixed(0)}</span>
      </div>
    </td>
    <td class="right">${r.benchmark
      ? '<span class="faint">—</span>'
      : p.rejected
        ? `<span class="chip ghost" title="${esc(p.rejected)}">no setup</span>`
        : `<span class="chip up">${p.rr.toFixed(2)}:1</span>`}</td>
  </tr>`;
}
