/**
 * predict.js — Polymarket's five-minute Bitcoin market, watched automatically.
 *
 * Every other tab in Paper is something you do. This one is something that
 * happens: you set a bankroll and a length of time and then the desk reads the
 * tape and the book on its own and buys when it finds a gap worth the spread. So
 * the screen is not arranged around a button. It is arranged around the two
 * questions you actually have while it runs — *what does it think about the window
 * on the clock right now*, and *why did it not bet* — with the bets themselves
 * third, because on a good run there are very few of them.
 *
 * The one number given more room than the P/L is how closely Paper's own Bitcoin
 * feed matches the one Polymarket settles on. It is the ceiling on everything else
 * here and it is not close to 100%, and a screen that buried it would be selling
 * the same false confidence the rest of this app exists to argue against.
 */

import { store, toast, refreshView } from '../app.js';
import { morph } from '../morph.js';
import * as api from '../api.js';
import { money, signedMoney, dir, esc, subSigned, dateTime } from '../format.js';
import { aside } from '../glossary.js';

let panel = null;
let journal = null;
let audit = null;
let poll = null;
let working = false;

/**
 * Unlike the other tabs this one never paints from cache alone.
 *
 * The desk keeps running server-side while you are on another tab, so a cached
 * panel is not merely stale — it can say "no run is open" about a run that has
 * been betting for twenty minutes, which is what it did the first time this was
 * wired up. What is cached is used to paint instantly, and then replaced.
 */
export async function renderPredict(host, { force } = {}) {
  if (panel && !force) paint(host);
  panel = await api.getPredict().catch(() => panel);
  paint(host);
  startPolling(host);
  /* Fetched after the first paint rather than alongside it. The record reads three
   * files and scores every window on them, and none of it changes inside a
   * five-minute market — making the screen wait on it would delay the one part of
   * this tab that is genuinely live. */
  journal = await api.getPredictJournal().catch(() => journal);
  paint(host);
  /* The audit last, and only once per visit. It refits six logistic models five
   * times each over the whole book, which is the most expensive thing this tab
   * can ask for and the least urgent — it answers "is this learning", and that
   * answer does not change inside a five-minute market. */
  audit = await api.getPredictAudit().catch(() => audit);
  paint(host);
}

/* The desk runs server-side whether or not this tab is open — the poll is only
 * how the screen finds out. Ten seconds matches the desk's own tick, so what is
 * shown is never more than one decision behind what it did. */
function startPolling(host) {
  stopPolling();
  poll = setInterval(async () => {
    if (store.view !== 'predict' || document.hidden) return;
    try {
      const before = panel?.run?.status;
      panel = await api.getPredict();
      paint(host);
      if (before === 'running' && panel?.run?.status !== 'running') {
        journal = await api.getPredictJournal().catch(() => journal);
        await refreshView();
      }
    } catch { /* a dropped poll is not a failed run */ }
  }, panel?.run?.status === 'running' ? 2_000 : 10_000);
}

function stopPolling() {
  if (poll) { clearInterval(poll); poll = null; }
}

const cents = (p) => (p == null ? '—' : `${(p * 100).toFixed(1)}¢`);
const bps = (n) => (n == null ? '—' : `${n >= 0 ? '+' : ''}${n.toFixed(1)} bps`);

/* Derived here rather than read off the response, because Swift's synthesised
 * Codable does not encode a computed property — `maxStake` and a bet's `won` both
 * exist on the engine's types and neither ever crosses the wire. Asking for them
 * gives `undefined`, which renders as an em-dash and a permanent nil record on a
 * screen where everything else is right. */
const maxStake = (r) => (r.bankroll * r.maxStakePct) / 100;
const settled = (b) => b.settledAt != null;
const won = (b) => (b.resolved == null ? null : b.resolved === b.side);

