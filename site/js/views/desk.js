/** Desk — what you own, what it is doing, and where the plan stands. */

import { store, toast, refreshView } from '../app.js';
import * as api from '../api.js';
import { money, signedMoney, signedR, price, pct, plainPct, shares, dir, esc, when, compact, sub, subSigned, subInline } from '../format.js';
import { equityChart } from '../chart.js';
import { morph } from '../morph.js';
import { modal } from '../modal.js';
import { confirmClose } from '../tickets.js';
import { term, aside, isPlain } from '../glossary.js';

export async function renderDesk(host) {
  const s = store.state;
  const p = s.portfolio;
  const invested = p.invested;
  const exposure = p.equity ? (invested / p.equity) * 100 : 0;

  /* The desk is redrawn on every price poll, and it is the longest screen in the
   * app — rebuilt whole it blinks, drops the scroll position of the positions
   * table and redraws a chart that has not changed. Patched, only the figures
   * that moved move. */
  morph(host, `
    <section class="view">
      ${rundown(s)}
      <div class="panel">
        <div class="stat-grid">
          <div class="stat">
            <span class="stat-label">${term('equity', 'Account equity')}</span>
            <span class="stat-value">${money(p.equity)}</span>
            ${sub(p.equity)}
            <span class="stat-note">from ${money(s.startingCash, 0)} starting capital</span>
          </div>
          <div class="stat">
            <span class="stat-label">Total P/L</span>
            <span class="stat-value ${dir(p.totalPnl)}">${signedMoney(p.totalPnl)}</span>
            ${subSigned(p.totalPnl)}
            <span class="stat-note ${dir(p.totalPnlPct)}">${pct(p.totalPnlPct)}</span>
          </div>
          <div class="stat">
            <span class="stat-label">Today</span>
            <span class="stat-value ${dir(p.dayPnl)}">${signedMoney(p.dayPnl)}</span>
            ${subSigned(p.dayPnl)}
            <span class="stat-note">across open positions</span>
          </div>
          <div class="stat">
            <span class="stat-label">${term('cash', 'Cash')}</span>
            <span class="stat-value">${money(p.cash)}</span>
            ${sub(p.cash)}
            <span class="stat-note">${plainPct(exposure, 0)} of equity invested</span>
          </div>
          <div class="stat" title="Money the account made, with deposits stripped out.">
            <span class="stat-label">From trading</span>
            <span class="stat-value ${dir(p.netOfContributions)}">${signedMoney(p.netOfContributions)}</span>
            ${subSigned(p.netOfContributions)}
            <span class="stat-note">${p.totalContributed > 0 ? `${money(p.totalContributed, 0)} paid in since` : 'no contributions set'}</span>
          </div>
          <div class="stat">
            <span class="stat-label">Open positions</span>
            <span class="stat-value">${p.positions.length}<span class="faint" style="font-size:13px"> / ${s.profile.maxOpenPositions}</span></span>
            <span class="stat-note">${p.positions.filter((x) => x.stop != null).length} with a stop set</span>
          </div>
          <div class="stat" title="What would be lost if every open stop filled at once.">
            <span class="stat-label">${term('heat', 'Risk on')}</span>
            <span class="stat-value ${p.heatPct > s.suitability.maxHeatPct ? 'down' : ''}">${plainPct(p.heatPct, 1)}</span>
            <span class="stat-note">${money(p.openRisk, 0)}${subInline(p.openRisk)} of ${plainPct(s.suitability.maxHeatPct, 1)} allowed</span>
          </div>
        </div>
        <div class="chart-wrap" id="eq" data-keep data-curve="${s.equityCurve.length}:${s.equityCurve[s.equityCurve.length - 1]?.equity ?? 0}:${s.startingCash}"></div>
        <div class="chart-legend">
          <span><span class="legend-key" style="background:${p.totalPnl >= 0 ? 'var(--up)' : 'var(--down)'}"></span>Equity</span>
          <span><span class="legend-key" style="background:var(--text-faint)"></span>Starting capital</span>
          <span class="faint">Each point is one hourly reading while the desk was open.</span>
        </div>
      </div>

      <div class="section-head" style="margin-top:26px">
        <h2>Open positions</h2>
        <span class="hint">The marker shows where price sits between your stop and your target.</span>
      </div>
      ${p.positions.length === 0 ? emptyPositions(s) : positionsTable(p.positions)}

      ${riskPanel(s)}

      <div class="section-head" style="margin-top:26px"><h2>Recent activity</h2></div>
      ${activity(s.trades.slice(0, 8))}
    </section>

    <div class="disclaimer">
      Paper is a training simulator. Prices are real and delayed; the money is not. Nothing here is a
      recommendation to buy or sell a real security, no order reaches a market, and no brokerage account is
      connected. Simulated results do not predict real ones: a paper fill always happens at the price asked
      for, and a real one often does not.
    </div>`);

  /* Drawn once and left alone until the curve itself moves. The chart is built
   * node by node rather than from markup, so it is the one part of this screen a
   * repaint cannot patch — redrawing it every thirty seconds was a visible flash
   * in the middle of the desk for a line that only changes when a day closes or a
   * position is marked. */
  const chart = document.getElementById('eq');
  if (chart && chart.dataset.drawn !== chart.dataset.curve) {
    chart.replaceChildren(equityChart(s.equityCurve, s.startingCash));
    chart.dataset.drawn = chart.dataset.curve;
  }
  wire();
}

