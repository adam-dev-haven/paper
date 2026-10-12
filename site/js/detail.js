/** The instrument drawer — chart, plan, working, news, and a manual ticket. */

import { store, toast, refreshView } from './app.js';
import * as api from './api.js';
import { money, signedMoney, price, pct, plainPct, dir, esc, when, REGIME_LABEL, regimeClass, scoreColor } from './format.js';
import { confirmBuy, confirmClose, usdOf } from './tickets.js';
import { priceChart } from './chart.js';

let current = null;
let range = '6mo';

/**
 * A third-party URL, or nothing.
 *
 * These come from the news feed, and `esc()` is the wrong tool for the job: it
 * stops the string breaking out of the attribute, and does nothing at all about
 * the scheme. `javascript:` inside an href is still `javascript:` after every
 * angle bracket has been escaped, and this page is a WKWebView with the whole
 * local API on the same origin. Only http and https are links here.
 */
function safeUrl(raw) {
  try {
    const u = new URL(String(raw ?? ''), location.origin);
    return u.protocol === 'http:' || u.protocol === 'https:' ? u.href : '';
  } catch {
    return '';
  }
}

export async function openDetail(symbol) {
  const drawer = document.getElementById('drawer');
  const scrim = document.getElementById('scrim');
  drawer.hidden = false;
  scrim.hidden = false;
  drawer.innerHTML = `<div class="drawer-head"><div><div class="drawer-title">${esc(symbol)}</div>
      <div class="drawer-sub">Loading…</div></div>
      <button class="close-btn" data-close-drawer>×</button></div>
    <div class="drawer-body"><div class="skeleton" style="height:220px"></div>
      <div class="skeleton" style="width:70%"></div><div class="skeleton" style="width:50%"></div></div>`;

  scrim.onclick = close;
  drawer.querySelector('[data-close-drawer]').onclick = close;

  try {
    current = await api.getInstrument(symbol, range);
    paint();
  } catch (err) {
    drawer.querySelector('.drawer-body').innerHTML = `<div class="note warn"><span>${esc(err.message)}</span></div>`;
  }
}

function close() {
  const drawer = document.getElementById('drawer');
  const scrim = document.getElementById('scrim');
  drawer.classList.add('is-closing');
  scrim.classList.add('is-closing');
  setTimeout(() => {
    drawer.hidden = true; scrim.hidden = true;
    drawer.classList.remove('is-closing'); scrim.classList.remove('is-closing');
    drawer.innerHTML = '';
    current = null;
  }, 230);
}