function clock(seconds) {
  const s = Math.max(0, Math.round(seconds ?? 0));
  const m = Math.floor(s / 60);
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}:${String(s % 60).padStart(2, '0')}`;
}

function paint(host) {
  if (!panel) {
    morph(host, `<section class="view"><div class="panel"><div class="empty">
      <div class="empty-title">The prediction desk could not be reached</div>
      <div class="empty-sub">Polymarket and the Bitcoin feed are both public and keyless, so this is
        usually the network rather than the app.</div></div></div></section>`);
    return;
  }

  const run = panel.run;
  /* Ten seconds is a short interval to rebuild a screen on, so this patches the
   * one that is already there rather than replacing it: the prices and the clock
   * move, the settings being typed into underneath them do not. */
  morph(host, `<section class="view">
    ${run ? live(panel) : setup(panel)}
    ${learningAudit(audit)}
    ${record(journal)}
  </section>`);
  wire(host);
  tickClocks();
}

/* ------------------------------------------------------------------ shared */

/** The caveat that governs everything else on this screen. */
function fidelityNote(p) {
  const fd = p.fidelity;
  if (!fd) return '';
  const fh = p.feedHealth;
  const rate = fd.windows ? Math.round((fd.agreed / fd.windows) * 100) : null;
  const warn = fd.assumed || (rate != null && rate < 80) || fh?.degraded;
  return `<div class="note ${warn ? 'warn' : ''}" style="margin-bottom:18px">
    <span class="note-icon">!</span><span>
    <strong>Paper is not reading the exact feed this market settles on.</strong>
    Polymarket resolves these windows from Chainlink's BTC/USD 60-second TWAP stream, which is not
    public. Chainlink is a median of independent reads across the major spot venues, so Paper reads the
    venues directly — Coinbase and Kraken over live sockets, consolidated once a second. Both quote real
    dollars, which is what rules out the deeper USDT books: the peg wanders a few basis points and this
    is a measurement that cares about single ones. ${esc(fd.summary)}
    Every probability on this screen has that remaining gap built into it, and settlement still comes
    from Polymarket's published result rather than from Paper's own reading of the price.</span></div>`;
}

/**
 * Which venues are actually live.
 *
 * On the screen because a run that quietly dropped to the polled Yahoo fallback is
 * running a materially different strategy from the one that was started: that feed
 * carries the eleven-basis-point gap the model is scaled by, which is the term that
 * decides whether the model gets any voice against the market at all.
 */
function feedPanel(p) {
  const fh = p.feedHealth;
  if (!fh) return '';
  const pill = (name, live) =>
    `<span class="predict-venue ${live ? 'live' : 'out'}">${esc(name)}</span>`;
  const all = [...(fh.connected ?? []).map((v) => [v, true]),
               ...(fh.stale ?? []).map((v) => [v, false])];
  const NAMES = { coinbase: 'Coinbase', kraken: 'Kraken' };
  return `<div class="panel panel-pad" style="margin-bottom:18px">
    <div class="section-head" style="margin:0 0 10px">
      <h2 style="font-size:15px">The tape</h2>
      <span class="spacer"></span>
      <span class="num dim">${fh.samplesPerMinute ?? 0}/min</span>
    </div>
    <div style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:10px">
      ${all.map(([v, live]) => pill(NAMES[v] ?? v, live)).join('')}
    </div>
    <div class="hint ${fh.degraded ? 'warn-text' : ''}">${esc(fh.summary ?? '')}</div>
  </div>`;
}

/**
 * The three numbers the desk has taught itself, and how much evidence each stands on.
 *
 * Shown with its sample size rather than alone, because "25% model weight" and
 * "25% model weight, which is the shipped default because only forty windows have
 * resolved" are different claims and only the second one is honest.
 */
function brainPanel(p) {
  const b = p.brain;
  if (!b) return '';
  const row = (label, value, isDefault, n, need, unit) => `<div class="predict-skip">
    <span>${esc(label)}${isDefault ? ' <span class="faint">— shipped default</span>' : ''}</span>
    <span class="num ${isDefault ? 'dim' : ''}">${esc(value)}${esc(unit ?? '')}
      <span class="faint">${n}/${need}</span></span>
  </div>`;
  return `<div class="panel panel-pad" style="margin-top:14px">
    <div class="metric-label" style="margin-bottom:10px">What the desk has learned</div>
    ${row('Gap to the resolver', b.feedNoiseBps.toFixed(1), b.feedIsDefault,
          b.feedWindows, 30, ' bps')}
    ${row('Weight the model is allowed', (b.modelWeight * 100).toFixed(1), b.weightIsDefault,
          b.weightWindows, 100, '%')}
    ${/* While this is still the shipped default, the number in force is the one the
          run was opened with, not the one sitting in the brain file — which may have
          been written before the default itself changed, and was showing 150 beside a
          run entering at 90. */''}
    ${row('Entry into the window',
          (b.offsetIsDefault ? (p.effectiveEntryOffset ?? b.entryOffsetSeconds) : b.entryOffsetSeconds).toFixed(0),
          b.offsetIsDefault, b.offsetSamples, 40, 's')}
    <div class="hint" style="margin-top:10px">${esc(b.summary ?? '')}</div>
    <div class="hint faint" style="margin-top:6px">Every window the desk watches is written down with
      what it thought and what the market was pricing, and the answer is filled in when Polymarket
      publishes it — whether or not anything was bought. A run that correctly declines all six of its
      windows still leaves six labelled examples behind, which is what these three are fitted from.</div>
  </div>`;
}

/** The current five-minute window: the clock, the two prices, and the model. */
function windowPanel(p) {
  const fc = p.forecast;
  const left = p.windowSecondsLeft ?? 0;
  const done = Math.min(100, Math.max(0, ((300 - left) / 300) * 100));

  return `<div class="panel panel-pad">
    <div class="section-head" style="margin:0 0 14px">
      <h2 style="font-size:15px">${esc(p.windowLabel ?? 'the current window')}</h2>
      <span class="hint">${esc(p.question ?? 'Bitcoin Up or Down, five minutes')}</span>
      <span class="spacer"></span>
      <span class="num dim">${clock(left)}</span>
    </div>
    <div class="score-track" style="margin-bottom:16px">
      <div class="score-fill" style="width:${done}%;background:var(--accent)"></div>
    </div>

    <div class="predict-sides">
      ${sideCard('Up', p.upAsk, p.upBid, p.bookDepthUp, fc ? fc.pUp : null)}
      ${sideCard('Down', p.downAsk, p.downBid, p.bookDepthDown, fc ? 1 - fc.pUp : null)}
    </div>

    ${fc ? forecastBreakdown(fc) : `<div class="empty" style="padding:22px 0">
      <div class="empty-sub">No forecast yet — the model needs twenty minutes of Bitcoin data behind it
        before it will say anything.</div></div>`}
  </div>`;
}

function sideCard(label, ask, bid, depth, model) {
  const gap = model != null && ask != null ? model - ask : null;
  const cls = gap == null ? 'flat' : gap > 0 ? 'up' : 'down';
  return `<div class="predict-side">
    <div class="predict-side-head">
      <span class="predict-side-name">${label}</span>
      <span class="faint">${depth != null ? `${Math.round(depth).toLocaleString()} offered` : ''}</span>
    </div>
    <div class="predict-side-price">${cents(ask)}</div>
    <div class="predict-side-meta">
      <span title="The best bid and offer on Polymarket's own book right now.">bid ${cents(bid)}</span>
      <span class="${cls}" title="Paper's probability for this outcome once the market's own price has been folded in, against what the contract costs. Positive is the edge the run is looking for.">fair ${cents(model)}${gap != null ? ` · ${gap >= 0 ? '+' : ''}${(gap * 100).toFixed(1)}¢` : ''}</span>
    </div>
  </div>`;
}

/**
 * The forecast, taken apart.
 *
 * Shown as four numbers and a sentence rather than a probability alone, because
 * the probability is the least interesting part: the signal and the two kinds of
 * uncertainty are what explain why a window that obviously moved up is still only
 * a sixty-percent call.
 */
function forecastBreakdown(fc) {
  const settled = Math.round(fc.settled * 100);
  return `
    <div class="metric-grid" style="grid-template-columns:repeat(auto-fit,minmax(118px,1fr));margin-top:18px">
      <div class="metric">
        <div class="metric-label" title="Where the window's time-weighted average lands if the price simply stays where it is. The market resolves Up if this finishes at or above the opening price.">Projected average</div>
        <div class="metric-value" style="font-size:16px">${fc.projectedTwap.toLocaleString(undefined, { maximumFractionDigits: 0 })}</div>
        <div class="metric-label">open ${fc.openPrice.toLocaleString(undefined, { maximumFractionDigits: 0 })}</div>
      </div>
      <div class="metric">
        <div class="metric-label" title="How far the projected average sits from the opening price, in hundredths of a percent. This is the whole signal.">Signal</div>
        <div class="metric-value ${dir(fc.signalBps)}" style="font-size:16px">${bps(fc.signalBps)}</div>
      </div>
      <div class="metric">
        <div class="metric-label" title="How far the rest of the window could still move the average. Shrinks as the window runs out.">Bitcoin may still move</div>
        <div class="metric-value" style="font-size:16px">±${Math.round(fc.pathSd).toLocaleString()}</div>
      </div>
      <div class="metric">
        <div class="metric-label" title="How far Paper's Bitcoin feed may be from the one the market settles on. This does not shrink as the window runs out — watching more carefully does not help you read a feed you are not reading.">Feed may be wrong by</div>
        <div class="metric-value" style="font-size:16px">±${Math.round(fc.feedSd).toLocaleString()}</div>
      </div>
      <div class="metric">
        <div class="metric-label">Chance of Up</div>
        <div class="metric-value ${fc.pUp >= 0.5 ? 'up' : 'down'}" style="font-size:18px">${(fc.pUp * 100).toFixed(1)}%</div>
        <div class="metric-label">${settled}% of the window in</div>
      </div>
    </div>
    ${fc.modelWeight != null ? `<div class="note" style="margin-top:14px"><span class="note-icon">›</span><span>
      <strong>Mostly the market's opinion, on purpose.</strong> Paper's own reading of the window makes it
      ${(fc.pModel * 100).toFixed(1)}%; Polymarket is pricing ${(fc.pMarket * 100).toFixed(1)}%. The two are
      combined with ${(fc.modelWeight * 100).toFixed(0)}% weight on Paper's, which is the share of its
      uncertainty that is a genuine forecast of what Bitcoin might still do rather than its inability to
      read the feed the market settles on. The people setting that price can see the resolver and Paper
      cannot, so a large disagreement is nearly always Paper being wrong — and betting the difference
      would buy the cheap side of a decided window over and over. The weight falls as the window runs
      out, because by then there is nothing left to forecast and everything left to observe.</span></div>`
      : ''}`;
}

/* The decision, stated whether or not it bet. "It did nothing for eleven minutes"
 * needs a reason as much as a fill does. */
function decisionPanel(d) {
  if (!d) return '';
  const tone = { taken: 'accent', vetoed: 'warn', 'too-thin': 'warn', 'no-room': 'warn' }[d.verdict] ?? '';
  const head = {
    taken: 'Bought', 'no-edge': 'No bet — the price is where the model is',
    'too-early': 'Waiting for the window to develop', 'too-late': 'Too close to the bell',
    'already-bet': 'Already positioned in this window', vetoed: 'Vetoed by the calibration',
    'too-thin': 'Not enough on the offer', 'too-small': 'Below the minimum order',
    'no-room': 'No room left in the bankroll', idle: 'Waiting',
    missed: 'Never looked at inside its own window',
    decided: 'The market has already called this window',
  }[d.verdict] ?? d.verdict;

  return `<div class="note ${tone}" style="margin-top:18px">
    <span class="note-icon">${d.verdict === 'taken' ? '✓' : d.verdict === 'vetoed' ? '!' : '›'}</span>
    <span><strong>${esc(head)}.</strong> ${esc(d.reason)}
    ${d.edge != null ? `<span class="faint"> Edge ${(d.edge * 100).toFixed(1)}¢ against a
      ${(d.requiredEdge * 100).toFixed(1)}¢ floor.</span>` : ''}</span></div>`;
}

/**
 * The twenty minutes behind the current window.
 *
 * Four outcomes, what the tape measured across each, and what the model would have
 * said at the same point in each of them — replayed against a tape truncated to
 * that instant, so it is a real out-of-sample check and not the model marking its
 * own homework after the fact.
 */
function calibrationPanel(c) {
  if (!c) return '';
  return `
    <div class="section-head" style="margin-top:26px">
      <h2>The four windows behind this one</h2>
      <span class="hint">The most recent four with a published result, replayed. Polymarket's resolver
        runs several minutes behind the bell, so these are not always the four on the clock. A sample
        this small is allowed to veto and never allowed to encourage.</span>
    </div>
    <div class="panel scroll-x"><table>
      <thead><tr><th>Window</th><th>Resolved</th><th class="right">Move</th>
        <th>The model would have said</th><th class="right">Right?</th></tr></thead>
      <tbody>${c.priors.map((w) => `<tr>
        <td class="num">${esc(w.label)}</td>
        <td class="${w.resolved === 'Up' ? 'up' : w.resolved === 'Down' ? 'down' : 'dim'}">
          ${esc(w.resolved ?? 'not yet')}</td>
        <td class="right num ${dir(w.movePct)}">${w.movePct != null ? `${w.movePct >= 0 ? '+' : ''}${(w.movePct * 100).toFixed(1)} bps` : '—'}</td>
        <td class="dim">${w.modelSide ? `${esc(w.modelSide)} at ${(w.modelP * 100).toFixed(1)}%` : '<span class="dim">no data</span>'}</td>
        <td class="right ${w.modelRight === true ? 'up' : w.modelRight === false ? 'down' : 'dim'}">
          ${w.modelRight === true ? 'yes' : w.modelRight === false ? 'no' : '—'}</td>
      </tr>`).join('')}</tbody>
    </table></div>
    <div class="note" style="margin-top:12px"><span class="note-icon">›</span>
      <span>${esc(c.summary)}</span></div>`;
}

/* ------------------------------------------------------------------- setup */

const LENGTHS = [[30, 'Half an hour'], [60, 'One hour'], [120, 'Two hours'], [240, 'Four hours']];

/**
 * What the form is currently set to.
 *
 * Kept here rather than read off the markup, because the markup is not where it
 * was safe to keep it: the tab rebuilds itself whenever it is left and come back
 * to, and every default below would be written straight back over a bankroll and
 * six sliders that had been deliberately moved. A repaint now draws what was
 * chosen, and the defaults are only ever the starting point of a first visit.
 */
const draft = {
  bankroll: 1000, minutes: 60, edge: 5, kelly: 25,
  stakeCap: 5, offset: 0, loss: 20, target: 30, autoBet: true, recovery: false, stake: 25,
};

function setup(p) {
  return `
    <div class="section-head">
      <h2>Bitcoin, five minutes at a time</h2>
      <span class="hint">Polymarket's rolling five-minute market, watched and bet automatically
        against a bankroll that is not your trading account.</span>
    </div>

    ${aside('Polymarket runs one market every five minutes on whether Bitcoin’s average across those five minutes finishes above where it started. Paper reads that market’s real order book, forms its own probability, and buys only when the two disagree by enough to be worth the spread.')}

    <div class="note accent" style="margin-bottom:18px"><span class="note-icon">›</span><span>
      <strong>It resolves on the average, not the close.</strong> A window resolves <em>Up</em> if the
      time-weighted average price across the five minutes finishes at or above the price at the start —
      so a spike in the first minute that fully retraces still resolves Up. Anything that predicts where
      the price ends up is answering a different question from the one being paid out on, and this does
      not do that.</span></div>

    ${marketHead(p)}
    ${tracker(p)}
    ${details(p)}
    ${brainPanel(p)}

    <div class="note" style="margin-bottom:18px"><span class="note-icon">›</span><span>
      <strong>This bankroll is separate from your trading account.</strong> A prediction contract has no
      cost basis, no holding period and nothing to sell it back to before it resolves; putting one
      through the same tax lots as a share would produce a ledger that is wrong about both. Nothing here
      touches the account on the Desk tab, and nothing here is real money either way.</span></div>

    <!-- Nothing in this panel comes from the server: it is the question being
         asked, and the poll behind it has no business rewriting it. Marked so a
         repaint updates the live panels below and leaves every control here
         exactly as it was set. -->
    <div class="panel panel-pad" data-keep>
      <div class="grid-2">
        <div class="field">
          <label for="bankrollInput">Bankroll</label>
          <input id="bankrollInput" type="number" step="any" value="${draft.bankroll}">
          <span class="faint" style="font-size:11.5px">Its own money, invented for this. Every size below
            is a share of it.</span>
        </div>
        <div class="field">
          <label>How long to watch</label>
          <div class="pill-row" id="lengthRow">
            ${LENGTHS.map(([m, l]) => `<button class="pill ${m === draft.minutes ? 'is-on' : ''}" data-minutes="${m}">${esc(l)}</button>`).join('')}
          </div>
          <span class="faint" style="font-size:11.5px">Twelve windows an hour. It will bet on very few
            of them.</span>
        </div>
        <div class="field">
          <label>Who presses the button</label>
          <div class="pill-row" id="autoBetRow">
            <button class="pill ${draft.autoBet !== false ? 'is-on' : ''}" data-auto="yes">It bets</button>
            <button class="pill ${draft.autoBet === false ? 'is-on' : ''}" data-auto="no">It advises</button>
          </div>
          <span class="faint" style="font-size:11.5px">Advising does everything else the same — reads the
            window, prices both sides, sizes the position — and then stops and tells you instead of
            buying. Either way you can place a bet by hand, and either way it learns from every window
            that resolves.</span>
        </div>
        <div class="field">
          <label>Chase losses</label>
          <div class="pill-row" id="recoveryRow">
            <button class="pill ${draft.recovery !== true ? 'is-on' : ''}" data-recovery="no">No</button>
            <button class="pill ${draft.recovery === true ? 'is-on' : ''}" data-recovery="yes">Recovery mode</button>
          </div>
          <span class="faint" style="font-size:11.5px">This is the martingale, and it is off for a reason.
            A contract is worth its probability minus its price; being down $50 moves neither, so a window
            the desk would decline while flat is exactly as bad a bet while behind — and "win back $50 on a
            $50 stake" only prices under 50¢, which is the tail that loses. On, and only once the run is
            actually down, it drops the edge bar to nothing and sizes each bet to the stake whose win
            returns the run to flat. The per-window cap and the loss limit still bind, so it can lose the
            run faster but not for more. Every such bet is marked, and the Review tab scores them
            separately — that is the point of having it here rather than arguing about it.</span>
        </div>
      </div>

      <div class="grid-2" style="margin-top:18px">
        <div class="field">
          <label for="edgeInput">Only bet at — <span id="edgeLabel">${draft.edge}</span>¢ of edge</label>
          <input id="edgeInput" type="range" min="2" max="20" step="0.5" value="${draft.edge}">
          <span class="faint" style="font-size:11.5px">How far the model has to beat the price before
            anything is bought. Lower buys more windows and worse ones.</span>
        </div>
        <div class="field">
          <label for="kellyInput">Bet — <span id="kellyLabel">${draft.kelly}</span>% of Kelly</label>
          <input id="kellyInput" type="range" min="5" max="100" step="5" value="${draft.kelly}">
          <span class="faint" style="font-size:11.5px">Full Kelly is growth-optimal only if the
            probability is exactly right, and this one is an estimate. A quarter keeps most of the
            growth for a fraction of the swing.</span>
        </div>
      </div>

      <div class="grid-2" style="margin-top:18px">
        <div class="field">
          <label for="stakeCapInput">Never more than — <span id="stakeCapLabel">${draft.stakeCap}</span>% of the bankroll on one window</label>
          <input id="stakeCapInput" type="range" min="1" max="25" step="0.5" value="${draft.stakeCap}">
          <span class="faint" style="font-size:11.5px">The hard cap above whatever Kelly asks for.</span>
        </div>
        <div class="field">
          <label for="offsetInput">Wait at least — <span id="offsetLabel">${draft.offset === 0 ? 'nothing, let the edge decide' : draft.offset + 's'}</span></label>
          <input id="offsetInput" type="range" min="0" max="240" step="10" value="${draft.offset}">
          <span class="faint" style="font-size:11.5px">A floor, not a schedule. At zero the desk reads
            every window from 15s in — the seconds the tape needs — and takes one the moment the edge
            clears the bar, which in a quiet window is never. It does not need a clock to be careful:
            the projected average starts at spot, so the signal starts at nothing, and the uncertainty
            starts at its largest, so an early window prices itself near 50% without being told to.
            Raise this only to force the desk to sit out the first part of every window.</span>
        </div>
      </div>

      <div class="grid-2" style="margin-top:18px">
        <div class="field">
          <label for="lossInput">Stop after losing — <span id="lossLabel">${draft.loss}</span>% of the bankroll</label>
          <input id="lossInput" type="range" min="5" max="60" step="1" value="${draft.loss}">
          <span class="faint" style="font-size:11.5px">Checked after every settlement, and it cannot be
            raised while the run is going.</span>
        </div>
        <div class="field">
          <label for="targetInput">Stop after making — <span id="targetLabel">${draft.target}</span>%</label>
          <input id="targetInput" type="range" min="5" max="150" step="1" value="${draft.target}">
          <span class="faint" style="font-size:11.5px">A streak of correct five-minute calls is exactly
            when people stop sizing and start pressing.</span>
        </div>
      </div>

      <div class="btn-row" style="margin-top:22px">
        <button class="btn primary" id="startPredictBtn">Start watching</button>
        <span class="faint" style="font-size:11.5px">It runs whether or not this tab is open, and
          settles from Polymarket's published result.</span>
      </div>
    </div>

    ${calibrationPanel(p.calibration)}`;
}

/* -------------------------------------------------------------------- live */

function live(p) {
  const r = p.run;
  const over = r.status !== 'running';
  const lossUsed = p.lossLimit > 0
    ? Math.min(100, Math.max(0, (-Math.min(0, p.realised) / p.lossLimit) * 100)) : 0;
  const targetDone = p.targetAmount > 0
    ? Math.min(100, Math.max(0, (p.realised / p.targetAmount) * 100)) : 0;

  return `
    <div class="section-head">
      <h2>${over ? 'Prediction run — report' : 'Prediction run — live'}</h2>
      <span class="hint">${money(r.bankroll, 0)} bankroll · ${cents(r.minEdge)} edge floor ·
        ${(r.kellyFraction * 100).toFixed(0)}% of Kelly · at most ${money(maxStake(r), 0)} a window</span>
      <span class="spacer"></span>
      ${over
        ? '<button class="btn sm" id="clearPredictBtn">Start another</button>'
        : '<button class="btn danger sm" id="endPredictBtn">Stop it</button>'}
    </div>

    ${over ? `<div class="note ${r.status === 'met-target' ? 'accent' : r.status === 'hit-loss-limit' ? 'warn' : ''}">
      <span class="note-icon">${r.status === 'met-target' ? '✓' : r.status === 'hit-loss-limit' ? '!' : '›'}</span>
      <span><strong>${esc({ 'met-target': 'Target reached', 'hit-loss-limit': 'Loss limit hit',
        'out-of-time': 'Time up', stopped: 'Stopped early' }[r.status] ?? r.status)}.</strong>
      ${esc(r.endNote ?? '')}</span></div>` : ''}

    ${p.feedError ? `<div class="note warn"><span class="note-icon">!</span>
      <span><strong>A feed is down.</strong> ${esc(p.feedError)} The run holds off rather than deciding
      from stale data.</span></div>` : ''}

    <div class="panel panel-pad" style="margin-top:${over ? '16' : '0'}px">
      <div class="metric-grid" style="grid-template-columns:repeat(auto-fit,minmax(118px,1fr))">
        <div class="metric"><div class="metric-label">Settled P/L</div>
          <div class="metric-value ${dir(p.realised)}" style="font-size:18px">${signedMoney(p.realised)}</div>
          ${subSigned(p.realised)}</div>
        <div class="metric"><div class="metric-label" title="What the open windows are worth at the current bid — the price they could actually be sold at.">Open</div>
          <div class="metric-value ${dir(p.unrealised)}">${signedMoney(p.unrealised)}</div></div>
        <div class="metric"><div class="metric-label">Record</div>
          <div class="metric-value">${r.bets.filter((b) => won(b) === true).length}<span class="faint" style="font-size:13px"> / ${r.bets.filter(settled).length}</span></div>
          <div class="metric-label" title="The sum of the prices paid. A contract bought at 80¢ is the market saying 80%, so these prices were already forecasting this many wins. Only a record above it is the model beating the market.">priced for ${r.bets.filter(settled).reduce((t, b) => t + b.cost, 0).toFixed(1)}</div>
          <div class="metric-label">${r.windowsSeen} window${r.windowsSeen === 1 ? '' : 's'} read</div></div>
        <div class="metric"><div class="metric-label">Free to bet</div>
          <div class="metric-value">${money(p.available, 0)}</div></div>
        <div class="metric"><div class="metric-label">${over ? 'Ran for' : 'Time left'}</div>
          <div class="metric-value" id="runClock" data-ends="${r.endsAt}">${over ? `${Math.round(r.minutes)}m` : clock(p.secondsLeft)}</div></div>
      </div>

      <div class="session-bars">
        <div class="session-bar">
          <div class="session-bar-head"><span>Loss limit</span>
            <span class="num ${lossUsed > 66 ? 'down' : ''}">${money(p.lossHeadroom, 0)} left of ${money(p.lossLimit, 0)}</span></div>
          <div class="score-track"><div class="score-fill" style="width:${lossUsed}%;background:var(--down)"></div></div>
        </div>
        <div class="session-bar">
          <div class="session-bar-head"><span>Target</span>
            <span class="num ${targetDone >= 100 ? 'up' : ''}">${money(Math.max(0, p.realised), 0)} of ${money(p.targetAmount, 0)}</span></div>
          <div class="score-track"><div class="score-fill" style="width:${targetDone}%;background:var(--up)"></div></div>
        </div>
      </div>
    </div>

    ${over ? '' : marketHead(p)}
    ${over ? '' : tracker(p)}
    ${over ? '' : ticket(p)}
    ${over ? '' : decisionPanel(p.decision)}
    ${over ? '' : details(p)}
    ${r.bets.length ? bets(r) : `<div class="panel" style="margin-top:18px"><div class="empty">
      <div class="empty-title">Nothing bought yet</div>
      <div class="empty-sub">${over
        ? `The run read ${r.windowsSeen} window${r.windowsSeen === 1 ? '' : 's'} and never found a price far enough from its own estimate to be worth the spread. That is a result, not a failure — on a five-minute market with penny spreads, priced by people reading the settlement feed directly, an edge is rare and a desk that found one every five minutes would be measuring its own error.`
        : 'It is reading a window every five minutes and will buy only when the price and the model disagree by more than the floor. On most windows they do not.'}</div>
    </div></div>`}
    ${skipTally(r)}
    ${brainPanel(p)}
    ${over ? fidelityNote(p) : ''}
    ${over ? calibrationPanel(p.calibration) : ''}`;
}

function bets(r) {
  return `
    <div class="section-head" style="margin-top:26px"><h2>What it bought</h2>
      <span class="hint">The desk sizes its own bets: ${(r.kellyFraction * 100).toFixed(0)}% of Kelly on the
        edge, held to ${money(maxStake(r), 0)} a window, so the stake moves with the edge and the price. The
        $5 / $25 / $100 buttons are only for bets placed by hand. Every fill walked Polymarket's real book, so
        the price paid is what the depth actually cost.</span></div>
    <div class="panel scroll-x"><table>
      <thead><tr><th>Window</th><th>Side</th><th class="right">Model</th><th class="right">Paid</th>
        <th class="right">Edge</th><th class="right">Size</th><th class="right">Stake</th>
        <th>Resolved</th><th class="right">P/L</th></tr></thead>
      <tbody>${[...r.bets].reverse().map((b) => `<tr class="predict-bet" data-thesis="${esc(b.thesis)}">
        <td class="num">${esc(b.window ? windowLabel(b.window) : '')}${b.manual ? ' <span class="faint" style="font-size:10.5px">by hand</span>' : ''}${b.recovery ? ' <span class="down" style="font-size:10.5px" title="Taken under the recovery rule: bar dropped to zero, size set to erase the deficit rather than to the edge.">chase</span>' : ''}</td>
        <td class="${b.side === 'Up' ? 'up' : 'down'}">${esc(b.side)}</td>
        <td class="right num">${(b.modelP * 100).toFixed(1)}%</td>
        <td class="right num" title="Best offer was ${cents(b.bestAsk)}; this is what the fill averaged across the book.">${cents(b.cost)}</td>
        <td class="right num up">+${(b.edge * 100).toFixed(1)}¢</td>
        <td class="right num">${b.shares.toFixed(1)}</td>
        <td class="right num">${money(b.stake, 2)}</td>
        <td class="${b.resolved === 'Up' ? 'up' : b.resolved === 'Down' ? 'down' : 'dim'}">
          ${b.resolved ? esc(b.resolved) : b.awaitingResolution ? 'awaiting resolver' : 'open'}</td>
        <td class="right num ${b.pnl != null ? dir(b.pnl) : 'dim'}">${b.pnl != null ? signedMoney(b.pnl) : '—'}</td>
      </tr>`).join('')}</tbody>
    </table></div>
    <div class="faint" style="margin-top:8px;font-size:11.5px">A contract pays exactly $1 if its side is
      right and nothing if it is not, so a loss is always the whole stake and a win is the size less the
      stake. There is no exit before resolution, which is why there is no stop on this tab.</div>
    ${recoveryScore(r.bets)}`;
}

/**
 * Recovery bets against the rest, scored side by side.
 *
 * The whole argument for having a chase mode in a simulator is that it produces a
 * number instead of an opinion, and a number nobody separates out is not one. Two
 * rows, same desk, same market, different rule.
 */
function recoveryScore(bets) {
  const settled = (bets || []).filter((b) => b.pnl != null);
  const chased = settled.filter((b) => b.recovery);
  if (!chased.length) return '';
  const normal = settled.filter((b) => !b.recovery);
  const row = (label, rows) => {
    if (!rows.length) return `<tr><td>${esc(label)}</td><td class="right num dim" colspan="4">none</td></tr>`;
    const staked = rows.reduce((a, b) => a + b.stake, 0);
    const pnl = rows.reduce((a, b) => a + b.pnl, 0);
    const won = rows.filter((b) => b.resolved === b.side).length;
    return `<tr><td>${esc(label)}</td>
      <td class="right num">${rows.length}</td>
      <td class="right num">${won}/${rows.length}</td>
      <td class="right num">${money(staked, 2)}</td>
      <td class="right num ${dir(pnl)}">${signedMoney(pnl)}</td></tr>`;
  };
  return `<div class="section-head" style="margin-top:22px"><h2>The chase, scored</h2>
      <span class="hint">Recovery bets are sized to the hole rather than to the edge. Here is what that
        bought, against what the same desk did when it was betting on the merits.</span></div>
    <div class="panel scroll-x"><table>
      <thead><tr><th>Rule</th><th class="right">Bets</th><th class="right">Right</th>
        <th class="right">Staked</th><th class="right">P/L</th></tr></thead>
      <tbody>${row('On the merits', normal)}${row('Chasing', chased)}</tbody>
    </table></div>`;
}

/**
 * Why the windows it passed on were passed on.
 *
 * A run that buys nothing for half an hour is the normal outcome on this market,
 * and an empty table reports it as though the feature were broken. This is the
 * difference between "it bought nothing" and "four windows the calibration vetoed
 * and two where the price was already where the model was" — the second is a
 * result about the market, which is the thing worth reading.
 */
const SKIP_LABEL = {
  'no-edge': 'the price was already where the model was',
  vetoed: 'the last four settled windows vetoed it',
  'too-thin': 'there was nothing worth buying on the offer',
  'too-small': 'the edge justified less than the minimum order',
  'too-late': 'the window was too close to the bell',
  'too-early': 'the window had not run long enough to read',
  'no-room': 'the bankroll or the loss limit had no space left',
  idle: 'it was waiting on an earlier window to resolve',
  // Not a judgement about the window — a report that the loop never evaluated it
  // inside the band at all. Worth its own line precisely because it used to be
  // filed as `too-late`, which reads as a decision rather than an omission.
  missed: 'the desk never got a look at it inside its own window',
  // The price had saturated, or the cheap side was quoted under a cent. Both mean
  // the book had stopped offering a probability, and the model's disagreement with
  // it that late is feed noise rather than a view. See `Verdict.decided`.
  decided: 'the market had already priced the window as settled',
  // `already-bet` is deliberately absent: a window that was bought is not a window
  // that was passed on, and the engine no longer banks it as one. Left here as a
  // label only in case an older run file carries the old counting.
  'already-bet': 'it was already positioned there',
};

function skipTally(r) {
  const rows = Object.entries(r.skipped ?? {})
    .filter(([, n]) => n > 0)
    .sort((a, b) => b[1] - a[1]);
  if (!rows.length) return '';
  /* The figures have to add up — every window read was bought, passed on for
   * exactly one reason, or is still on the clock. Stating them on one line makes
   * that a self-checking claim rather than a number to take on faith, which is how
   * two separate double-counts announced themselves.
   *
   * The last term is the one that is easy to forget and looks like a bug without.
   * A window is only banked as passed-on once it rolls over, because its verdict is
   * not final until it is — so for most of any five-minute window the first three
   * figures are one short of each other, correctly. */
  const passed = rows.reduce((n, [, c]) => n + c, 0);
  const open = Math.max(0, r.windowsSeen - r.bets.length - passed);
  /* The tally says what happened; this says how close it came, which is the part
   * worth acting on. A run whose best look was a cent short of its bar was nearly in
   * business and is worth running again; one whose best look was eleven cents short
   * was never going to bet and something has to change first. */
  const m = r.closestMiss;
  const miss = m ? `<div class="predict-skip" style="border-top:1px solid var(--line);margin-top:8px;padding-top:12px">
      <span>Closest it came — ${esc(m.windowLabel)}, ${esc(m.side)} at ${(m.offset).toFixed(0)}s in</span>
      <span class="num">${(m.edge * 100).toFixed(1)}¢ of ${(m.required * 100).toFixed(1)}¢
        <span class="faint">${(m.shortfall * 100).toFixed(1)}¢ short</span></span>
    </div>` : '';
  return `<div class="panel panel-pad" style="margin-top:14px">
    <div class="metric-label" style="margin-bottom:10px">
      ${r.windowsSeen} window${r.windowsSeen === 1 ? '' : 's'} read ·
      ${r.bets.length} bought · ${passed} passed on${open ? ` · ${open} still on the clock` : ''}</div>
    ${rows.map(([verdict, n]) => `<div class="predict-skip">
      <span>${esc(SKIP_LABEL[verdict] ?? verdict)}</span>
      <span class="num dim">${n} window${n === 1 ? '' : 's'}</span>
    </div>`).join('')}
    ${miss}
  </div>`;
}

/* ------------------------------------------------------------- the tracker */

const usd = (v) => (v == null ? '—' : `$${v.toLocaleString(undefined,
  { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`);

/**
 * The three numbers a five-minute market is actually about, at the size they
 * deserve.
 *
 * Price to beat, price now, and how long is left. Everything else on this tab is a
 * reason; these are the facts, and before this they were scattered across a
 * breakdown table in 12px type while a progress bar got the full width.
 */
function marketHead(p) {
  const t = p.track;
  const left = p.windowSecondsLeft ?? 0;
  const beat = t?.openPrice;
  const now = p.spot;
  const avg = t?.twapSoFar;
  const gap = beat != null && avg != null ? avg - beat : null;
  const winning = (gap ?? 0) >= 0;
  const spotGap = beat != null && now != null ? now - beat : null;

  const signed = (v) => `${v >= 0 ? '▲' : '▼'} ${usd(Math.abs(v)).replace('$', '$')}`;

  return `<div class="panel panel-pad predict-head">
    <div class="predict-head-main">
      <div>
        <div class="metric-label">Price to beat</div>
        <div class="predict-big">${usd(beat)}</div>
      </div>
      <div>
        <div class="metric-label">Average so far
          ${gap != null ? `<span class="${winning ? 'up' : 'down'}">${signed(gap)}</span>` : ''}</div>
        <div class="predict-big ${gap == null ? '' : winning ? 'up' : 'down'}">${usd(avg)}</div>
      </div>
      <div>
        <div class="metric-label">Bitcoin now
          ${spotGap != null ? `<span class="faint">${signed(spotGap)}</span>` : ''}</div>
        <div class="predict-big dim" style="font-size:20px">${usd(now)}</div>
      </div>
      <span class="spacer"></span>
      <div style="text-align:right">
        <div class="metric-label">${esc(p.windowLabel ?? '')} left</div>
        <div class="predict-big num" id="windowClock"
          data-ends="${Date.now() + left * 1000}">${clock(left)}</div>
      </div>
    </div>
    <div class="hint" style="margin-top:10px">This window resolves <strong>Up</strong> if the
      <em>average</em> finishes at or above the price to beat, so the middle number is the one that
      settles it — not the last price. They can disagree: a spike that fully retraces still resolves Up.
      ${spotGap != null && gap != null && Math.abs(spotGap - gap) > 5
        ? `<strong>Right now they disagree by ${usd(Math.abs(spotGap - gap))}</strong>, because the
           average still carries the whole window and the last price does not.` : ''}</div>
    <div class="hint faint" style="margin-top:6px">All three are <strong>Paper's</strong> reading, a
      median of Coinbase and Kraken. Polymarket's own screen will show different figures for the same
      window — it settles on a Chainlink feed Paper cannot read, and shows that feed's rolling
      60-second average rather than a last price. A few dollars between the two is the normal size of
      that gap, and it is the gap every probability here is already discounted by.</div>
  </div>`;
}

/**
 * The window as it happens.
 *
 * **Redrawn to look like the market it is modelling.** The first version stacked two
 * equal panes and stretched the whole drawing with `preserveAspectRatio="none"` — a
 * 720-unit viewBox squeezed into a 1300px panel, which scaled the horizontal axis by
 * nearly two and left every label and stroke visibly distorted. That is most of what
 * "the graph looks weird" was. It scales uniformly now, so text is text.
 *
 * The price pane leads, filled and at full width, with the price to beat as a dashed
 * target across it — which is how Polymarket draws it and, more to the point, is the
 * one line the whole market is about. The running average is drawn beside it because
 * *that* is what settles, which their chart cannot tell you. The probabilities keep
 * a short strip underneath on the same time axis, because the gap between them is
 * where a bet comes from and it only reads as a gap if the two are drawn together.
 */
function tracker(p) {
  const t = p.track;
  if (!t || !t.btc?.length || !t.openPrice) return '';

  const W = 1200, H = 348;
  const PL = 14, PR = 96, PT = 26, PH = 196;          // price pane
  const SY = PT + PH + 44, SH = 56;                   // probability strip
  const iw = W - PL - PR;
  const x = (ms) => PL + Math.max(0, Math.min(1, (ms - t.window.start * 1000) / 300000)) * iw;

  const vals = t.btc.map((b) => b.p).concat([t.openPrice, t.twapSoFar].filter((v) => v != null));
  let lo = Math.min(...vals), hi = Math.max(...vals);
  /* A window that has barely moved would otherwise be auto-scaled into a wall of
     noise filling the pane, which reads as drama and is the opposite of the truth.
     The floor is a tenth of a percent of price, so a flat window looks flat. */
  const floor = t.openPrice * 0.001;
  if (hi - lo < floor) { const m = (hi + lo) / 2; lo = m - floor / 2; hi = m + floor / 2; }
  const pad = (hi - lo) * 0.18;
  lo -= pad; hi += pad;
  const y = (v) => PT + PH - ((v - lo) / (hi - lo)) * PH;

  const pts = t.btc.map((b) => [x(b.t), y(b.p)]);
  const line = pts.map((q, i) => `${i ? 'L' : 'M'}${q[0].toFixed(1)},${q[1].toFixed(1)}`).join('');
  const last = pts[pts.length - 1];
  const area = `${line}L${last[0].toFixed(1)},${(PT + PH).toFixed(1)}L${pts[0][0].toFixed(1)},${(PT + PH).toFixed(1)}Z`;

  // Coloured by the quantity that settles — the running average against the open —
  // rather than by spot, which can be above the line while the average is not.
  const winning = (t.twapSoFar ?? t.openPrice) >= t.openPrice;
  const stroke = winning ? 'var(--up)' : 'var(--down)';
  const openY = y(t.openPrice);

  const py = (v) => SY + SH - v * SH;
  const series = (key) => {
    const rows = t.points.filter((q) => q[key] != null);
    if (rows.length < 2) return '';
    return rows.map((q, i) => `${i ? 'L' : 'M'}${x(q.t).toFixed(1)},${py(q[key]).toFixed(1)}`).join('');
  };

  const bandX = PL + (t.bandFrom / 300) * iw;
  const bandW = Math.max(0, ((t.bandTo - t.bandFrom) / 300) * iw);
  const ticks = [0, 60, 120, 180, 240, 300];

  return `<div class="panel panel-pad" style="margin-top:18px">
    <svg viewBox="0 0 ${W} ${H}" class="predict-chart">
      <defs>
        <linearGradient id="predFill" x1="0" x2="0" y1="0" y2="1">
          <stop offset="0%" stop-color="${stroke}" stop-opacity="0.22"></stop>
          <stop offset="100%" stop-color="${stroke}" stop-opacity="0"></stop>
        </linearGradient>
      </defs>

      <rect x="${bandX.toFixed(1)}" y="${PT}" width="${bandW.toFixed(1)}" height="${PH}"
        fill="var(--accent)" opacity="0.05"></rect>
      <rect x="${bandX.toFixed(1)}" y="${SY}" width="${bandW.toFixed(1)}" height="${SH}"
        fill="var(--accent)" opacity="0.05"></rect>

      <path d="${area}" fill="url(#predFill)"></path>
      <line x1="${PL}" x2="${W - PR}" y1="${openY.toFixed(1)}" y2="${openY.toFixed(1)}"
        stroke="var(--warn)" stroke-dasharray="6 5" stroke-width="1.4"></line>
      <text x="${W - PR + 8}" y="${(openY + 4).toFixed(1)}" class="chart-tick" fill="var(--warn)">Target</text>

      ${t.twapSoFar != null ? `<line x1="${PL}" x2="${W - PR}" y1="${y(t.twapSoFar).toFixed(1)}"
        y2="${y(t.twapSoFar).toFixed(1)}" stroke="${stroke}" stroke-dasharray="2 5"
        stroke-width="1.2" opacity="0.75"></line>
      <text x="${W - PR + 8}" y="${(y(t.twapSoFar) + 4).toFixed(1)}" class="chart-tick"
        fill="${stroke}">average</text>` : ''}

      <path d="${line}" fill="none" stroke="${stroke}" stroke-width="2"
        stroke-linejoin="round" stroke-linecap="round"></path>
      <circle cx="${last[0].toFixed(1)}" cy="${last[1].toFixed(1)}" r="4.5" fill="${stroke}"></circle>
      <circle cx="${last[0].toFixed(1)}" cy="${last[1].toFixed(1)}" r="9" fill="${stroke}" opacity="0.2"></circle>

      <text x="${W - PR + 8}" y="${PT + 5}" class="chart-tick">${usd(hi)}</text>
      <text x="${W - PR + 8}" y="${PT + PH}" class="chart-tick">${usd(lo)}</text>

      <line x1="${PL}" x2="${W - PR}" y1="${py(0.5).toFixed(1)}" y2="${py(0.5).toFixed(1)}"
        stroke="var(--line)" stroke-width="1"></line>
      <text x="${PL}" y="${SY - 12}" class="chart-tick">Polymarket's price for Up, against the model</text>
      <text x="${W - PR + 8}" y="${(py(1) + 8).toFixed(1)}" class="chart-tick">100¢</text>
      <text x="${W - PR + 8}" y="${(py(0) + 2).toFixed(1)}" class="chart-tick">0¢</text>
      <path d="${series('market')}" fill="none" stroke="var(--accent)" stroke-width="1.8"></path>
      <path d="${series('model')}" fill="none" stroke="var(--text-dim)" stroke-width="1.6"
        stroke-dasharray="5 4"></path>

      ${t.markers.map((m) => `
        <line x1="${x(m.t).toFixed(1)}" x2="${x(m.t).toFixed(1)}" y1="${PT}" y2="${SY + SH}"
          stroke="${m.side === 'Up' ? 'var(--up)' : 'var(--down)'}" stroke-width="1.2" opacity="0.6"></line>
        <circle cx="${x(m.t).toFixed(1)}" cy="${py(m.price).toFixed(1)}" r="4"
          fill="${m.side === 'Up' ? 'var(--up)' : 'var(--down)'}"></circle>
        <text x="${(x(m.t) + 7).toFixed(1)}" y="${(py(m.price) - 8).toFixed(1)}"
          class="chart-tick">${esc(m.label)}</text>`).join('')}

      ${ticks.map((sec) => `<text x="${(PL + (sec / 300) * iw).toFixed(1)}" y="${H - 6}"
        class="chart-tick" text-anchor="${sec === 0 ? 'start' : sec === 300 ? 'end' : 'middle'}"
        >${sec === 0 ? '0:00' : `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, '0')}`}</text>`).join('')}
      <text x="${(PL + ((t.bandFrom + t.bandTo) / 2 / 300) * iw).toFixed(1)}" y="${PT - 10}"
        class="chart-tick" text-anchor="middle" fill="var(--accent)">it may act in here</text>
    </svg>
    <div class="chart-key">
      <span><i style="background:${stroke}"></i>Bitcoin</span>
      <span><i style="background:var(--warn)"></i>price to beat</span>
      <span><i style="background:var(--accent)"></i>Polymarket, Up</span>
      <span><i style="background:var(--text-dim)"></i>the model</span>
    </div>
  </div>`;
}

/* --------------------------------------------------------------- the ticket */

/**
 * What the model would do, and the buttons to do it yourself.
 *
 * The desk deciding on its own is the feature; this is the admission that its bar
 * is a setting rather than a law. Everything it refuses is refused for a stated
 * reason and a stated distance, and "five cents of edge" is the one of those
 * reasons that is a judgement rather than a fact about the account or the book. So
 * the recommendation is always shown — side, price, the model's probability and
 * the gap between them — whether or not it clears, and the buttons are always live
 * within the window's own limits.
 */
function ticket(p) {
  const r = p.run;
  if (!r || r.status !== 'running') return '';
  const d = p.decision;
  const fc = p.forecast;
  const left = p.windowSecondsLeft ?? 0;
  const already = (r.bets ?? []).some((b) => b.window?.start === p.window?.start);
  const tooLate = left < (r.cutoffSeconds ?? 35);

  const call = d?.side ?? (fc ? (fc.pUp >= 0.5 ? 'Up' : 'Down') : null);
  const ask = call === 'Up' ? p.upAsk : p.downAsk;
  const modelP = fc ? (call === 'Up' ? fc.pUp : 1 - fc.pUp) : null;
  const edge = modelP != null && ask != null ? modelP - ask : null;
  const clears = edge != null && d?.requiredEdge != null && edge >= d.requiredEdge;

  const headline = already
    ? 'This window is already positioned — one bet per window.'
    : tooLate
      ? `Inside the last ${(r.cutoffSeconds ?? 35).toFixed(0)}s. The book thins here and a fill walks several cents.`
      : call == null
        ? 'No reading on this window yet.'
        : clears
          ? `The model likes <strong>${esc(call)}</strong> at ${cents(ask)} — ${cents(edge)} of edge against the ${cents(d.requiredEdge)} it asks for.`
          : edge != null
            ? edge < 0
              /* "−0.4¢ of edge" is arithmetic, not English. A negative edge is not a
                 small edge; it is the price being better than the model, which is a
                 different thing and worth saying as one. */
              ? `The model makes <strong>${esc(call)}</strong> ${(modelP * 100).toFixed(1)}%, and it is offered at ${cents(ask)} — ${cents(-edge)} <em>more</em> than the model thinks it is worth. There is nothing here to buy.`
              : `The model makes <strong>${esc(call)}</strong> ${(modelP * 100).toFixed(1)}% and it is offered at ${cents(ask)} — ${cents(edge)} of edge, under the ${cents(d?.requiredEdge ?? r.minEdge)} the desk waits for.`
            : `The model makes <strong>${esc(call)}</strong> ${modelP == null ? '—' : `${(modelP * 100).toFixed(1)}%`}, and there is no offer on it right now.`;

  const cap = maxStake(r);
  const free = p.available ?? 0;
  const stakes = [5, 25, 100, Math.max(5, Math.round(Math.min(cap, free)))];
  const seen = new Set();
  const choices = stakes.filter((s) => (seen.has(s) ? false : seen.add(s)));
  const chosen = draft.stake ?? 25;
  const disabled = already || tooLate;

  const payout = (side) => {
    const a = side === 'Up' ? p.upAsk : p.downAsk;
    if (a == null || a <= 0) return '';
    return `<span class="faint">win ${money(chosen / a, 0)}</span>`;
  };

  return `<div class="panel panel-pad predict-ticket" style="margin-top:14px">
    <div class="section-head" style="margin:0 0 12px">
      <h2 style="font-size:15px">${r.autoBet === false ? 'It is advising, not betting' : 'The call'}</h2>
      <span class="spacer"></span>
      ${d?.wouldStake != null ? `<span class="hint">it would stake ${money(d.wouldStake)}</span>` : ''}
    </div>
    <div class="note ${clears ? 'accent' : ''}" style="margin:0 0 14px">
      <span class="note-icon">${clears ? '✓' : '›'}</span><span>${headline}</span></div>

    <div class="predict-buy">
      <button class="predict-side-btn up" data-side="Up" ${disabled ? 'disabled' : ''}>
        <span>Up ${cents(p.upAsk)}</span>${payout('Up')}</button>
      <button class="predict-side-btn down" data-side="Down" ${disabled ? 'disabled' : ''}>
        <span>Down ${cents(p.downAsk)}</span>${payout('Down')}</button>
    </div>

    ${/* Deliberately not `data-keep`. The selection is already repaint-safe because
          it lives in `draft.stake` and is rendered from there, and marking the row
          kept would freeze its children — so the buttons would not grey out when a
          bet lands or the window closes, which is the one thing they must do. */''}
    <div class="predict-stakes">
      <span class="metric-label">Stake</span>
      ${choices.map((s) => `<button class="pill ${s === chosen ? 'is-on' : ''}" data-stake="${s}"
        ${disabled || s > Math.min(cap, free) + 0.01 ? 'disabled' : ''}>${money(s, 0)}</button>`).join('')}
      <span class="spacer"></span>
      <span class="hint">capped at ${money(cap, 0)} a window · ${money(free, 0)} free</span>
    </div>
    ${p.windowBestEdge != null && p.windowBestEdge > (edge ?? -1) + 0.0005
      ? `<div class="hint" style="margin-top:12px">Best this window so far: <strong>${cents(p.windowBestEdge)}</strong>
         at ${(p.windowBestOffset ?? 0).toFixed(0)}s in${
           (p.windowBestOffset ?? 0) < (p.effectiveEntryOffset ?? 90)
             ? ` — <em>before</em> the ${(p.effectiveEntryOffset ?? 90).toFixed(0)}s the desk waits for, so it was never allowed to take it.`
             : '.'}</div>`
      : ''}
    <div class="hint faint" style="margin-top:10px">Pressing one of these skips the edge bar and nothing
      else. One bet per window, the per-window cap, the loss limit, Polymarket's minimum order and the
      real depth of the book all still apply, and the fill walks the book exactly as the desk's own
      would — so the price you get is what the depth cost, not the best offer.</div>
  </div>`;
}


/* What the windows before this one had been doing, and whether that is allowed to
   count for anything yet. */
function regimePanel(p) {
  const r = p.regime;
  /* `regimeModel`, not `regime` — the Swift side exposes a computed `regime` that
   * falls back to an unlearned model, and a computed property is not encoded by
   * Codable, so asking for it here gets `undefined` and the panel renders as though
   * nothing had ever been fitted. The same trap that ate `maxStake` and a bet's
   * `won` before it. */
  const model = p.brain?.regimeModel;
  if (!r && !model) return '';
  const on = model && !model.isDefault && model.kappa > 0;
  const fc = p.forecast;

  const rows = [
    ['Run of same-way windows', r?.run, (v) => `${v > 0 ? '+' : ''}${v.toFixed(0)}`],
    ['Drift over the last hour', r?.drift, (v) => `${v > 0 ? '+' : ''}${v.toFixed(2)} sd`],
    ['The window just gone', r?.last, (v) => `${v > 0 ? '+' : ''}${v.toFixed(2)} sd`],
    ['Volatility shift', r?.volShift, (v) => `${v > 0 ? '+' : ''}${v.toFixed(2)}`],
    ['Just reversed', r?.reversal, (v) => (v > 0 ? 'yes' : 'no')],
  ];
  const contrib = Object.fromEntries((p.regimeReadings ?? []).map((x) => [x.name, x.contribution]));

  return `<div class="panel panel-pad" style="margin-top:14px">
    <div class="section-head" style="margin:0 0 10px">
      <h2 style="font-size:15px">The hour behind this window</h2>
      <span class="spacer"></span>
      <span class="num ${on ? 'up' : 'dim'}">${on
        ? `${(fc?.regimeAdjustment ?? 0) >= 0 ? '+' : ''}${(fc?.regimeAdjustment ?? 0).toFixed(2)} log-odds`
        : 'not in use'}</span>
    </div>
    ${r ? rows.map(([name, v, fmt]) => `<div class="predict-skip">
      <span>${esc(name)}</span>
      <span class="num ${v == null ? 'dim' : ''}">${v == null ? '—' : fmt(v)}${
        on && contrib[name] != null
          ? ` <span class="faint">${contrib[name] >= 0 ? '+' : ''}${contrib[name].toFixed(2)}</span>`
          : ''}</span>
    </div>`).join('')
    : '<div class="hint">Not enough tape behind this window to read the hour before it yet.</div>'}
    <div class="hint" style="margin-top:10px">${esc(model?.summary ?? '')}</div>
  </div>`;
}

/**
 * Everything that is a reason rather than a fact, folded away.
 *
 * The tab had grown to eleven panels of equal weight, which is a reference manual
 * rather than a screen — and the three things someone actually needs on opening it
 * (what is the price, what does it think, can I act) were somewhere in the middle
 * of it. These are all still here and all still one click away; they are just no
 * longer competing with the decision.
 */
function details(p) {
  return `<details class="predict-details">
    <summary>The numbers behind it</summary>
    <div style="margin-top:14px">${windowPanel(p)}</div>
    ${regimePanel(p)}
    ${feedPanel(p)}
    ${fidelityNote(p)}
  </details>`;
}

/* -------------------------------------------------------------- the record */

/**
 * What survives closing the app.
 *
 * This section exists because the honest answer to "is it calibrating from its
 * mistakes?" used to be that you could not tell from the app. The desk learned
 * from every window it watched and none of it was visible: three fitted numbers
 * with no history, no record of a finished run — `clear` deleted one and starting
 * another overwrote it — and no way to see whether the model was any good.
 *
 * So it is three panels answering three different questions, in the order they are
 * worth asking: is the model any good, has the desk changed its mind, and what has
 * it been doing.
 */
function record(j) {
  if (!j) return '';
  return `
    <div class="section-head" style="margin-top:32px">
      <h2>The record</h2>
      <span class="hint">Read from disk, not from this session — closing the app does not touch any of it.</span>
    </div>
    ${scoreboard(j)}
    ${offsetProfile(j)}
    ${brainLog(j.changes, j.brain)}
    ${runHistory(j.runs)}`;
}

/* The model against the market, which is the only comparison that means anything:
 * a Brier score on its own has no scale. */
function scoreboard(j) {
  const sc = j.score;
  const ahead = sc.windows > 0 && sc.modelBrier < sc.marketBrier;
  const brier = (v) => (v == null ? '—' : v.toFixed(4));

  const waiting = j.windowsRecorded - j.windowsResolved;
  const counts = `${j.windowsRecorded} window${j.windowsRecorded === 1 ? '' : 's'} watched ·
    ${j.windowsResolved} resolved${waiting > 0 ? ` · ${waiting} still with Polymarket's resolver` : ''}${
      j.windowsDegraded > 0 ? ` · ${j.windowsDegraded} kept but not fitted, recorded on the fallback feed` : ''}`;

  if (!sc.windows) {
    return `<div class="panel panel-pad">
      <div class="metric-label" style="margin-bottom:10px">How good the model has been</div>
      <div class="hint">${esc(sc.summary)}</div>
      <div class="hint faint" style="margin-top:8px">${counts}</div>
    </div>`;
  }

  return `<div class="panel panel-pad">
    <div class="metric-label" style="margin-bottom:12px">How good the model has been</div>
    <div class="stat-grid">
      <div class="stat"><span class="stat-label">Model, by Brier</span>
        <span class="stat-value ${ahead ? 'up' : ''}">${brier(sc.modelBrier)}</span>
        <span class="stat-note">lower is better · a coin flip scores 0.2500</span></div>
      <div class="stat"><span class="stat-label">Market, by Brier</span>
        <span class="stat-value ${ahead ? '' : 'up'}">${brier(sc.marketBrier)}</span>
        <span class="stat-note">the benchmark it has to beat</span></div>
      <div class="stat"><span class="stat-label">What it decides on</span>
        <span class="stat-value">${brier(sc.blendBrier)}</span>
        <span class="stat-note">the two blended at the weight in force</span></div>
      <div class="stat"><span class="stat-label">Called the right side</span>
        <span class="stat-value">${(sc.modelHitRate * 100).toFixed(1)}%</span>
        <span class="stat-note">market ${(sc.marketHitRate * 100).toFixed(1)}% · the weaker measure</span></div>
    </div>
    <div class="hint" style="margin-top:12px">${esc(sc.summary)}</div>
    <div class="hint faint" style="margin-top:8px">${counts}</div>
    ${calibrationTable(sc.calibration)}
  </div>`;
}

/**
 * Stated confidence against how often that confidence was right.
 *
 * This is the table that actually answers the word "calibrating". A model can have
 * a fine hit rate and still be badly calibrated — saying 90% about things that
 * happen 60% of the time is the failure that turns a quarter of Kelly into a third
 * of the bankroll, and it is invisible in every other number on this screen.
 */
function calibrationTable(bands) {
  if (!bands?.length) return '';
  return `<div style="margin-top:16px">
    <div class="metric-label" style="margin-bottom:8px">Is it honest about its own confidence?</div>
    ${bands.map((b) => {
      const drift = b.actual - b.claimed;
      const tone = Math.abs(drift) < 0.05 ? '' : drift < 0 ? 'down' : 'up';
      return `<div class="predict-skip">
        <span>Said ${(b.claimed * 100).toFixed(0)}% <span class="faint">(${b.windows} look${b.windows === 1 ? '' : 's'})</span></span>
        <span class="num ${tone}">was right ${(b.actual * 100).toFixed(0)}%
          <span class="faint">${drift >= 0 ? '+' : ''}${(drift * 100).toFixed(0)} pts</span></span>
      </div>`;
    }).join('')}
    <div class="hint faint" style="margin-top:8px">A well-calibrated model lands on the line: the things it
      calls 70% happen about 70% of the time. Sitting above it is underconfidence, which costs
      opportunities; sitting below it is overconfidence, which costs money.</div>
  </div>`;
}

/**
 * What each moment in a window has been worth, historically.
 *
 * The entry-offset fit answers "which offset should the desk use" and answers it
 * conservatively — forty qualifying looks in a bucket and a winner that beats the
 * field by more than a standard error — so for the first day of running it correctly
 * says nothing. That is right for a number that changes behaviour and no use at all
 * for the question underneath it: **is the edge already gone by the time the desk is
 * allowed to look?**
 *
 * This is the same data with no decision attached, and every row carries the count
 * it stands on. A row built on nine windows is not evidence and is shown with a nine
 * on it.
 */
function offsetProfile(j) {
  const rows = j.offsets ?? [];
  const entry = j.brain?.entryOffsetSeconds ?? 90;
  if (!rows.length) {
    return `<div class="panel panel-pad" style="margin-top:14px">
      <div class="metric-label" style="margin-bottom:10px">When the edge shows up</div>
      <div class="hint">Nothing has resolved yet. Every window is sampled every fifteen seconds from
        0:30 to 4:30, whether or not the desk is allowed to act at that point, so this fills in across
        the whole window rather than only the part it trades.</div>
    </div>`;
  }
  const best = Math.max(...rows.map((r) => r.meanReturn));
  return `<div class="panel panel-pad" style="margin-top:14px">
    <div class="metric-label" style="margin-bottom:10px">When the edge shows up</div>
    <div class="scroll-x"><table>
      <thead><tr><th>Seconds in</th><th class="right">Windows</th><th class="right">Edge appeared</th>
        <th class="right">Took it</th><th class="right">Return a dollar</th>
        <th class="right">Model vs market</th></tr></thead>
      <tbody>${rows.map((r) => {
        const sharper = r.modelBrier < r.marketBrier;
        const thin = r.qualified < 40;
        return `<tr${Math.abs(r.offset - entry) < 8 ? ' style="background:color-mix(in srgb,var(--accent) 7%,transparent)"' : ''}>
          <td class="num">${r.offset.toFixed(0)}s${Math.abs(r.offset - entry) < 8 ? ' <span class="faint">entry</span>' : ''}</td>
          <td class="right num dim">${r.samples}</td>
          <td class="right num">${(r.edgeRate * 100).toFixed(0)}%</td>
          <td class="right num ${thin ? 'dim' : ''}">${r.qualified}</td>
          <td class="right num ${r.qualified === 0 ? 'dim' : r.meanReturn > 0 ? 'up' : 'down'}">${
            r.qualified === 0 ? '—' : `${r.meanReturn >= 0 ? '+' : ''}${(r.meanReturn * 100).toFixed(1)}%`}${
            r.meanReturn === best && r.qualified > 0 ? ' <span class="faint">best</span>' : ''}</td>
          <td class="right num ${sharper ? 'up' : 'dim'}">${r.modelBrier.toFixed(3)} / ${r.marketBrier.toFixed(3)}</td>
        </tr>`;
      }).join('')}</tbody>
    </table></div>
    <div class="hint" style="margin-top:10px">Read the <em>Took it</em> column before the return beside it:
      a bucket where only a handful of looks ever qualified can show a huge number for reasons that have
      nothing to do with the offset. The fit that actually moves the entry wants forty in a bucket and a
      winner clear of the field by more than its own standard error, which is deliberately harder than
      eyeballing this table — but this is the table the fit is reading.</div>
  </div>`;
}

/* Every time a fitted number actually moved. A parameter that never moves is a
 * parameter that never learned anything, and that has to be as visible as one that
 * did — which is why this says so rather than rendering nothing. */
function brainLog(changes, b) {
  const pending = b ? [
    b.feedIsDefault ? `the feed gap needs ${30 - (b.feedWindows ?? 0)} more resolved windows` : null,
    b.weightIsDefault ? `the model's weight needs ${100 - (b.weightWindows ?? 0)} more` : null,
    b.offsetIsDefault ? 'the entry offset has not found a bucket that beats the field by more than its own standard error' : null,
  ].filter(Boolean) : [];

  if (!changes?.length) {
    return `<div class="panel panel-pad" style="margin-top:14px">
      <div class="metric-label" style="margin-bottom:10px">What it has changed its mind about</div>
      <div class="hint">Nothing yet — every parameter is still the value the app shipped with.
        ${pending.length ? `Currently ${pending.join(', and ')}.` : ''}
        This list fills in as answers arrive, and an entry here is the desk revising a number it was
        given, on evidence it gathered itself.</div>
    </div>`;
  }

  return `<div class="panel panel-pad" style="margin-top:14px">
    <div class="metric-label" style="margin-bottom:10px">What it has changed its mind about</div>
    ${changes.slice(0, 12).map((c) => `<div class="predict-skip">
      <span>${esc(c.parameter === 'feed-gap' ? 'Gap to the resolver'
        : c.parameter === 'model-weight' ? 'Weight the model is allowed' : 'Entry into the window')}
        ${c.firstMeasurement ? '<span class="faint">— first measurement</span>' : ''}
        <span class="faint">${dateTime(c.at)}</span></span>
      <span class="num">${c.from.toFixed(1)} → ${c.to.toFixed(1)}${esc(unitOf(c.parameter))}
        <span class="faint">${c.evidence} windows</span></span>
    </div>`).join('')}
    ${pending.length ? `<div class="hint faint" style="margin-top:10px">Still on its shipped default:
      ${pending.join(', and ')}.</div>` : ''}
  </div>`;
}