/**
 * The whole account in a paragraph, before any of the numbers.
 *
 * A dashboard of eight figures is not a summary — it is eight things to work out,
 * and someone new works out none of them. This says where the account stands, what
 * it is exposed to and what the sensible next move is, in sentences, from state
 * the app already has. It is deterministic: no model runs to produce it, so it is
 * always there and always says the same thing about the same numbers.
 */
function rundown(s) {
  const p = s.portfolio;
  const cur = currencyNote(s);
  const lines = [];

  if (!p.positions.length) {
    lines.push(`Nothing is open. The account holds ${money(p.equity, 0)}, all of it in cash.`);
  } else {
    const stopped = p.positions.filter((x) => x.stop != null).length;
    lines.push(`${p.positions.length} position${p.positions.length === 1 ? '' : 's'} open, worth ${money(p.invested, 0)}. That is ${plainPct((p.invested / Math.max(p.equity, 1)) * 100, 0)} of the account invested, with ${money(p.cash, 0)} in cash.`);
    lines.push(stopped === p.positions.length
      ? `All of them have a stop, so ${money(p.openRisk, 0)} is the most they can lose together: ${plainPct(p.heatPct, 1)} of the account against the ${plainPct(s.suitability.maxHeatPct, 1)} this profile allows.`
      : `${p.positions.length - stopped} of them ${p.positions.length - stopped === 1 ? 'has' : 'have'} no stop, so that part of the account has no defined risk and no size check.`);
  }

  const traded = p.netOfContributions;
  if (p.totalContributed > 0) {
    lines.push(`${money(p.totalContributed, 0)} has been paid in since the account opened. Excluding deposits, the trading itself has ${traded >= 0 ? 'made' : 'lost'} ${money(Math.abs(traded), 0)}.`);
  } else if (Math.abs(p.totalPnl) > 0) {
    lines.push(`The trading has ${p.totalPnl >= 0 ? 'made' : 'lost'} ${money(Math.abs(p.totalPnl), 0)} so far, ${pct(p.totalPnlPct)} on the starting capital.`);
  }

  const sc = s.scorecard;
  if (sc?.closedTrades >= 3) {
    lines.push(`${sc.closedTrades} trades have been closed${sc.expectancyR != null ? `, worth ${sc.expectancyR >= 0 ? '+' : ''}${sc.expectancyR.toFixed(2)} times the amount risked on average. ${sc.expectancyR >= 0 ? 'Positive expectancy pays out over enough trades' : 'Negative expectancy means repeating the method costs money'}` : ''}.`);
  }

  const next = nextMove(s);
  if (cur) lines.push(cur);

  return `<div class="rundown">
    <div class="rundown-head">
      <span class="rundown-label">Where you stand</span>
      <span class="spacer"></span>
      ${s.learning?.proposed ? `<button class="chip warn" data-goto="learning">${s.learning.proposed} proposed change${s.learning.proposed === 1 ? '' : 's'}</button>` : ''}
      <span class="rundown-profile">${esc(s.profile.name)} · ${esc(s.profile.horizon.split(' —')[0])}</span>
    </div>
    <p class="prose">${lines.join(' ')}</p>
    ${next ? `<div class="rundown-next"><span class="note-icon">›</span><span>${next}</span></div>` : ''}
  </div>`;
}