function paint() {
  const { instrument: inst, quote: q, metrics: m, plan, bars, news } = current;
  const drawer = document.getElementById('drawer');
  const held = store.state.portfolio.positions.find((p) => p.symbol === inst.symbol);

  drawer.innerHTML = `
    <div class="drawer-head">
      <div>
        <div class="drawer-title">${esc(inst.symbol)}</div>
        <div class="drawer-sub">${esc(inst.name)} · ${esc(inst.sector)} · ${esc(q?.exchange || inst.klass)}</div>
      </div>
      <div class="drawer-price">
        <div class="p">${price(q?.price, inst.symbol)}</div>
        <div class="${dir(q?.changePct)}" style="font-size:12.5px;font-family:var(--mono)">${pct(q?.changePct)} today</div>
      </div>
      <button class="close-btn" data-close-drawer>×</button>
    </div>

    <div class="drawer-body">
      <div class="row wrap" style="gap:7px">
        <span class="chip ${regimeClass(m.regime)}">${REGIME_LABEL[m.regime]}</span>
        <span class="chip ghost">engine read ${m.conviction.toFixed(0)}/100</span>
        ${held ? `<span class="chip accent">held · ${dir(held.pnl) === 'up' ? '+' : ''}${held.pnlPct.toFixed(1)}%</span>` : ''}
        <span class="spacer" style="margin-left:auto"></span>
        <div class="range-tabs">
          ${['1mo', '6mo', '1y'].map((r) => `<button data-range="${r}" class="${range === r ? 'is-active' : ''}">${r}</button>`).join('')}
        </div>
      </div>

      <div>
        <div id="pchart"></div>
        <div class="chart-legend" style="padding:8px 0 0">
          <span><span class="legend-key" style="background:var(--text)"></span>Price</span>
          <span><span class="legend-key" style="background:#d6a87a"></span>20-day average</span>
          <span><span class="legend-key" style="background:#8b7ad6"></span>50-day average</span>
          ${!plan.rejected ? `<span><span class="legend-key" style="background:var(--accent)"></span>Entry</span>
          <span><span class="legend-key" style="background:var(--up)"></span>Target</span>
          <span><span class="legend-key" style="background:var(--down)"></span>Stop</span>` : ''}
        </div>
      </div>

      <div>
        <div class="section-head"><h2 style="font-size:13px">The engine's read</h2>
          ${m.style ? `<span class="hint">weighted for a ${esc(m.style)} horizon</span>` : ''}</div>
        <div class="scores">
          ${[
            ['Trend', m.scores.trend, 'Where price sits against its 20-, 50- and 200-day averages, and which way the 50-day is sloping.'],
            ['Momentum', m.scores.momentum, 'Recent return, measured over the window this horizon actually trades in — days for a fast trade, months for a slow one.'],
            ['Entry quality', m.scores.entry, 'Whether this is a good price or a late one. Buying strength is fine; buying euphoria is not.'],
            ['Risk profile', m.scores.risk, 'How expensive the volatility and the drawdowns make this. Not disqualifying, just costly.'],
            ['Daily range', m.scores.range, 'Whether there is enough daily movement to trade quickly at all. An instrument that barely moves cannot cover the spread inside a session — and one that moves too far makes the stop a coin toss.'],
            ['Durability', m.scores.durability, 'Whether this would have survived being held: how deep the drawdowns ran, how rough the ride was, whether it holds its 200-day. Only a long horizon asks.'],
          ].filter(([, v]) => v != null)
            .map(([label, v, why]) => `<div class="score-row" title="${esc(why)}">
              <span class="dim">${label}</span>
              <div class="score-track"><div class="score-fill" style="width:${v}%;background:${scoreColor(v)}"></div></div>
              <span class="num dim">${v.toFixed(0)}</span></div>`).join('')}
        </div>
      </div>

      ${plan.rejected
        ? `<div class="note warn"><span class="note-icon">!</span><span><strong>No setup here.</strong> ${esc(plan.rejected)}</span></div>`
        : planBlock(plan, m)}

      <div class="metric-grid">
        ${[
          ['20-day avg', price(m.sma20, m.symbol)], ['50-day avg', price(m.sma50, m.symbol)], ['200-day avg', price(m.sma200, m.symbol)],
          ['RSI (14)', m.rsi14?.toFixed(0) ?? '—'], ['Daily range', plainPct(m.atrPct)], ['Ann. volatility', plainPct(m.vol30, 0)],
          ['1 month', pct(m.ret1mo, 1)], ['6 months', pct(m.ret6mo, 1)], ['1 year', pct(m.ret1y, 1)],
          ['From 52w high', plainPct(m.fromHigh52, 1)], ['Worst 1y drop', plainPct(m.drawdown1y, 0)],
          ['Conviction', m.conviction.toFixed(0) + '/100'],
        ].map(([l, v]) => `<div class="metric"><div class="metric-label">${l}</div><div class="metric-value">${v}</div></div>`).join('')}
      </div>

      <div>
        <div class="section-head"><h2 style="font-size:13px">Order ticket</h2>
          <span class="hint">Simulated. No order leaves this machine.</span></div>
        ${ticket(inst, q, plan, held)}
      </div>

      <div>
        <div class="section-head"><h2 style="font-size:13px">Explain this one</h2></div>
        <div id="explainSlot">
          <button class="btn" id="explainBtn" ${store.state.analyst.available ? '' : 'disabled'}>
            ${store.state.analyst.available ? 'Ask the analyst about ' + esc(inst.symbol) : 'Needs an ANTHROPIC_API_KEY'}
          </button>
        </div>
      </div>

      ${news?.length ? `<div>
        <div class="section-head"><h2 style="font-size:13px">Headlines</h2></div>
        ${news.map((n) => `<a class="news-item" href="${esc(safeUrl(n.url))}" target="_blank" rel="noopener noreferrer">
          <div class="news-title">${esc(n.title)}</div>
          <div class="news-meta">${esc(n.publisher)} · ${when(n.published)}</div></a>`).join('')}
      </div>` : ''}

      <p class="faint" style="font-size:11.5px;line-height:1.6">${esc(inst.note)}</p>
    </div>`;

  document.getElementById('pchart').append(
    priceChart(bars, { plan: plan.rejected ? null : plan, sma20: true, sma50: true, symbol: inst.symbol }),
  );

  drawer.querySelector('[data-close-drawer]').onclick = close;
  drawer.querySelectorAll('[data-range]').forEach((b) =>
    b.addEventListener('click', async () => {
      range = b.dataset.range;
      current = await api.getInstrument(inst.symbol, range);
      paint();
    }));
  wireTicket(inst, q, plan, held);
  document.getElementById('explainBtn')?.addEventListener('click', explain);
}

