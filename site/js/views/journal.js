/** Journal — the trade record and the scorecard that reads it back to you. */

import { store } from '../app.js';
import { money, signedMoney, price, pct, plainPct, shares, dir, esc, dateTime } from '../format.js';

/* A reconstructed exit is dated to a session, not to a moment. Printing a clock
 * time beside one would claim a precision the daily bar does not have. */
const dayOnly = (ts) => new Date(ts).toLocaleDateString(undefined,
  { year: 'numeric', month: 'short', day: 'numeric' });

export async function renderJournal(host) {
  const s = store.state;
  const sc = s.scorecard;
  const closed = s.trades.filter((t) => t.action === 'sell');

  host.innerHTML = `
    <section class="view">
      <div class="section-head">
        <h2>Scorecard</h2>
        <span class="hint">Measured across every closed trade.</span>
      </div>

      <div class="panel">
        <div class="stat-grid">
          <div class="stat"><span class="stat-label">Closed trades</span>
            <span class="stat-value">${sc.closedTrades}</span>
            <span class="stat-note">${sc.wins} up · ${sc.losses} down</span></div>
          <div class="stat"><span class="stat-label">Win rate</span>
            <span class="stat-value">${sc.winRate == null ? '—' : plainPct(sc.winRate, 0)}</span>
            <span class="stat-note">read alongside expectancy</span></div>
          <div class="stat"><span class="stat-label">Expectancy</span>
            <span class="stat-value ${dir(sc.expectancyR)}">${sc.expectancyR == null ? '—' : (sc.expectancyR >= 0 ? '+' : '') + sc.expectancyR.toFixed(2) + 'R'}</span>
            <span class="stat-note">average result per unit risked</span></div>
          <div class="stat"><span class="stat-label">Profit factor</span>
            <span class="stat-value">${sc.profitFactor == null ? '—' : sc.profitFactor === null ? '—' : (isFinite(sc.profitFactor) ? sc.profitFactor.toFixed(2) : '∞')}</span>
            <span class="stat-note">gross gains ÷ gross losses</span></div>
          <div class="stat"><span class="stat-label">Average win</span>
            <span class="stat-value up">${sc.avgWin == null ? '—' : signedMoney(sc.avgWin)}</span>
            <span class="stat-note">vs ${sc.avgLoss == null ? '—' : signedMoney(sc.avgLoss)} average loss</span></div>
          <div class="stat"><span class="stat-label">How exits happened</span>
            <span class="stat-value" style="font-size:15px">${sc.targetsHit}·${sc.stoppedOut}·${sc.manualExits}</span>
            <span class="stat-note">target · stop · by hand${sc.gappedExits ? ` · ${sc.gappedExits} gapped` : ''}${sc.backfilledExits ? ` · ${sc.backfilledExits} reconstructed` : ''}</span></div>
          <div class="stat" title="Spread, commission and tax across every fill.">
            <span class="stat-label">Given up to costs</span>
            <span class="stat-value down">${money(sc.totalCommission + sc.totalSlippage + sc.totalTax, 2)}</span>
            <span class="stat-note">${sc.pnlBeforeCosts == null ? 'nothing closed yet'
              : `${signedMoney(sc.pnlBeforeCosts)} before them`}</span></div>
        </div>
        <div class="panel-pad" style="border-top:1px solid var(--line)">
          <div class="note accent"><span class="note-icon">›</span><span>${esc(sc.verdict)}</span></div>
        </div>
      </div>

      <div class="section-head" style="margin-top:26px">
        <h2>Trade record</h2>
        <span class="hint">${s.trades.length} entries. The reasoning is stored with each trade.</span>
      </div>
      ${s.trades.length === 0 ? empty() : table(s.trades)}

      ${closed.length >= 3 ? rDistribution(closed) : ''}
    </section>`;
}

function empty() {
  return `<div class="panel"><div class="empty">
    <div class="empty-title">The record is empty</div>
    <div class="empty-sub">Every entry and exit is logged here with its reason attached, which is what the
      review reads back.</div>
  </div></div>`;
}

/**
 * Newest first, by when the fill actually happened.
 *
 * The ledger inserts every new trade at the front of the array, which is the
 * right order right up until the reconciliation pass books an exit that happened
 * last Tuesday — that one goes to the front too, and lands at the top of a table
 * whose column header says "When". Sorting here rather than relying on insertion
 * order means a reconstructed exit sits on the day it belongs to.
 */