/** The FX sentence, only where there is one to say. */
/**
 * Said once, under the numbers: what the second figure is, and what it is not.
 *
 * The exposure sentence is the part that matters. Someone reading kronor under
 * every dollar amount can slide into thinking the account holds kronor, and it
 * does not — it holds dollars, and the rate moving is a real gain or loss to
 * anyone whose life is priced in something else.
 *
 * It used to end "nothing is held, priced or ordered in kronor", which stopped
 * being true the moment Stockholm arrived: a Volvo position is quoted, stopped
 * and ordered in kronor, and only the account it settles into is dollars. So the
 * note now counts what is actually held in a foreign currency and says which of
 * the two situations this account is in, rather than asserting the simpler one.
 */
function currencyNote(s) {
  if (!s.fx || s.currency === 'USD') return '';
  const rate = s.fx.perUSD?.[s.currency];
  if (!rate) return '';
  const exposure = s.foreignExposureUSD ?? 0;
  const held = (s.portfolio?.positions ?? []).filter((x) => x.currency && x.currency !== 'USD');
  const heldIn = [...new Set(held.map((x) => x.currency))];

  const opening = `Every figure above is in US dollars. The smaller ≈ line is the same amount in `
    + `${esc(s.currency)} at ${rate.toFixed(2)} per dollar${s.fx.live ? '' : ', a standing estimate while the rate feed is unreachable'}, `;

  const base = heldIn.length
    ? `${opening}shown for reading only. Prices are a separate matter: `
      + `${held.length === 1 ? `${esc(held[0].symbol)} is` : `${held.length} of these positions are`} `
      + `quoted, stopped and ordered in ${esc(heldIn.join(' and '))}, and the account converts at the fill and at the mark.`
    : `${opening}shown for reading only: every position here is quoted and settled in dollars.`;

  if (exposure <= 0) return base;
  return `${base} A real ${esc(s.currency)} account holding these positions would also carry ${money(exposure, 0)} `
    + `of dollar exposure, which moves the profit independently of the positions.`;
}

/**
 * One concrete next action, chosen from the state rather than offered as a menu.
 * The ordering is by what would matter most, not by what is easiest to suggest.
 */
function nextMove(s) {
  const p = s.portfolio;
  const naked = p.positions.filter((x) => x.stop == null);
  if (naked.length) {
    return `<strong>${esc(naked[0].symbol)} has no stop.</strong> Click it and set one. Without a stop the position has no defined risk and no size check against the account limit.`;
  }
  if (p.heatPct > s.suitability.maxHeatPct) {
    return `<strong>Total open risk is over the limit.</strong> ${plainPct(p.heatPct, 1)} is at stake against the ${plainPct(s.suitability.maxHeatPct, 1)} this profile allows. Closing or trimming one position brings it back inside.`;
  }
  if (s.learning?.proposed) {
    return `<strong>${s.learning.proposed} proposed change${s.learning.proposed === 1 ? '' : 's'}</strong> from what your closed trades have shown. <button class="btn sm" data-goto="learning">Read them</button>`;
  }
  if (!p.positions.length && !s.trades?.length) {
    return `Start with the <strong>Analyst</strong>. It reads every instrument on the board, refuses most of them, and returns entry, target, stop and size for the few that clear the bar. <button class="btn sm" data-goto="analyst">Run it</button>`;
  }
  if (s.scorecard?.closedTrades >= 3) {
    return `${s.scorecard.closedTrades} closed trades. The <strong>Review</strong> measures what each one did after you sold it. <button class="btn sm" data-goto="analyst">Open it</button>`;
  }
  return '';
}