const unitOf = (p) => (p === 'feed-gap' ? ' bps' : p === 'model-weight' ? '%' : 's');

/* Every finished run, including the ones that bought nothing — which is most of
 * them, and which is the point: a run that correctly declined every window is a
 * result, and a history that only kept the ones that traded would be a history of
 * the exception. */
function runHistory(runs) {
  if (!runs?.length) {
    return `<div class="panel panel-pad" style="margin-top:14px">
      <div class="metric-label" style="margin-bottom:10px">Finished runs</div>
      <div class="hint">No run has finished yet. Every one is archived when it ends, and clearing a run
        off the screen no longer removes it from here.</div>
    </div>`;
  }
  return `<div class="section-head" style="margin-top:22px"><h2 style="font-size:15px">Finished runs</h2>
      <span class="hint">${runs.length} kept. A run that bought nothing is a result, not a blank.</span></div>
    <div class="panel scroll-x"><table>
      <thead><tr><th>Started</th><th class="right">Length</th><th class="right">Entry</th>
        <th class="right">Read</th><th class="right">Bought</th><th class="right">Right</th>
        <th class="right">Closest miss</th><th class="right">P/L</th><th>Ended</th></tr></thead>
      <tbody>${runs.slice(0, 40).map((r) => {
        const pnl = (r.bets ?? []).reduce((n, b) => n + (b.pnl ?? 0), 0);
        const settled = (r.bets ?? []).filter((b) => b.resolved != null);
        const wins = settled.filter((b) => b.resolved === b.side).length;
        const m = r.closestMiss;
        return `<tr>
          <td>${dateTime(r.startedAt)}</td>
          <td class="right num">${(r.minutes ?? 0).toFixed(0)}m</td>
          <td class="right num dim">${(r.entryOffsetSeconds ?? 0).toFixed(0)}s</td>
          <td class="right num">${r.windowsSeen ?? 0}</td>
          <td class="right num">${(r.bets ?? []).length}</td>
          <td class="right num">${settled.length ? `${wins}/${settled.length}` : '—'}</td>
          <td class="right num ${m ? '' : 'dim'}">${m
            ? `${(m.edge * 100).toFixed(1)}¢ of ${(m.required * 100).toFixed(1)}¢`
            : '—'}</td>
          <td class="right num ${pnl > 0 ? 'up' : pnl < 0 ? 'down' : 'dim'}">${
            (r.bets ?? []).length ? signedMoney(pnl) : '—'}</td>
          <td class="faint">${esc(statusLabel(r.status))}</td>
        </tr>`;
      }).join('')}</tbody>
    </table></div>`;
}

