/**
 * session.js — a timed day-trading run.
 *
 * The rest of the app reads daily bars and says so. This tab does not: a session
 * pulls five-day, five-minute bars, and every level on it comes from intraday
 * volatility and intraday levels. That distinction is stated on the screen rather
 * than buried in a doc, because the whole reason day trading has been absent until
 * now is that faking it on daily data would have been the exact dishonesty this
 * app argues against.
 *
 * The screen is arranged around the two numbers that decide whether a session was
 * any good and neither of which is the P/L: how much of the loss limit is left,
 * and how much time is. Everything else is secondary to those.
 */

import { store, toast, refreshView } from '../app.js';
import * as api from '../api.js';
import { money, signedMoney, price, pct, plainPct, dir, esc, subSigned, subInline } from '../format.js';
import { term, aside } from '../glossary.js';
import { modal } from '../modal.js';
import { morph } from '../morph.js';

let panel = null;
let poll = null;
let working = false;

export async function renderSession(host, { force } = {}) {
  if (!panel || force) panel = await api.getSession().catch(() => null);
  paint(host);
  startPolling(host);
}

/** A session is a clock. It has to tick whether or not anything else changes. */
function startPolling(host) {
  stopPolling();
  if (panel?.session?.status !== 'running') return;
  poll = setInterval(async () => {
    if (store.view !== 'session' || document.hidden) return;
    try {
      panel = await api.getSession();
      paint(host);
      if (panel?.session?.status !== 'running') {
        stopPolling();
        await refreshView();
      }
    } catch { /* a dropped poll is not a failed session */ }
  }, 20_000);
}

function stopPolling() {
  if (poll) { clearInterval(poll); poll = null; }
}

function paint(host) {
  if (!panel) {
    morph(host, `<section class="view"><div class="panel"><div class="empty">
      <div class="empty-sub">The session board could not be loaded.</div></div></div></section>`);
    return;
  }

  /* A running session repaints itself every twenty seconds. Patched rather than
   * rebuilt, so the clock and the P/L move on their own and nothing else does. */
  morph(host, `<section class="view">
    ${panel.session ? live(panel) : setup(panel)}
  </section>`);

  wire(host);
  tickClock();
}

/* ------------------------------------------------------------------- setup */

const PRESETS = [
  [30, 'Half an hour'],
  [60, 'One hour'],
  [120, 'Two hours'],
  [240, 'Four hours'],
];