function planBlock(plan, m) {
  return `<div>
    <div class="section-head"><h2 style="font-size:13px">The plan</h2>
      <span class="hint">${plan.rr.toFixed(2)}:1 · breaks even at a ${plan.breakevenWinRate.toFixed(0)}% win rate</span></div>
    <div class="plan">
      <div class="plan-cell entry"><div class="plan-label">Entry</div>
        <div class="plan-price">${price(plan.entry, plan.symbol)}</div>
        <div class="plan-delta faint">${plan.entryKind === 'pullback' ? 'wait for a pullback' : 'at market'}</div></div>
      <div class="plan-cell target"><div class="plan-label">Target</div>
        <div class="plan-price up">${price(plan.target, plan.symbol)}</div>
        <div class="plan-delta up">${pct(plan.targetPct, 1)}</div></div>
      <div class="plan-cell stop"><div class="plan-label">Stop</div>
        <div class="plan-price down">${price(plan.stop, plan.symbol)}</div>
        <div class="plan-delta down">${pct(plan.stopPct, 1)}</div></div>
    </div>
    <div class="note" style="margin-top:10px"><span class="note-icon">›</span><span>
      Suggested size is ${plan.shares < 1 ? plan.shares.toFixed(4) : plan.shares.toFixed(2)} units
      (${money(plan.cost, 0)}), which risks ${money(plan.riskTaken, 0)} if the stop fills.
      ${plan.sizedBy === 'concentration' ? 'That is below the full risk budget: the single-position ceiling capped the size first.' : ''}
      ${plan.tightStop ? 'The stop is tighter than the default trend distance because overhead supply caps the target.' : ''}
    </span></div>
  </div>`;
}

function ticket(inst, q, plan, held) {
  // The amount field is dollars and the price is in the listing's own currency,
  // so the pre-fill goes through the rate — without it a kronor listing was
  // sized off a number ten times too large.
  const unitUsd = usdOf(q?.price || 0, inst.symbol) || 0;
  const suggested = plan.rejected
    ? (unitUsd ? Math.round((store.state.portfolio.equity * 0.05) / unitUsd * 100) / 100 : 0)
    : plan.shares;
  return `<div class="panel panel-pad">
    <div class="grid-2">
      <div class="field"><label for="tAmount">Amount to invest</label>
        <input type="number" id="tAmount" min="1" step="1" value="${Math.round((suggested || 0) * unitUsd)}"></div>
      <div class="field"><label for="tShares">Units</label>
        <input type="number" id="tShares" min="0" step="0.0001" value="${(suggested || 0).toFixed(4)}"></div>
      <div class="field"><label for="tTarget">Target (optional)</label>
        <input type="number" id="tTarget" step="0.01" value="${plan.rejected ? '' : plan.target.toFixed(2)}"></div>
      <div class="field"><label for="tStop">Stop (optional)</label>
        <input type="number" id="tStop" step="0.01" value="${plan.rejected ? '' : plan.stop.toFixed(2)}"></div>
    </div>
    <div id="ticketRisk" class="faint" style="font-size:11.5px;margin-top:10px"></div>
    <div class="btn-row" style="margin-top:12px">
      <button class="btn primary" id="buyBtn">Buy ${esc(inst.symbol)}</button>
      ${held ? `<button class="btn danger" id="sellBtn">Close position (${held.shares < 1 ? held.shares.toFixed(4) : held.shares.toFixed(2)} units)</button>` : ''}
    </div>
  </div>`;
}