function emptyPositions(s) {
  return `<div class="panel"><div class="empty">
    <div class="empty-title">Nothing open yet</div>
    <div class="empty-sub">
      You have ${money(s.cash ?? s.portfolio.cash, 0)} of simulated capital. Run the
      <strong>Analyst</strong> to get worked trade ideas with entries, targets and stops, or open
      <strong>Markets</strong> and pick something yourself.
    </div>
    <div class="btn-row" style="margin-top:6px">
      <button class="btn primary" data-goto="analyst">Run the analyst</button>
      <button class="btn" data-goto="markets">Browse markets</button>
      <button class="btn ghost" data-settings="risk">Change the settings</button>
    </div>
  </div></div>`;
}

function positionsTable(positions) {
  return `<div class="panel scroll-x"><table>
    <thead><tr>
      <th>Instrument</th><th class="right">Size</th><th class="right">Avg cost</th>
      <th class="right">Last</th><th class="right">Market value</th><th class="right">Open P/L</th>
      <th>Plan</th><th></th>
    </tr></thead>
    <tbody>${positions.map(posRow).join('')}</tbody>
  </table></div>`;
}

/**
 * `fxPnl` is the part of the profit the exchange rate is responsible for.
 *
 * Only ever present on a holding quoted in something other than dollars, and
 * worth its line when it is: an account that settles in dollars and holds a
 * kronor asset carries the currency whether it meant to or not, and a position
 * can be up in kronor and down in dollars on the same afternoon. Splitting it out
 * is the difference between a lesson and a number that makes no sense.
 */
function fxLine(x) {
  if (x.fxPnl == null || Math.abs(x.fxPnl) < 0.5) return '';
  const share = x.fxPnl >= 0 ? 'of that gain' : 'against it';
  return `<br><span class="faint" style="font-size:10.5px"
    title="Prices for ${esc(x.symbol)} are in ${esc(x.currency)}. The account settles in dollars, so the rate moves the result alongside the stock.">
    ${signedMoney(x.fxPnl)} ${share} is the ${esc(x.currency)}</span>`;
}

function posRow(x) {
  const hasBracket = x.target != null && x.stop != null;
  const prog = x.bracketProgress ?? 0.5;
  return `<tr class="pos-row clickable" data-symbol="${esc(x.symbol)}">
    <td><div class="sym"><span class="sym-ticker">${esc(x.symbol)}</span>
      <span class="sym-name">opened ${when(x.openedAt)}${x.longTermQualified ? ' · long-term rate' : ''}${x.currency && x.currency !== 'USD' ? ` · ${esc(x.currency)}` : ''}</span></div></td>
    <td class="right num">${shares(x.shares)}</td>
    <td class="right num">${price(x.avgPrice, x.symbol)}</td>
    <td class="right num">${price(x.price, x.symbol)}</td>
    <td class="right num">${money(x.value)}${sub(x.value)}</td>
    <td class="right num ${dir(x.pnl)}">${signedMoney(x.pnl)}<br>
      <span style="font-size:11.5px">${pct(x.pnlPct)}</span>
      ${x.openRisk ? `<br><span class="faint" style="font-size:10.5px">${money(x.openRisk, 0)} at risk</span>` : ''}
      ${fxLine(x)}</td>
    <td style="min-width:150px">
      ${hasBracket ? `
        <div class="bracket" style="--p:${prog}"></div>
        <div class="bracket-labels"><span>${price(x.stop, x.symbol)}</span><span>${price(x.target, x.symbol)}</span></div>`
      : `<span class="chip warn">No exit plan</span>`}
    </td>
    <td class="right">
      <div class="btn-row" style="justify-content:flex-end">
        <button class="btn sm" data-bracket="${esc(x.symbol)}">Exits</button>
        <button class="btn sm danger" data-close="${esc(x.symbol)}">Close</button>
      </div>
    </td>
  </tr>`;
}