function setup(p) {
  const equity = store.state.portfolio.equity;
  const cash = store.state.portfolio.cash;
  const suggested = Math.max(100, Math.round((cash * 0.25) / 100) * 100);

  return `
    <div class="section-head">
      <h2>Day trading session</h2>
      <span class="hint">A set amount of money, a set amount of time, and limits that cannot be changed while the clock runs.</span>
    </div>

    ${aside('You commit part of the account for a fixed period. Five-minute bars are scanned for setups with the entry, stop and size worked out, and the session ends at its loss limit, its target or the clock.')}

    <div class="note accent" style="margin-bottom:18px"><span class="note-icon">›</span><span>
      <strong>This is the only part of Paper that reads intraday data.</strong> Everywhere else the engine
      works from daily bars, which cannot resolve a trade opened and closed inside one session. A session
      pulls five days of five-minute bars, 391 per instrument, so the stops, targets and averages here are
      intraday numbers.</span></div>

    ${!p.marketOpen ? `<div class="note warn" style="margin-bottom:18px"><span class="note-icon">!</span>
      <span><strong>The equity session is closed.</strong> A session started now trades crypto only, which
      runs continuously and has no closing bell to end a losing run.</span></div>` : ''}

    <!-- The question being asked, not the server's answer to it: a repaint
         updates everything around this panel and leaves the controls in it set
         to whatever they were set to. -->
    <div class="panel panel-pad" data-keep>
      <div class="grid-2">
        <div class="field">
          <label for="stakeInput">How much to commit ${cur()}</label>
          <input id="stakeInput" type="number" step="any" value="${suggested}">
          <span class="faint" style="font-size:11.5px">${money(cash, 0)} is free in the account.
            Risk per trade is a share of this stake, not of the whole account.</span>
        </div>
        <div class="field">
          <label>How long</label>
          <div class="pill-row" id="minutesRow">
            ${PRESETS.map(([m, l], i) => `<button class="pill ${i === 1 ? 'is-on' : ''}" data-minutes="${m}">${esc(l)}</button>`).join('')}
          </div>
          <span class="faint" style="font-size:11.5px">When the time is up, anything the session opened is
            closed at the current price, whether or not it is in profit.</span>
        </div>
      </div>

      <div class="grid-2" style="margin-top:18px">
        <div class="field">
          <label for="lossInput">Stop the session after losing — <span id="lossLabel">3</span>% of the stake</label>
          <input id="lossInput" type="range" min="1" max="15" step="0.5" value="3">
          <span class="faint" style="font-size:11.5px">
            Reaching this closes the session to new entries whatever the clock says. It cannot be
            raised while the session is running.</span>
        </div>
        <div class="field">
          <label for="targetInput">End it after making — <span id="targetLabel">5</span>% of the stake</label>
          <input id="targetInput" type="range" min="1" max="30" step="0.5" value="5">
          <span class="faint" style="font-size:11.5px">Reaching this ends the session with time left on
            the clock. It cannot be raised while the session is running.</span>
        </div>
      </div>

      <div class="grid-2" style="margin-top:18px">
        <div class="field">
          <label for="riskInput">Risk per trade — <span id="riskLabel">1</span>% of the stake</label>
          <input id="riskInput" type="range" min="0.25" max="3" step="0.25" value="1">
          <span class="faint" style="font-size:11.5px">What is lost if the stop fills. Position size is
            worked backwards from it.</span>
        </div>
        <div class="field">
          <label for="tradesInput">At most — <span id="tradesLabel">6</span> trades</label>
          <input id="tradesInput" type="range" min="1" max="15" step="1" value="6">
          <span class="faint" style="font-size:11.5px">A hard cap on entries. Each one crosses the spread
            twice and pays commission twice.</span>
        </div>
      </div>

      <div id="sessionPreview" class="note" style="margin-top:18px"></div>

      <div class="row wrap" style="gap:8px;margin-top:16px">
        <button class="btn primary" id="startSessionBtn">Start the session</button>
        ${p.dayTradesLeft != null ? `<span class="faint" style="font-size:11.5px">
          ${p.dayTradesLeft} day trade${p.dayTradesLeft === 1 ? '' : 's'} left before the pattern-day-trader
          rule freezes this account. Crypto is exempt.</span>` : ''}
      </div>
    </div>

    <div class="panel panel-pad" style="margin-top:18px">
      <div class="explain-label" style="margin-bottom:8px">What runs during a session</div>
      <p class="prose" style="font-size:12.5px">
        Scanning is done by the <strong>engine alone</strong>. No model is called on a timer; an intraday
        setup is geometry rather than narrative. The analyst can still be asked about one instrument at a
        time from its drawer.
      </p>
      <p class="prose" style="font-size:12.5px">
        Every cost applied elsewhere applies here: the spread on each fill, commission both ways, the
        short-term tax rate on anything closed inside a year, and the pattern-day-trader rule under
        $25,000. On a five-minute timeframe those costs are usually most of the result.
      </p>
    </div>`;
}

const cur = () => `<span class="unit">${esc(store.state.currency)}</span>`;

/* -------------------------------------------------------------------- live */