function wireTicket(inst, q, plan, held) {
  const amount = document.getElementById('tAmount');
  const units = document.getElementById('tShares');
  const stop = document.getElementById('tStop');
  const riskLine = document.getElementById('ticketRisk');
  const px = q?.price || 0;
  const unitUsd = usdOf(px, inst.symbol) || 0;
  const valueOf = (n) => (unitUsd ? money(n * unitUsd, 0) : price(n * px, inst.symbol));

  const showRisk = () => {
    const n = Number(units.value);
    const s = Number(stop.value);
    const equity = store.state.portfolio.equity;
    if (n > 0 && s > 0 && s < px) {
      const risk = usdOf((px - s) * n, inst.symbol);
      riskLine.innerHTML = risk == null
        ? `If the stop fills you lose <strong style="color:var(--down)">${price((px - s) * n, inst.symbol)}</strong>. Position value ${valueOf(n)}.`
        : `If the stop fills you lose <strong style="color:var(--down)">${money(risk, 0)}</strong>,
        ${plainPct((risk / equity) * 100)} of the account. Position value ${valueOf(n)}.`;
    } else if (n > 0) {
      riskLine.innerHTML = `Position value ${valueOf(n)}. <strong style="color:var(--warn)">No stop set</strong>:
        without one the trade has no defined loss and no computed size.`;
    } else riskLine.textContent = '';
  };

  amount.addEventListener('input', () => { if (unitUsd) units.value = (Number(amount.value) / unitUsd).toFixed(4); showRisk(); });
  units.addEventListener('input', () => { if (unitUsd) amount.value = Math.round(Number(units.value) * unitUsd); showRisk(); });
  stop.addEventListener('input', showRisk);
  showRisk();

  document.getElementById('buyBtn').addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    const n = Number(units.value);
    const t = Number(document.getElementById('tTarget').value);
    const s = Number(stop.value);
    // Caught here, where the fields are, rather than as a server refusal after
    // the dialog has already been read and confirmed.
    if (!(n > 0)) return toast('Enter an amount or a number of units to buy.', 'err');
    if (s > 0 && s >= px) return toast(`A stop sits below the current price of ${price(px, inst.symbol)}.`, 'err');
    if (t > 0 && t <= px) return toast(`A target sits above the current price of ${price(px, inst.symbol)}.`, 'err');
    const confirmed = await confirmBuy({
      symbol: inst.symbol, shares: n, px,
      target: t > 0 ? t : null, stop: s > 0 ? s : null,
      refused: plan.rejected || null,
    });
    if (!confirmed) return;
    btn.disabled = true;
    try {
      await api.trade({
        action: 'buy', symbol: inst.symbol, shares: n,
        target: t > 0 ? t : null, stop: s > 0 ? s : null,
        thesis: plan.rejected ? 'Manual entry; the engine had refused this setup' : 'Manual entry on the engine plan',
      });
      toast(`Bought ${inst.symbol}.`);
      await refreshView();
      current = await api.getInstrument(inst.symbol, range);
      paint();
    } catch (err) { toast(err.message, 'err'); btn.disabled = false; }
  });

  document.getElementById('sellBtn')?.addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    if (!(await confirmClose(held))) return;
    btn.disabled = true;
    try {
      const { trade } = await api.trade({ action: 'sell', symbol: inst.symbol, reason: 'Closed from the instrument drawer' });
      toast(`Closed ${inst.symbol} — ${signedMoney(trade.pnl)}.`, trade.pnl > 0 ? 'ok' : 'info');
      await refreshView();
      close();
    } catch (err) { toast(err.message, 'err'); btn.disabled = false; }
  });
}

async function explain() {
  const slot = document.getElementById('explainSlot');
  slot.innerHTML = `<div class="row" style="gap:10px"><div class="spinner"></div>
    <span class="faint" style="font-size:12.5px">Reading the chart, the levels and the headlines…</span></div>`;
  try {
    const { brief } = await api.explain(current.instrument.symbol);
    if (!brief) { slot.innerHTML = `<div class="note warn"><span>The analyst returned nothing for this one.</span></div>`; return; }
    slot.innerHTML = `
      <div style="display:flex;flex-direction:column;gap:16px">
        <div class="pick-headline">${esc(brief.headline)}</div>
        <div class="explain-block"><div class="explain-label">What is happening</div><p class="prose">${esc(brief.what)}</p></div>
        <div class="explain-block"><div class="explain-label">Why it exists</div><p class="prose">${esc(brief.why)}</p></div>
        <div class="explain-block"><div class="explain-label">How it is run</div><p class="prose">${esc(brief.how)}</p></div>
        <div class="note warn"><span class="note-icon">!</span><span><strong>What would end it:</strong> ${esc(brief.invalidation)}</span></div>
        ${brief.jargon?.length ? `<div class="jargon">${brief.jargon.map((j) =>
          `<div class="jargon-item"><span class="jargon-term">${esc(j.term)}</span> — ${esc(j.plain)}</div>`).join('')}</div>` : ''}
      </div>`;
  } catch (err) {
    slot.innerHTML = `<div class="note warn"><span>${esc(err.message)}</span></div>`;
  }
}