function table(unsorted) {
  const trades = [...unsorted].sort((a, b) => b.at - a.at);
  return `<div class="panel scroll-x"><table>
    <thead><tr>
      <th>When</th><th>Instrument</th><th>Action</th><th class="right">Size</th>
      <th class="right">Fill</th><th class="right">Value</th><th class="right">Costs</th>
      <th class="right">Result</th><th>Reasoning</th>
    </tr></thead>
    <tbody>${trades.map((t) => `<tr>
      <td class="faint" style="white-space:nowrap;font-size:12px"
          ${t.backfilled ? 'title="Reconstructed from the bar for that session, so the day is known and the time inside it is not."' : ''}>
        ${t.backfilled ? esc(dayOnly(t.at)) : dateTime(t.at)}</td>
      <td><span class="sym-ticker" data-symbol="${esc(t.symbol)}" style="cursor:pointer">${esc(t.symbol)}</span></td>
      <td>
        <span class="chip ${t.action === 'buy' ? 'accent' : 'ghost'}">${t.action === 'buy' ? 'Buy' : 'Sell'}</span>
        ${t.trigger === 'target' ? '<span class="chip up" style="margin-left:4px">target</span>' : ''}
        ${t.trigger === 'stop' ? '<span class="chip down" style="margin-left:4px">stop</span>' : ''}
        ${t.gapped ? '<span class="chip warn" style="margin-left:4px" title="The session opened past the level, so the fill was the open rather than the level.">gapped</span>' : ''}
        ${t.backfilled ? '<span class="chip ghost" style="margin-left:4px" title="Paper was not running when this level was reached. The fill was rebuilt from the bar for that session — the price is the level, but the time inside the day is inferred.">reconstructed</span>' : ''}
        ${t.dayTrade ? '<span class="chip ghost" style="margin-left:4px">day trade</span>' : ''}
      </td>
      <td class="right num">${shares(t.shares)}</td>
      <td class="right num" title="${t.quotedPrice ? `Quoted ${price(t.quotedPrice, t.symbol)}; the spread was crossed to fill.` : ''}">
        ${price(t.price, t.symbol)}
        ${t.quotedPrice && Math.abs(t.quotedPrice - t.price) > 1e-9
          ? `<br><span class="faint" style="font-size:10.5px">quoted ${price(t.quotedPrice, t.symbol)}</span>` : ''}</td>
      <td class="right num">${money(t.value)}</td>
      <td class="right num faint" style="font-size:12px">${money((t.commission ?? 0) + (t.slippage ?? 0), 2)}
        ${t.taxDue ? `<br><span style="font-size:10.5px">${money(t.taxDue, 2)} tax</span>` : ''}</td>
      <td class="right num ${dir(t.pnl)}">${t.pnl == null ? '—' : signedMoney(t.pnl)}
        ${t.rMultiple != null ? `<br><span class="faint" style="font-size:11px">${t.rMultiple >= 0 ? '+' : ''}${t.rMultiple.toFixed(2)}R</span>` : ''}</td>
      <td class="dim" style="max-width:400px;font-size:12.5px;line-height:1.5">${esc(t.reason)}</td>
    </tr>`).join('')}</tbody></table></div>`;
}

/** The R histogram — the shape that shows whether the exits are doing their job. */
function rDistribution(closed) {
  const rs = closed.map((t) => t.rMultiple).filter((r) => r != null);
  if (rs.length < 3) return '';
  const buckets = [
    ['< -1R', (r) => r < -1], ['-1 to 0R', (r) => r >= -1 && r < 0],
    ['0 to 1R', (r) => r >= 0 && r < 1], ['1 to 2R', (r) => r >= 1 && r < 2],
    ['2R+', (r) => r >= 2],
  ].map(([label, test]) => ({ label, n: rs.filter(test).length }));
  const max = Math.max(...buckets.map((b) => b.n), 1);

  return `<div class="section-head" style="margin-top:26px">
      <h2>Result distribution</h2>
      <span class="hint">In R: multiples of the money risked, so a Bitcoin trade and a Walmart trade compare on the same scale.</span>
    </div>
    <div class="panel panel-pad">
      <div class="scores">
        ${buckets.map((b) => `<div class="score-row">
          <span class="dim">${b.label}</span>
          <div class="score-track"><div class="score-fill" style="width:${(b.n / max) * 100}%;background:${b.label.startsWith('<') || b.label.startsWith('-1') ? 'var(--down)' : 'var(--up)'}"></div></div>
          <span class="num dim">${b.n}</span>
        </div>`).join('')}
      </div>
      <div class="note" style="margin-top:14px"><span class="note-icon">›</span><span>
        A profitable system usually has more entries in the left two buckets than the right ones, and survives
        because the bars on the right reach further. Losses bigger than −1R mean a stop was moved, skipped or
        gapped through.
      </span></div>
    </div>`;
}