function live(p) {
  const s = p.session;
  const over = s.status !== 'running';
  const lossUsed = p.lossLimit > 0 ? Math.min(100, Math.max(0, (-Math.min(0, p.total) / p.lossLimit) * 100)) : 0;
  const targetDone = p.targetAmount > 0 ? Math.min(100, Math.max(0, (p.total / p.targetAmount) * 100)) : 0;
  const elapsed = s.minutes * 60 - p.secondsLeft;
  const timeUsed = s.minutes > 0 ? Math.min(100, (elapsed / (s.minutes * 60)) * 100) : 0;

  return `
    <div class="section-head">
      <h2>${over ? 'Session report' : 'Session running'}</h2>
      <span class="hint">${money(s.stake, 0)} committed · ${plainPct(s.riskPctPerTrade, 2)} per trade ·
        five-minute bars</span>
      <span class="spacer"></span>
      ${over
        ? '<button class="btn sm" id="clearSessionBtn">Start another</button>'
        : '<button class="btn danger sm" id="endSessionBtn">End it now</button>'}
    </div>

    ${over ? `<div class="note ${s.status === 'met-target' ? 'accent' : s.status === 'hit-loss-limit' ? 'warn' : ''}">
      <span class="note-icon">${s.status === 'met-target' ? '✓' : s.status === 'hit-loss-limit' ? '!' : '›'}</span>
      <span><strong>${esc(statusLabel(s.status))}.</strong> ${esc(s.endNote ?? '')}</span></div>` : ''}

    <div class="panel panel-pad" style="margin-top:${over ? '16' : '0'}px">
      <div class="metric-grid" style="grid-template-columns:repeat(auto-fit,minmax(120px,1fr))">
        <div class="metric"><div class="metric-label">Session P/L</div>
          <div class="metric-value ${dir(p.total)}" style="font-size:18px">${signedMoney(p.total)}</div>
          ${subSigned(p.total)}</div>
        <div class="metric"><div class="metric-label">Realised</div>
          <div class="metric-value ${dir(p.realised)}">${signedMoney(p.realised)}</div>
          ${subSigned(p.realised)}</div>
        <div class="metric"><div class="metric-label">Open</div>
          <div class="metric-value ${dir(p.unrealised)}">${signedMoney(p.unrealised)}</div>
          ${subSigned(p.unrealised)}</div>
        <div class="metric"><div class="metric-label">Trades</div>
          <div class="metric-value">${s.entries.length}<span class="faint" style="font-size:13px"> / ${s.maxTrades}</span></div></div>
        <div class="metric"><div class="metric-label">${over ? 'Ran for' : 'Time left'}</div>
          <div class="metric-value" id="clock">${over ? Math.round(s.minutes) + 'm' : clockText(p.secondsLeft)}</div></div>
      </div>

      <div class="session-bars">
        <div class="session-bar">
          <div class="session-bar-head">
            <span>Loss limit</span>
            <span class="num ${lossUsed > 66 ? 'down' : ''}">${money(p.lossHeadroom, 0)}${subInline(p.lossHeadroom)} left of ${money(p.lossLimit, 0)}</span>
          </div>
          <div class="score-track"><div class="score-fill" style="width:${lossUsed}%;background:var(--down)"></div></div>
        </div>
        <div class="session-bar">
          <div class="session-bar-head">
            <span>Target</span>
            <span class="num ${targetDone >= 100 ? 'up' : ''}">${money(Math.max(0, p.total), 0)} of ${money(p.targetAmount, 0)}</span>
          </div>
          <div class="score-track"><div class="score-fill" style="width:${targetDone}%;background:var(--up)"></div></div>
        </div>
        ${over ? '' : `<div class="session-bar">
          <div class="session-bar-head"><span>Clock</span><span class="num dim" id="clockSub">${clockText(p.secondsLeft)}</span></div>
          <div class="score-track"><div class="score-fill" style="width:${timeUsed}%;background:var(--accent)"></div></div>
        </div>`}
      </div>
    </div>

    ${s.entries.length ? entries(s) : ''}
    ${over ? report(p) : board(p)}`;
}

function statusLabel(status) {
  return { 'met-target': 'Target reached', 'hit-loss-limit': 'Loss limit hit',
    'out-of-time': 'Time up', stopped: 'Ended early', running: 'Running' }[status] ?? status;
}