function riskPanel(s) {
  const sui = s.suitability;
  const f = s.profile.frictions;
  return `<div class="section-head" style="margin-top:26px">
      <h2>How this account is run</h2>
      <span class="hint">Set on the Profile tab. Every line is enforced.</span>
      <span class="spacer"></span>
      <button class="btn sm" data-settings="risk">Change the settings</button>
    </div>
    <div class="panel">
      <div class="stat-grid">
        <div class="stat"><span class="stat-label">Risk per trade</span>
          <span class="stat-value ${sui.capped ? 'warn-text' : ''}">${sui.effectiveRiskPct.toFixed(2)}%</span>
          <span class="stat-note">${sui.capped
            ? `capped from ${sui.statedRiskPct.toFixed(2)}% for suitability`
            : `${money(s.portfolio.equity * (sui.effectiveRiskPct / 100), 0)}${subInline(s.portfolio.equity * (sui.effectiveRiskPct / 100))} if the stop fills`}</span></div>
        <div class="stat"><span class="stat-label">Single position ceiling</span>
          <span class="stat-value">${s.profile.maxPositionPct}%</span>
          <span class="stat-note">of equity, at most</span></div>
        <div class="stat"><span class="stat-label">Horizon</span>
          <span class="stat-value" style="font-size:15px">${esc(s.profile.horizon.split(' —')[0])}</span>
          <span class="stat-note">${esc(s.profile.goal)}</span></div>
        <div class="stat"><span class="stat-label">Costs to date</span>
          <span class="stat-value">${money(p_costs(s), 0)}</span>
          <span class="stat-note">spread, commission and tax</span></div>
      </div>
      ${sui.capped ? `<div class="panel-pad" style="border-top:1px solid var(--line)">
        <div class="note warn"><span class="note-icon">!</span><span>${esc(sui.note)}</span></div>
      </div>` : ''}
      <div class="panel-pad" style="border-top:1px solid var(--line)">
        <div class="row wrap" style="gap:7px">
          <span class="chip ${s.session.equityMarketOpen ? 'up' : 'ghost'}">
            <span class="regime-dot" style="background:${s.session.equityMarketOpen ? 'var(--up)' : 'var(--text-faint)'}"></span>
            ${esc(s.session.note)}</span>
          ${s.session.dayTradesLeft != null ? `<span class="chip ${s.session.dayTradesLeft === 0 ? 'down' : 'warn'}"
            title="Under $25,000 a US margin account gets three day trades in five business days.">
            ${s.session.dayTradesLeft} day trade${s.session.dayTradesLeft === 1 ? '' : 's'} left this week</span>` : ''}
          <span class="chip ghost">${f.commissionPerTrade > 0 ? `$${f.commissionPerTrade.toFixed(2)} per order`
            : f.commissionPctOfValue > 0 ? `${f.commissionPctOfValue}% commission` : 'commission-free'}</span>
          <span class="chip ghost" title="Gains realised inside ${f.longTermHoldingDays} days are taxed at the higher rate, withheld at the sale.">
            tax ${f.shortTermTaxPct}% / ${f.longTermTaxPct}%</span>
        </div>
      </div>
      ${s.contributions.length ? `<div class="panel-pad" style="border-top:1px solid var(--line)">
        <span class="faint" style="font-size:12px">Last paid in ${when(s.contributions[0].at)}:
          ${money(s.contributions[0].amount, 0)}. ${esc(s.contributions[0].note)}</span>
      </div>` : ''}
    </div>`;
}

/** Everything the account has given up to frictions, in one number. */
function p_costs(s) {
  return s.scorecard.totalCommission + s.scorecard.totalSlippage + s.scorecard.totalTax;
}