const statusLabel = (s) => ({
  'met-target': 'Target reached', 'hit-loss-limit': 'Loss limit hit',
  'out-of-time': 'Time up', stopped: 'Ended early', running: 'Running',
}[s] ?? s ?? '—');

function windowLabel(w) {
  const d = new Date(w.start * 1000);
  const e = new Date((w.start + 300) * 1000);
  const t = (x) => `${String(x.getHours()).padStart(2, '0')}:${String(x.getMinutes()).padStart(2, '0')}`;
  return `${t(d)}–${t(e)}`;
}

/* ------------------------------------------------------------------ clocks */

/** Both clocks tick locally so neither looks frozen between ten-second polls. */
function tickClocks() {
  clearInterval(tickClocks.timer);
  tickClocks.timer = setInterval(() => {
    let alive = false;
    for (const id of ['windowClock', 'runClock']) {
      const node = document.getElementById(id);
      if (!node || !node.dataset.ends) continue;
      alive = true;
      node.textContent = clock((Number(node.dataset.ends) - Date.now()) / 1000);
    }
    if (!alive) clearInterval(tickClocks.timer);
  }, 1000);
}

/* -------------------------------------------------------------------- wire */

function wire(host) {
  /* `onclick =`, not `addEventListener`.
   *
   * `paint` runs every ten seconds off the poll and calls this function each
   * time, and `morph` patches the DOM in place rather than replacing it — so the
   * button node survives every repaint. With `addEventListener` each pass hung
   * another copy of this handler on the same node and none of them ever came off.
   * Two and a half minutes on the tab meant fifteen listeners, so one click on
   * *Re-run the contest* fired fifteen contests, posted fifteen times, and stacked
   * fifteen identical toasts up the screen. Assignment replaces; it cannot
   * accumulate. Every other control in this function was already written that way
   * and this one was the exception. */
  const rerun = host.querySelector('[data-rerun-contest]');
  if (rerun) rerun.onclick = async (e) => {
    const btn = e.currentTarget;
    if (btn.disabled) return;
    btn.disabled = true;
    btn.textContent = 'Scoring…';
    try {
      audit = await api.runPredictContest();
      paint(host);
      toast(audit.policy?.isDefault
        ? 'Contest re-run. Nothing beat the market, so the reading is unchanged.'
        : `Contest re-run. Now reading with ${audit.policy.candidateId}.`);
    } catch (err) {
      toast(err.message, 'err');
      // Re-enabled by hand on the failure path only: the success path repaints,
      // and a repaint rebuilds the button from the audit it just fetched.
      btn.disabled = false;
      btn.textContent = 'Re-run the contest';
    }
  };
  const val = (id) => Number(document.getElementById(id)?.value ?? 0);

  /* Each control owns one field of the draft. Written on the way in rather than
   * read on the way out, so what the form is set to survives a repaint and a trip
   * to another tab, and the label beside a slider is updated from the same edit. */
  const bankroll = host.querySelector('#bankrollInput');
  if (bankroll) bankroll.oninput = () => { draft.bankroll = Number(bankroll.value) || 0; };

  const offsetEl = host.querySelector('#offsetInput');
  const offsetLabelEl = host.querySelector('#offsetLabel');
  if (offsetEl) offsetEl.oninput = () => {
    draft.offset = Number(offsetEl.value) || 0;
    if (offsetLabelEl) {
      offsetLabelEl.textContent = draft.offset === 0 ? 'nothing, let the edge decide' : draft.offset + 's';
    }
  };

  for (const [input, label, key] of [
    ['edgeInput', 'edgeLabel', 'edge'], ['kellyInput', 'kellyLabel', 'kelly'],
    ['stakeCapInput', 'stakeCapLabel', 'stakeCap'],
    ['lossInput', 'lossLabel', 'loss'], ['targetInput', 'targetLabel', 'target'],
  ]) {
    const el = host.querySelector(`#${input}`);
    if (!el) continue;
    el.oninput = () => {
      draft[key] = Number(el.value);
      host.querySelector(`#${label}`).textContent = el.value;
    };
  }

  host.querySelectorAll('#lengthRow .pill').forEach((b) => {
    b.onclick = () => {
      host.querySelectorAll('#lengthRow .pill').forEach((x) => x.classList.remove('is-on'));
      b.classList.add('is-on');
      draft.minutes = Number(b.dataset.minutes);
    };
  });

  const start = host.querySelector('#startPredictBtn');
  if (start) start.onclick = async () => {
    if (working) return;
    working = true;
    start.disabled = true;
    try {
      panel = await api.startPredict({
        bankroll: val('bankrollInput'),
        minutes: Number(host.querySelector('#lengthRow .pill.is-on')?.dataset.minutes ?? 60),
        minEdge: val('edgeInput') / 100,
        kellyFraction: val('kellyInput') / 100,
        maxStakePct: val('stakeCapInput'),
        entryOffsetSeconds: val('offsetInput'),
        maxLossPct: val('lossInput'),
        targetPct: val('targetInput'),
        autoBet: draft.autoBet !== false,
        recovery: draft.recovery === true,
      });
      paint(host);
      startPolling(host);
      toast(draft.autoBet === false
        ? 'Watching. It will tell you what it would do and leave the button to you.'
        : 'Watching. It will bet only when the price and the model disagree.', 'ok');
    } catch (e) {
      toast(e.message, 'bad', 7000);
      start.disabled = false;
    } finally { working = false; }
  };

  const end = host.querySelector('#endPredictBtn');
  if (end) end.onclick = async () => {
    if (working) return;
    working = true;
    end.disabled = true;
    try {
      panel = await api.endPredict();
      paint(host);
      await refreshView();
    } catch (e) { toast(e.message, 'bad'); end.disabled = false; }
    finally { working = false; }
  };

  const clear = host.querySelector('#clearPredictBtn');
  if (clear) clear.onclick = async () => {
    if (working) return;
    working = true;
    try { panel = await api.clearPredict(); paint(host); }
    catch (e) { toast(e.message, 'bad'); }
    finally { working = false; }
  };

  /* The ticket. Stake lives in `draft` rather than in the DOM because this view
   * repaints every two seconds while a run is live, and a choice that does not
   * survive a repaint is a choice you cannot make. */
  host.querySelectorAll('.predict-stakes .pill').forEach((b) => {
    b.onclick = () => {
      draft.stake = Number(b.dataset.stake);
      host.querySelectorAll('.predict-stakes .pill').forEach((x) => x.classList.remove('is-on'));
      b.classList.add('is-on');
    };
  });

  host.querySelectorAll('.predict-side-btn').forEach((b) => {
    b.onclick = async () => {
      if (working) return;
      working = true;
      host.querySelectorAll('.predict-side-btn').forEach((x) => { x.disabled = true; });
      try {
        panel = await api.placePredictBet(b.dataset.side, draft.stake ?? 25);
        paint(host);
        toast(`Bought ${b.dataset.side}. It settles on Polymarket's published result.`, 'ok');
      } catch (e) {
        toast(e.message, 'bad', 7000);
        host.querySelectorAll('.predict-side-btn').forEach((x) => { x.disabled = false; });
      } finally { working = false; }
    };
  });

  host.querySelectorAll('#recoveryRow .pill').forEach((b) => {
    b.onclick = () => {
      host.querySelectorAll('#recoveryRow .pill').forEach((x) => x.classList.remove('is-on'));
      b.classList.add('is-on');
      draft.recovery = b.dataset.recovery === 'yes';
    };
  });

  host.querySelectorAll('#autoBetRow .pill').forEach((b) => {
    b.onclick = () => {
      host.querySelectorAll('#autoBetRow .pill').forEach((x) => x.classList.remove('is-on'));
      b.classList.add('is-on');
      draft.autoBet = b.dataset.auto === 'yes';
    };
  });

  // The whole case for a bet is written down when it is placed. Clicking the row
  // is how you read it back, rather than it being lost behind a summary.
  host.querySelectorAll('.predict-bet').forEach((row) => {
    row.style.cursor = 'pointer';
    row.onclick = () => toast(row.dataset.thesis, 'ok', 14_000);
  });
}