function clockText(seconds) {
  const s = Math.max(0, Math.round(seconds));
  const m = Math.floor(s / 60);
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m ${String(s % 60).padStart(2, '0')}s`;
}

/** The clock ticks locally so it never looks frozen between twenty-second polls. */
function tickClock() {
  const el = document.getElementById('clock');
  if (!el || !panel?.session || panel.session.status !== 'running') return;
  const endsAt = panel.session.endsAt;
  clearInterval(tickClock.timer);
  tickClock.timer = setInterval(() => {
    const node = document.getElementById('clock');
    if (!node) return clearInterval(tickClock.timer);
    const left = (endsAt - Date.now()) / 1000;
    node.textContent = clockText(left);
    const sub = document.getElementById('clockSub');
    if (sub) sub.textContent = clockText(left);
  }, 1000);
}

/* ------------------------------------------------------------------- board */

function board(p) {
  const open = p.candidates.filter((c) => !c.blocked);
  const shut = p.candidates.filter((c) => c.blocked);

  if (!p.candidates.length) {
    return `<div class="panel" style="margin-top:18px"><div class="empty">
      <div class="empty-title">Nothing on the board</div>
      <div class="empty-sub">${p.marketOpen
        ? 'The scan is running. If it stays empty, no instrument currently clears the reward-to-risk floor on five-minute bars.'
        : 'The equity session is closed and this profile has no crypto in its universe, so nothing can be traded right now.'}</div>
    </div></div>`;
  }

  return `
    <div class="section-head" style="margin-top:26px">
      <h2>Live board</h2>
      <span class="hint">${open.length} tradable of ${p.candidates.length} scanned · five-minute bars ·
        refreshed every 20 seconds</span>
    </div>
    ${open.map(candidate).join('')}
    ${shut.length ? `
      <div class="section-head" style="margin-top:22px"><h2>Not available</h2>
        <span class="hint">Why each one cannot be taken.</span></div>
      <div class="panel scroll-x"><table>
        <thead><tr><th>Instrument</th><th>Reason</th></tr></thead>
        <tbody>${shut.map((c) => `<tr>
          <td><span class="sym-ticker" data-symbol="${esc(c.symbol)}" style="cursor:pointer">${esc(c.symbol)}</span></td>
          <td class="dim" style="font-size:12.5px">${esc(c.blocked)}</td></tr>`).join('')}</tbody>
      </table></div>` : ''}`;
}

function candidate(c) {
  const plan = c.plan;
  return `<div class="pick">
    <div class="pick-head">
      <div class="pick-title">
        <div class="pick-headline">${esc(c.name)}
          <span class="faint" style="font-weight:500">· ${esc(c.symbol)}</span></div>
        <div class="pick-meta">
          ${price(c.price, c.symbol)} <span class="${dir(c.changePct)}">${pct(c.changePct, 2)}</span> today ·
          engine read ${c.conviction.toFixed(0)}/100 ·
          ${c.barRangePct != null ? `${plainPct(c.barRangePct)} average five-minute range` : ''}
        </div>
      </div>
      <button class="btn primary sm" data-take-session="${esc(c.symbol)}">Take it</button>
    </div>
    <div class="pick-body">
      <div class="plan">
        <div class="plan-cell entry">
          <div class="plan-label">Entry</div>
          <div class="plan-price">${price(plan.entry, plan.symbol)}</div>
          <div class="plan-delta faint">${money(plan.cost, 0)} · ${plan.shares < 1 ? plan.shares.toFixed(4) : plan.shares.toFixed(2)} units</div>
        </div>
        <div class="plan-cell target">
          <div class="plan-label">Target</div>
          <div class="plan-price up">${price(plan.target, plan.symbol)}</div>
          <div class="plan-delta up">${pct(plan.targetPct, 2)} · ${money(plan.shares * (plan.target - plan.entry), 0)}</div>
        </div>
        <div class="plan-cell stop">
          <div class="plan-label">Stop</div>
          <div class="plan-price down">${price(plan.stop, plan.symbol)}</div>
          <div class="plan-delta down">${pct(plan.stopPct, 2)} · ${money(plan.riskTaken, 0)} at risk</div>
        </div>
      </div>
      ${c.sizeNote ? `<div class="note warn"><span class="note-icon">!</span>
        <span>${esc(c.sizeNote)}</span></div>` : ''}

      <div class="row wrap" style="gap:7px">
        <span class="chip up">${plan.rr.toFixed(2)}:1</span>
        <span class="chip ghost" title="With this ratio, how often you would need to be right just to break even.">breaks even at ${plan.breakevenWinRate.toFixed(0)}%</span>
        <span class="chip ghost" title="Five-minute bars, not days. About ${Math.round(c.barsToTarget * 5)} minutes at this timeframe.">~${c.barsToTarget.toFixed(0)} bars to target</span>
        ${plan.tightStop ? '<span class="chip warn">tightened stop</span>' : ''}
      </div>
    </div>
  </div>`;
}

/* ----------------------------------------------------------------- entries */

function entries(s) {
  return `
    <div class="section-head" style="margin-top:26px"><h2>What the session traded</h2></div>
    <div class="panel scroll-x"><table>
      <thead><tr><th>Instrument</th><th class="right">Entry</th><th class="right">Stop</th>
        <th class="right">Exit</th><th class="right">Costs</th><th class="right">P/L</th>
        <th class="right">R</th><th>How it ended</th></tr></thead>
      <tbody>${s.entries.map((e) => `<tr>
        <td><span class="sym-ticker" data-symbol="${esc(e.symbol)}" style="cursor:pointer">${esc(e.symbol)}</span></td>
        <td class="right num">${price(e.entry, e.symbol)}</td>
        <td class="right num down">${price(e.stop, e.symbol)}</td>
        <td class="right num">${e.exit != null ? price(e.exit, e.symbol) : '<span class="dim">open</span>'}</td>
        <td class="right num down" title="Spread crossed on the way in and again on the way out, plus commission both times.">${e.costs != null ? money(e.costs, 2) : '—'}</td>
        <td class="right num ${e.pnl != null ? dir(e.pnl) : 'dim'}">${e.pnl != null ? signedMoney(e.pnl) : '—'}</td>
        <td class="right num ${e.rMultiple != null ? dir(e.rMultiple) : 'dim'}">${e.rMultiple != null ? (e.rMultiple >= 0 ? '+' : '') + e.rMultiple.toFixed(2) : '—'}</td>
        <td class="dim" style="font-size:12px">${esc(triggerLabel(e.trigger))}</td>
      </tr>`).join('')}</tbody>
    </table></div>`;
}

const triggerLabel = (t) => ({
  target: 'Target hit', stop: 'Stop hit', manual: 'Closed by hand',
  session: 'Closed when the session ended',
}[t] ?? (t ? t : 'Still open'));

/* ------------------------------------------------------------------ report */

function report(p) {
  const s = p.session;
  const closed = s.entries.filter((e) => e.pnl != null);
  const wins = closed.filter((e) => e.pnl > 0);
  const rs = closed.map((e) => e.rMultiple).filter((r) => r != null);
  const avgR = rs.length ? rs.reduce((a, b) => a + b, 0) / rs.length : null;
  const stoppedOut = closed.filter((e) => e.trigger === 'stop').length;
  const flattened = closed.filter((e) => e.trigger === 'session').length;

  return `
    <div class="section-head" style="margin-top:26px"><h2>How it went</h2>
      <span class="hint">The session's own record, kept separate from the account's.</span></div>
    <div class="panel panel-pad">
      <div class="metric-grid" style="grid-template-columns:repeat(auto-fit,minmax(110px,1fr))">
        <div class="metric"><div class="metric-label">Closed</div><div class="metric-value">${closed.length}</div></div>
        <div class="metric"><div class="metric-label">Won</div><div class="metric-value up">${wins.length}</div></div>
        <div class="metric"><div class="metric-label">Stopped out</div><div class="metric-value down">${stoppedOut}</div></div>
        <div class="metric"><div class="metric-label">Average ${term('r', 'R')}</div>
          <div class="metric-value ${avgR == null ? '' : dir(avgR)}">${avgR == null ? '—' : (avgR >= 0 ? '+' : '') + avgR.toFixed(2)}</div></div>
        <div class="metric"><div class="metric-label">Return on stake</div>
          <div class="metric-value ${dir(p.totalPct)}">${pct(p.totalPct, 2)}</div></div>
        <div class="metric" title="Spread and commission across every fill.">
          <div class="metric-label">Paid to trade</div>
          <div class="metric-value down">${money(costsOf(s), 2)}</div></div>
      </div>
      <p class="prose" style="margin-top:16px">${esc(verdict(p, closed, wins, avgR, flattened))}</p>
      ${costLine(p, s, closed)}
    </div>`;
}

const costsOf = (s) => s.entries.reduce((n, e) => n + (e.costs ?? 0), 0);

/**
 * What the trading cost, said plainly and separately from whether it worked.
 *
 * This is the number a day-trading simulator exists to show. A stop that was
 * placed half a percent away on an instrument charging a quarter percent each way
 * has already spent most of its risk budget before the price moves at all, and on
 * a five-minute timeframe that arithmetic is the whole game. Stating it as a share
 * of the result is the only way it lands.
 */
function costLine(p, s, closed) {
  const costs = costsOf(s);
  if (!closed.length || costs <= 0) return '';
  const gross = p.total + costs;
  const share = Math.abs(p.total) > 0 ? (costs / Math.abs(p.total)) * 100 : null;

  return `<div class="note ${costs > Math.abs(gross) ? 'warn' : ''}" style="margin-top:14px">
    <span class="note-icon">!</span><span>
      <strong>${money(costs, 2)} of this went on spread and commission</strong> across
      ${closed.length * 2} fills. Before those costs the session
      ${gross >= 0 ? 'made' : 'lost'} ${money(Math.abs(gross), 2)}; after them it
      ${p.total >= 0 ? 'made' : 'lost'} ${money(Math.abs(p.total), 2)}.
      ${share != null && share >= 50
        ? ` That is ${share.toFixed(0)}% of the result. Each position crosses the spread twice and pays
            commission twice, and an intraday stop is often closer than the round trip costs.`
        : gross > 0 && p.total < 0
          ? ' The trades were net positive before costs and negative after them. A win rate does not show this.'
          : ' This figure grows with the number of trades, whether or not they work.'}
    </span></div>`;
}

/**
 * The session's own account of itself, from its numbers. Deterministic — no model
 * is asked, which is why it is always here and always says the same thing about
 * the same session.
 */
function verdict(p, closed, wins, avgR, flattened) {
  const s = p.session;
  if (!closed.length) {
    return `Nothing was traded. ${s.status === 'out-of-time'
      ? 'The clock ran out before any setup cleared the reward-to-risk floor.'
      : 'The session ended before anything was taken.'}`;
  }

  const parts = [];
  parts.push(`${closed.length} trade${closed.length === 1 ? '' : 's'} closed, ${wins.length} of them up, for ${signedMoney(p.total)} on a ${money(s.stake, 0)} stake: ${pct(p.totalPct, 2)}.`);

  if (avgR != null) {
    parts.push(avgR >= 0.2
      ? `Each trade was worth ${avgR.toFixed(2)} times what it risked on average, which covers the costs.`
      : avgR <= -0.5
        ? `Each trade lost ${Math.abs(avgR).toFixed(2)} times what it risked on average. Repeated at this rate, the loss limit is what ends the session.`
        : `Each trade was worth ${avgR.toFixed(2)} times what it risked on average, close enough to flat that spread and commission account for most of the difference.`);
  }

  if (s.status === 'hit-loss-limit') {
    parts.push(`The loss limit closed the session to new entries. It was set before the session started and could not be raised during it.`);
  } else if (s.status === 'met-target') {
    parts.push(`The target ended the session with time left on the clock.`);
  } else if (flattened > 0) {
    parts.push(`${flattened} position${flattened === 1 ? ' was' : 's were'} closed by the session ending rather than by their own stop or target.`);
  }

  return parts.join(' ');
}

/* ----------------------------------------------------------------- wiring */

function wire(host) {
  // Live preview of what the settings actually mean, in money.
  const inputs = ['stakeInput', 'lossInput', 'targetInput', 'riskInput', 'tradesInput']
    .map((id) => host.querySelector('#' + id)).filter(Boolean);
  const preview = () => {
    const stake = Number(host.querySelector('#stakeInput')?.value) || 0;
    const loss = Number(host.querySelector('#lossInput')?.value) || 0;
    const target = Number(host.querySelector('#targetInput')?.value) || 0;
    const risk = Number(host.querySelector('#riskInput')?.value) || 0;
    const trades = Number(host.querySelector('#tradesInput')?.value) || 0;
    for (const [id, v] of [['lossLabel', loss], ['targetLabel', target], ['riskLabel', risk], ['tradesLabel', trades]]) {
      const el = host.querySelector('#' + id);
      if (el) el.textContent = v;
    }
    const host$ = host.querySelector('#sessionPreview');
    if (!host$) return;
    const perTrade = stake * (risk / 100);
    const limit = stake * (loss / 100);
    const goal = stake * (target / 100);
    host$.innerHTML = `<span class="note-icon">›</span><span>
      Each trade risks <strong>${money(perTrade, 0)}</strong>${subInline(perTrade)}. The session ends if it is
      <strong>${money(limit, 0)}</strong>${subInline(limit)} down — about ${(limit / Math.max(perTrade, 1)).toFixed(1)} losing
      trades in a row — or <strong>${money(goal, 0)}</strong>${subInline(goal)} up. At most ${trades} trades either way.
      ${target < loss ? '<br><strong>The target is below the loss limit.</strong> It will be raised to sit above it.' : ''}
    </span>`;
  };
  /* Assigned rather than added: these nodes now survive a repaint, and a listener
   * added to each of them would be added again every time one happened. */
  inputs.forEach((el) => { el.oninput = preview; });
  if (inputs.length) preview();

  host.querySelectorAll('[data-minutes]').forEach((el) => {
    el.onclick = () => {
      host.querySelectorAll('[data-minutes]').forEach((x) => x.classList.remove('is-on'));
      el.classList.add('is-on');
    };
  });

  if (host.dataset.sessionBound) return;
  host.dataset.sessionBound = '1';
  host.addEventListener('click', async (e) => {
    if (store.view !== 'session') return;
    if (e.target.closest('#startSessionBtn')) return start(host);
    if (e.target.closest('#endSessionBtn')) return end(host);
    if (e.target.closest('#clearSessionBtn')) return clear(host);
    const take = e.target.closest('[data-take-session]');
    if (take) return take$(host, take);
  });
}

async function start(host) {
  if (working) return;
  const stake = Number(host.querySelector('#stakeInput')?.value) || 0;
  const minutes = Number(host.querySelector('[data-minutes].is-on')?.dataset.minutes) || 60;
  const config = {
    stake, minutes,
    maxLossPct: Number(host.querySelector('#lossInput')?.value) || 3,
    targetPct: Number(host.querySelector('#targetInput')?.value) || 5,
    riskPctPerTrade: Number(host.querySelector('#riskInput')?.value) || 1,
    maxTrades: Number(host.querySelector('#tradesInput')?.value) || 6,
    flatAtEnd: true,
  };

  const ok = await modal({
    title: 'Start the session?',
    confirmText: 'Start it',
    body: `<div class="ticket-line"><span>Committed</span><span>${money(stake, 0)}${subInline(stake)}</span></div>
      <div class="ticket-line"><span>Runs for</span><span>${minutes} minutes</span></div>
      <div class="ticket-line"><span>Ends if down</span><span class="down">${money(stake * config.maxLossPct / 100, 0)}${subInline(stake * config.maxLossPct / 100)}</span></div>
      <div class="ticket-line"><span>Ends if up</span><span class="up">${money(stake * config.targetPct / 100, 0)}${subInline(stake * config.targetPct / 100)}</span></div>
      <div class="ticket-line"><span>Risk per trade</span><span>${money(stake * config.riskPctPerTrade / 100, 0)}${subInline(stake * config.riskPctPerTrade / 100)}</span></div>
      <p style="margin-top:12px">The loss limit and the target cannot be changed once the session starts.
      Anything it opens is closed when it ends. Simulated money; no order reaches a market.</p>`,
  });
  if (!ok) return;

  working = true;
  try {
    panel = await api.startSession(config);
    await refreshView();
    paint(host);
    startPolling(host);
    toast(`Session open for ${minutes} minutes, with a ${money(stake * config.maxLossPct / 100, 0)} loss limit.`);
  } catch (err) {
    toast(err.message, 'err', 8000);
  } finally {
    working = false;
  }
}

async function take$(host, btn) {
  const symbol = btn.dataset.takeSession;
  btn.disabled = true;
  try {
    panel = await api.takeSessionTrade(symbol);
    await refreshView();
    paint(host);
    toast(`${symbol} opened with its bracket attached. It closes when either leg is touched.`);
  } catch (err) {
    toast(err.message, 'err', 8000);
    btn.disabled = false;
  }
}

async function end(host) {
  const ok = await modal({
    title: 'End the session now?', confirmText: 'End it', tone: 'danger',
    body: `<p>Anything still open is closed at the current price. The record of the session is kept.</p>`,
  });
  if (!ok) return;
  try {
    panel = await api.endSession();
    stopPolling();
    await refreshView();
    paint(host);
  } catch (err) { toast(err.message, 'err'); }
}

async function clear(host) {
  try {
    panel = await api.clearSession();
    await refreshView();
    paint(host);
  } catch (err) { toast(err.message, 'err'); }
}