function activity(trades) {
  if (!trades.length) {
    return `<div class="panel"><div class="empty"><div class="empty-sub">No trades yet.</div></div></div>`;
  }
  return `<div class="panel scroll-x"><table>
    <thead><tr><th>When</th><th>Action</th><th class="right">Size</th><th class="right">Price</th>
      <th class="right">Result</th><th>Why</th></tr></thead>
    <tbody>${trades.map((t) => `<tr>
      <td class="faint" style="white-space:nowrap">${when(t.at)}</td>
      <td><span class="chip ${t.action === 'buy' ? 'accent' : t.pnl > 0 ? 'up' : t.pnl < 0 ? 'down' : 'ghost'}">
        ${t.action === 'buy' ? 'Bought' : 'Sold'} ${esc(t.symbol)}</span>
        ${t.trigger === 'target' ? '<span class="chip up" style="margin-left:5px">target</span>' : ''}
        ${t.trigger === 'stop' ? '<span class="chip down" style="margin-left:5px">stop</span>' : ''}</td>
      <td class="right num">${shares(t.shares)}</td>
      <td class="right num">${price(t.price, t.symbol)}</td>
      <td class="right num ${dir(t.pnl)}">${t.pnl == null ? '—' : signedMoney(t.pnl)}
        ${t.rMultiple != null ? `<br><span style="font-size:11px" class="faint">${t.rMultiple >= 0 ? '+' : ''}${t.rMultiple.toFixed(2)}R</span>` : ''}</td>
      <td class="dim" style="max-width:340px;font-size:12.5px">${esc(t.reason)}</td>
    </tr>`).join('')}</tbody></table></div>`;
}

/* ----------------------------------------------------------------- wiring */

function wire() {
  // Delegated: the desk repaints after every trade, so per-node listeners are
  // bound to elements that no longer exist by the time anyone clicks them.
  const host = document.getElementById('main');
  if (!host.dataset.deskBound) {
    host.dataset.deskBound = '1';
    host.addEventListener('click', (e) => {
      // data-goto and data-settings are handled once, globally, in app.js.
      const close$ = e.target.closest('[data-close]');
      if (close$) return closePosition(e, close$);
      const bracket$ = e.target.closest('[data-bracket]');
      if (bracket$) return editBracket(e, bracket$);
    });
  }
}

async function closePosition(e, b) {
      e.stopPropagation();
      const sym = b.dataset.close;
      const pos = store.state.portfolio.positions.find((x) => x.symbol === sym);
      if (pos && !(await confirmClose(pos))) return;
      b.disabled = true;
      try {
        const { trade } = await api.trade({ action: 'sell', symbol: sym, reason: 'Closed manually from the desk' });
        // A loss is a result, not a failure — `err` is kept for things that broke.
        toast(`Closed ${sym} — ${signedMoney(trade.pnl)}${trade.rMultiple != null ? ` (${signedR(trade.rMultiple)})` : ''}.`,
          trade.pnl > 0 ? 'ok' : 'info');
        await refreshView();
      } catch (err) {
        toast(err.message, 'err');
        b.disabled = false;
      }
}

async function editBracket(e, b) {
      e.stopPropagation();
      const sym = b.dataset.bracket;
      const pos = store.state.portfolio.positions.find((x) => x.symbol === sym);
      const res = await modal({
        title: `Exit plan — ${sym}`,
        confirmText: 'Save exit plan',
        body: `<p>Last traded ${price(pos?.price, pos?.symbol)}, average cost ${price(pos?.avgPrice, pos?.symbol)}.
          Leave a field empty to remove that leg. A position without a stop has no defined loss.</p>`,
        fields: [
          { name: 'target', label: 'Target', value: pos?.target ?? '', hint: 'price at which the gain is taken' },
          { name: 'stop', label: 'Stop', value: pos?.stop ?? '', hint: 'price at which the trade is wrong' },
        ],
      });
      if (!res) return;
      try {
        await api.setBracket({
          symbol: sym,
          target: res.target === '' ? null : Number(res.target),
          stop: res.stop === '' ? null : Number(res.stop),
        });
        toast(`Exit plan updated for ${sym}.`);
        await refreshView();
      } catch (err) { toast(err.message, 'err'); }
}