/* ------------------------------------------------------- the learning audit */

const VERDICT_TONE = { healthy: 'up', waiting: 'dim', blocked: 'warn-text', broken: 'down' };
const VERDICT_MARK = { healthy: '✓', waiting: '·', blocked: '!', broken: '!' };

/**
 * Whether this desk is learning, and what it has learned.
 *
 * Its own block rather than a number in the header, because the honest answer is
 * never one number. A desk can be taking in evidence, fitting it correctly, and
 * still be unable to act on any of it — that was the real state of this one, and
 * no single figure on any screen said so. Five checks, each with a verdict, and
 * the worst of them carries.
 */
function learningAudit(a) {
  if (!a) return '';
  const tone = VERDICT_TONE[a.verdict] ?? 'dim';
  return `
    <div class="section-head" style="margin-top:26px">
      <h2>Is it learning?</h2>
      <span class="hint">Five checks over the shadow book, the fitted parameters and the real bets.</span>
      <span class="spacer"></span>
      <button class="btn sm" data-rerun-contest title="Re-scores every candidate reading against the market, now rather than on its hourly clock.">Re-run the contest</button>
    </div>

    <div class="note ${a.verdict === 'healthy' ? '' : 'warn'}" style="margin-bottom:14px">
      <span class="note-icon">${VERDICT_MARK[a.verdict] ?? '·'}</span>
      <span><strong class="${tone}">${esc((a.verdict || '').toUpperCase())}</strong> — ${esc(a.headline)}</span>
    </div>

    <div class="panel" style="padding:0;margin-bottom:14px">
      ${(a.checks || []).map(checkRow).join('')}
    </div>

    ${candidateTable(a)}`;
}

function checkRow(c) {
  const tone = VERDICT_TONE[c.verdict] ?? 'dim';
  return `
    <div style="padding:13px 15px;border-bottom:1px solid var(--line)">
      <div class="row" style="gap:10px;align-items:baseline">
        <span class="chip ${c.verdict === 'healthy' ? 'ghost' : 'ghost ' + tone}" style="font-size:10.5px">${esc(c.verdict)}</span>
        <strong style="font-size:13px">${esc(c.question)}</strong>
      </div>
      <p style="font-size:12.5px;line-height:1.6;margin:8px 0 0;color:var(--text-dim)">${esc(c.finding)}</p>
      ${c.remedy ? `<p class="faint" style="font-size:12px;line-height:1.6;margin:8px 0 0">→ ${esc(c.remedy)}</p>` : ''}
      ${(c.readings || []).length ? `<div style="margin-top:10px;display:grid;grid-template-columns:auto 1fr;gap:3px 14px;font-size:11.5px">
        ${c.readings.map((r) => `
          <span class="${r.flagged ? 'warn-text' : 'faint'}" style="white-space:nowrap">${r.flagged ? '! ' : ''}${esc(r.name)}</span>
          <span style="font-family:var(--mono)">${esc(r.value)}</span>`).join('')}
      </div>` : ''}
    </div>`;
}

/**
 * The field, and what each row was actually testing.
 *
 * The `asks` line is the point of showing this at all. A table of Brier scores
 * is six numbers; a table that says what question each reading was posing is a
 * record of what has been ruled out, which is the useful thing when the answer
 * keeps coming back "nothing beats the price".
 */
function candidateTable(a) {
  const rows = a.candidates || [];
  if (!rows.length) return '';
  return `
    <div class="panel scroll-x">
      <div style="padding:13px 15px 4px">
        <strong style="font-size:13px">Every reading, scored on windows it was never fitted on</strong>
        <p class="faint" style="font-size:11.5px;line-height:1.6;margin:6px 0 0">
          Walk-forward, split on window boundaries, paired against the reading in force with the
          standard error clustered by window — sixteen samples inside one five-minute window share
          a single outcome, and counting them as sixteen observations overstates the evidence
          fourfold. A challenger is promoted at ${(a.promotionSigma ?? 2).toFixed(0)}σ, and demoted if it stops clearing that bar.
        </p>
      </div>
      <table>
        <thead><tr>
          <th>Reading</th><th class="right">Brier</th>
          <th class="right">vs in force</th><th class="right">σ</th><th>Verdict</th>
        </tr></thead>
        <tbody>${rows.map((r) => `<tr>
          <td>
            <div style="font-size:12.5px">${r.promotable ? '<strong class="up">promote</strong> · ' : ''}${esc(r.label)}</div>
            <div class="faint" style="font-size:11px;line-height:1.5;margin-top:2px">${esc(r.asks)}</div>
          </td>
          <td class="right num">${r.oosBrier.toFixed(5)}</td>
          <td class="right num ${r.gainOverChampion > 0 ? 'up' : r.gainOverChampion < 0 ? 'down' : ''}">${r.gainOverChampion >= 0 ? '+' : ''}${r.gainOverChampion.toFixed(5)}</td>
          <td class="right num">${r.sigma.toFixed(1)}</td>
          <td class="faint" style="font-size:11.5px;line-height:1.5">${esc(r.verdict)}</td>
        </tr>`).join('')}</tbody>
      </table>
    </div>`;
}
