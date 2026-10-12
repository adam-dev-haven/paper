/**
 * settings.js — one settings surface, mounted in two places.
 *
 * Everything that configures an account lives here and nowhere else. It renders
 * into the Profile tab full width, and into a sheet that opens over whatever you
 * were looking at from the gear in the top bar or ⌘, — same sections, same draft,
 * same save button. Two implementations of "risk per trade" would eventually
 * disagree, and the one that disagreed would be the one the engine actually used.
 *
 * The sections are ordered the way the reasoning runs, not the way the data
 * model is shaped: what you have, then what your situation is, then what the app
 * therefore allows, then what you would like, then what it costs. Risk appetite
 * sits deliberately *after* circumstances, because the suitability panel between
 * them has to be read before the slider means anything.
 *
 * The search box exists because a settings screen with forty controls is a
 * settings screen nobody finds anything in.
 */

import { store, toast, refreshView, go } from './app.js';
import { restartSetup } from './views/start.js';
import * as api from './api.js';
import { money, homeAmount, hasHome, plainPct, esc, currency as displayCurrency } from './format.js';
import { term, aside } from './glossary.js';
import { modal } from './modal.js';
import {
  renderAnalystSection, handleAnalystClick, wireAnalystInputs, loadAnalystPanel,
} from './views/analystsettings.js';

/* --------------------------------------------------------------- the options */

const GOALS = [
  ['growth', 'Grow the capital', 'Maximum appreciation, with drawdown accepted as the cost.'],
  ['income', 'Steady compounding', 'Low volatility. Requires a better ratio for the same risk.'],
  ['preservation', 'Preserve what I have', 'Keeping the capital is the objective; upside is secondary.'],
  ['speculation', 'Asymmetric bets', 'Most fail, so the winners must be large enough to pay for them.'],
  ['learning', 'Learn how this works', 'Balanced settings, weighted toward explanation over performance.'],
];

const HORIZONS = [
  ['intraday', 'Intraday', 'Hours. In and out inside the session.'],
  ['swing', 'Swing', 'Days to a couple of weeks.'],
  ['position', 'Position', 'Weeks to months.'],
  ['long-term', 'Long-term', 'Months to years, held through ordinary swings.'],
];

const INCOME = [
  ['none', 'No income right now', 'Nothing replaces what this account loses.'],
  ['irregular', 'Irregular / freelance', 'Arrives without a schedule you can plan a drawdown against.'],
  ['salaried', 'Steady salary', 'Losses are refilled over time.'],
  ['abundant', 'Well above outgoings', 'This money is spare.'],
];

const APPETITE = [
  ['stocks-only', 'Equities only'],
  ['crypto-only', 'Crypto only'],
  ['both', 'Equities and crypto'],
  ['index-first', 'Index-first'],
];

/* Which exchanges the account trades on, which is a separate question from what
   kind of asset. Someone in Stockholm may want equities and crypto but only the
   listings they can actually deal in before dinner; someone else wants both
   boards and the six-and-a-half-hour gap between them. */
const MARKETS = [
  ['us', 'United States', 'NYSE and Nasdaq, 09:30–16:00 New York. Quoted in dollars.'],
  ['stockholm', 'Stockholm', 'Nasdaq Stockholm, 09:00–17:30 local, its own holidays. Quoted in kronor.'],
  ['crypto', 'Crypto', 'Continuous. No close, no holidays, no day-trading rule.'],
];

/* The currencies a second figure can be read in. The ledger is dollars in every
   one of these cases — this list only decides what the small line underneath says. */
const CURRENCIES = [
  ['USD', 'US dollar', '$'],
  ['EUR', 'Euro', '€'],
  ['SEK', 'Swedish krona', 'kr'],
  ['GBP', 'Pound sterling', '£'],
  ['NOK', 'Norwegian krone', 'kr'],
  ['DKK', 'Danish krone', 'kr'],
  ['CHF', 'Swiss franc', 'CHF'],
  ['CAD', 'Canadian dollar', 'C$'],
  ['AUD', 'Australian dollar', 'A$'],
  ['JPY', 'Japanese yen', '¥'],
];

const PRESETS = [
  ['learner', 'Learning the ropes'],
  ['day-trader', 'Day trader'],
  ['long-term-grower', 'Long-term grower'],
  ['crypto-native', 'Crypto native'],
  ['capital-to-protect', 'Capital to protect'],
];

/* ------------------------------------------------------------------ the draft */

/** Edits are local until Save, so a half-typed number never resizes a live position. */
export const state = { draft: null, dirty: false, section: 'accounts', query: '' };

export function resetDraft() { state.draft = null; state.dirty = false; }

function sync() {
  const live = store.state?.profile;
  if (!live) return;
  if (!state.draft || state.draft.id !== live.id) {
    state.draft = structuredClone(live);
    state.dirty = false;
  }
}

function get(path) { return path.split('.').reduce((o, k) => o?.[k], state.draft); }

/** The profile being edited, or an empty object before one is loaded. */
function draft() { return state.draft ?? {}; }

/**
 * The markets a profile trades, with the same rule the engine uses: an empty list
 * is every market, never none. A profile written before Stockholm existed has no
 * list at all, and it should gain the new board rather than lose the old one.
 */
function marketsOf(p) {
  const m = p?.markets;
  return Array.isArray(m) && m.length ? m : MARKETS.map(([k]) => k);
}

function set(path, value) {
  const keys = path.split('.');
  const last = keys.pop();
  const target = keys.reduce((o, k) => o[k], state.draft);
  target[last] = value;
  state.dirty = true;
}

/* ------------------------------------------------------------- form pieces */

function field(path, label, value, type, hint) {
  return `<div class="field" data-search="${esc((label + ' ' + (hint ?? '')).toLowerCase())}">
    <label for="pf-${esc(path)}">${esc(label)}</label>
    <input id="pf-${esc(path)}" data-field="${esc(path)}" type="${type}"
           step="any" value="${esc(String(value ?? ''))}">
    ${hint ? `<span class="faint" style="font-size:11.5px">${hint}</span>` : ''}
  </div>`;
}

/**
 * A money field. Typed in dollars, stored in dollars, displayed in dollars.
 *
 * The number in the box is the number in the ledger, with no conversion between
 * them — which means it does not quietly drift as the rate moves, the way a field
 * that stored a converted value would. Underneath sits the same amount in the
 * reading currency, live as you type, because "is that the right order of
 * magnitude for me" is the question this field is actually asking and answering it
 * in dollars alone leaves it unanswered for anyone who does not earn in them.
 */
function moneyField(path, label, usdValue, hint) {
  const cur = displayCurrency();
  const value = Number(usdValue) || 0;
  const echo = cur.code === 'USD' ? ''
    : `<span class="money-echo" data-echo="${esc(path)}">≈ ${homeAmount(value, 0)}${
        cur.live ? '' : ' — standing estimate, the rate feed is unreachable'}</span>`;
  return `<div class="field" data-search="${esc((label + ' ' + (hint ?? '')).toLowerCase())}">
    <label for="pf-${esc(path)}">${esc(label)} <span class="unit">USD</span></label>
    <input id="pf-${esc(path)}" data-money="${esc(path)}" type="number" step="any"
           value="${Number.isFinite(value) ? Math.round(value * 100) / 100 : ''}">
    ${echo}
    ${hint ? `<span class="faint" style="font-size:11.5px">${hint}</span>` : ''}
  </div>`;
}

function slider(path, label, value, min, max, step, hint) {
  return `<div class="field" data-search="${esc((label + ' ' + hint).toLowerCase())}">
    <label for="pf-${esc(path)}">${label}</label>
    <input id="pf-${esc(path)}" data-slider="${esc(path)}" type="range"
           min="${min}" max="${max}" step="${step}" value="${value}">
    <span class="faint" style="font-size:11.5px">${hint}</span>
  </div>`;
}

function choices(path, label, options, current) {
  return `<div class="field" data-search="${esc((label + ' ' + options.map((o) => o[1]).join(' ')).toLowerCase())}">
    <label>${esc(label)}</label>
    <div class="choice-grid">
      ${options.map(([k, l, d]) => `
        <button class="choice ${current === k ? 'is-on' : ''}" data-set="${esc(path)}" data-value="${esc(k)}">
          <span class="choice-label">${esc(l)}</span>
          ${d ? `<span class="choice-note">${esc(d)}</span>` : ''}
        </button>`).join('')}
    </div>
  </div>`;
}

function toggle(path, label, on) {
  return `<button class="pill ${on ? 'is-on' : ''}" data-toggle="${esc(path)}" data-search="${esc(label.toLowerCase())}">
    <span class="pill-dot"></span>${esc(label)}</button>`;
}

const panel = (inner) => `<div class="panel panel-pad">${inner}</div>`;

/* -------------------------------------------------------------- the sections */

const SECTIONS = [
  {
    id: 'accounts', label: 'Accounts', keywords: 'account switch profile new delete ledger',
    render: (p, s) => `
      ${head('Accounts', 'Each one keeps its own ledger, its own history and its own scorecard.')}
      ${accountsPanel(s)}
      ${panel(`<div class="grid-2">
        ${field('name', 'Account name', p.name, 'text')}
        ${field('note', 'What this account is for', p.note, 'text')}
      </div>`)}`,
  },
  {
    id: 'money', label: 'Money', keywords: 'capital contribution deposit expenses savings currency amount',
    render: (p) => `
      ${head('Money', 'What is in the account, what goes in each month, and what it is measured against.')}
      ${panel(`
        <div class="grid-2">
          ${moneyField('startingCapital', 'Starting capital', p.startingCapital,
            'Takes effect when the account is reset. The opening balance of a ledger that has already traded is not rewritten.')}
          ${moneyField('monthlyContribution', 'Monthly contribution', p.monthlyContribution,
            'Paid in automatically on the first refresh of each month. The equity curve reports growth from deposits separately from growth from trading.')}
        </div>
        <div class="grid-2" style="margin-top:16px">
          ${moneyField('monthlyExpenses', 'Monthly expenses', p.monthlyExpenses,
            'Not spent from the account. Used to express losses in months of expenses.')}
          ${field('emergencyFundMonths', 'Months of expenses held elsewhere', p.emergencyFundMonths, 'number',
            'Cash outside this account. It is a large input into risk capacity.')}
        </div>`)}
      ${currencyPanel(p)}`,
  },
  {
    id: 'situation', label: 'Your situation', keywords: 'income job salary freelance unemployed capacity suitability',
    render: (p, s) => `
      ${head('Your situation', 'These set your risk capacity, which caps your stated appetite.')}
      ${panel(choices('incomeStability', 'Income', INCOME, p.incomeStability))}
      ${suitabilityPanel(s.suitability)}`,
  },
  {
    id: 'objective', label: 'Objective', keywords: 'goal horizon universe target return crypto equities',
    render: (p) => `
      ${head('Objective', 'What this money is for, and how long it has. Both change which setups are eligible.')}
      ${panel(`
        ${choices('goal', 'Objective', GOALS, p.goal)}
        <div style="margin-top:18px">${choices('horizon', 'Horizon', HORIZONS, p.horizon)}</div>
        ${p.horizon === 'intraday' ? intradayNote() : ''}
        <div class="grid-2" style="margin-top:18px">
          ${field('targetAnnualReturnPct', 'Target return, % a year', p.targetAnnualReturnPct, 'number',
            'Used by the review to report whether the method is on course.')}
          <div class="field" data-search="universe instruments crypto equities index">
            <label>Universe</label>
            <div class="pill-row">
              ${APPETITE.map(([k, l]) => `<button class="pill ${p.appetite === k ? 'is-on' : ''}" data-set="appetite" data-value="${k}">${esc(l)}</button>`).join('')}
            </div>
            <span class="faint" style="font-size:11.5px">Instruments outside it are shown but cannot be bought.
              Index-first is the only setting that makes the benchmarks tradeable.</span>
          </div>
        </div>

        <div class="field" style="margin-top:18px" data-search="markets exchanges stockholm sweden us venue omx">
          <label>Markets</label>
          <div class="pill-row">
            ${MARKETS.map(([k, l, d]) => `<button class="pill ${marketsOf(p).includes(k) ? 'is-on' : ''}"
              data-market="${k}" title="${esc(d)}">${esc(l)}</button>`).join('')}
          </div>
          <span class="faint" style="font-size:11.5px">Which exchanges this account deals on — a different
            question from what kind of asset. Prices and levels are always in the currency the exchange quotes
            in, so a Stockholm stop is a kronor level; the account itself still settles in dollars, and the
            rate moves the result alongside the stock. Turning them all off is read as all of them on.</span>
        </div>`)}`,
  },
  {
    id: 'risk', label: 'Risk', keywords: 'risk per trade position size drawdown open positions heat',
    render: (p) => `
      ${head('Risk and limits', 'What you would like to risk. The engine uses the smaller of this and what your circumstances support.')}
      ${aside('These set how much you are prepared to lose on one idea. The amount invested is derived from it and is never chosen directly.')}
      ${panel(`
        <div class="grid-2">
          ${slider('riskPctPerTrade', `${term('risk', 'Risk per trade')} — ${p.riskPctPerTrade}% of equity`, p.riskPctPerTrade, 0.25, 3, 0.25,
            `The amount lost if the stop fills, not the amount invested. At ${p.riskPctPerTrade}%, ten losers in a row costs about ${plainPct(p.riskPctPerTrade * 10, 0)} of the account.`)}
          ${slider('maxPositionPct', `Maximum single position — ${p.maxPositionPct}% of equity`, p.maxPositionPct, 5, 50, 5,
            'A ceiling on concentration. Without it, a quiet name with a tight stop can be sized into half the account.')}
        </div>
        <div class="grid-2" style="margin-top:18px">
          ${slider('maxOpenPositions', `Maximum open positions — ${p.maxOpenPositions}`, p.maxOpenPositions, 1, 12, 1,
            'Also the number of ideas the analyst may fund in one run.')}
          ${slider('drawdownTolerancePct', `${term('drawdown', 'Drawdown')} you would sit through — ${p.drawdownTolerancePct}%`, p.drawdownTolerancePct, 5, 60, 5,
            'Bounds total open risk: half of this figure is the most the engine will have at stake across every position at once.')}
        </div>`)}`,
  },
  {
    id: 'costs', label: 'Costs and rules', keywords: 'commission spread slippage tax market hours pattern day trader pdt',
    render: (p) => costsPanel(p),
  },
  {
    id: 'reading', label: 'Reading',
    keywords: 'plain language explain jargon currency display beginner mode opens landing guided record rules market desk',
    render: (p, s) => `
      ${head('How this reads', 'Where the app opens, and how much it explains.')}
      ${panel(`
        ${choices('readingMode', 'Opens on',
          (s.readingModes ?? []).map((m) => [m.id, m.label, m.note]), p.readingMode)}
        <p class="prose" style="font-size:12.5px;margin-top:4px">
          Changes no trading setting. Risk, horizon and universe stay where they are.
        </p>`)}
      ${panel(`
        <div class="row wrap" style="gap:10px">
          ${toggle('plainLanguage', 'Explain the terms as they are used', p.plainLanguage)}
        </div>
        <p class="prose" style="font-size:12.5px;margin-top:12px">
          With this on, headings carry a plain-language line underneath and every term is underlined and
          defined where it appears. With it off, the definitions are still available on hover and the
          underlines are not drawn. Picking a mode above sets this switch; changing it here leaves the
          mode where it is.
        </p>`)}`,
  },
  {
    id: 'analyst', label: 'Analyst', keywords: 'api key anthropic token budget cost spend limit diagnose troubleshoot check credential',
    render: () => renderAnalystSection(),
  },
  {
    id: 'learning', label: 'Calibration', keywords: 'learning memory lessons calibration adapt reset forget',
    render: (p, s) => learningPanel(s),
  },
  {
    id: 'danger', label: 'Reset', keywords: 'reset delete erase danger wipe',
    render: (p, s) => dangerPanel(s),
  },
];

function head(title, hint) {
  return `<div class="section-head"><h2>${esc(title)}</h2><span class="hint">${esc(hint)}</span></div>`;
}

/* ------------------------------------------------------------- the panels */

function accountsPanel(s) {
  return `<div class="panel">
    <div class="profile-grid">
      ${s.profiles.map((x) => `
        <button class="profile-card ${x.active ? 'is-on' : ''}" data-activate="${esc(x.id)}">
          <span class="profile-name">${esc(x.name)}</span>
          <span class="profile-meta">${esc(x.goal)} · ${esc(x.horizon.split(' —')[0])}</span>
          <span class="profile-equity">${money(x.equity, 0)}
            <span class="${x.totalPnlPct >= 0 ? 'up' : 'down'}" style="font-size:11.5px">
              ${x.totalPnlPct >= 0 ? '+' : ''}${x.totalPnlPct.toFixed(1)}%</span></span>
          <span class="profile-meta">${x.openPositions} open</span>
        </button>`).join('')}
      <button class="profile-card is-new" id="newProfileBtn">
        <span class="profile-name">+ New account</span>
        <span class="profile-meta">Answer a few questions, or start from a preset.</span>
      </button>
    </div>
    <div class="panel-pad" style="border-top:1px solid var(--line)">
      <span class="faint" style="font-size:12px">Each account keeps its own ledger, history, scorecard and
      calibration. A day trader and a long-term holder on one equity curve would produce no readable record
      for either.</span>
    </div>
  </div>`;
}

function currencyPanel(p) {
  const cur = displayCurrency();
  return `
    ${head('Second currency', 'What the small figure under each amount is read in. The account itself is always dollars.')}
    ${panel(`
      <div class="field" data-search="currency usd eur sek nok dkk gbp chf cad aud jpy krona euro dollar krone franc yen pound">
        <label>Read amounts alongside in</label>
        <div class="pill-row">
          ${CURRENCIES.map(([code, name, sym]) => `
            <button class="pill ${p.currency === code ? 'is-on' : ''}" data-set="currency" data-value="${code}">
              ${esc(sym)} ${esc(name)}</button>`).join('')}
        </div>
      </div>
      <div class="note accent" style="margin-top:14px"><span class="note-icon">›</span><span>
        <strong>Every figure here is in US dollars</strong>: the balance, the cash, the profit, the risk,
        the costs, the prices and every field you type an amount into. That is the currency these
        instruments are quoted and traded in.
        ${cur.code === 'USD'
          ? 'Pick a currency above and a smaller second figure appears beside the amounts worth translating.'
          : `Picking ${esc(cur.code)} adds a smaller <span class="money-sub is-inline">≈ figure</span> beside the
             amounts worth translating, converted at ${cur.rate.toFixed(4)} ${esc(cur.code)} per USD${
               cur.live ? ', live' : ', a standing estimate while the rate feed is unreachable'}. It is a
             reading aid: no order is placed in ${esc(cur.code)}, and nothing is stored in it.`}
      </span></div>
      <p class="prose" style="font-size:12.5px;margin-top:12px">
        This was set from your Mac's region on first launch, and can be changed here at any time.
      </p>
      <p class="prose" style="font-size:12.5px;margin-top:8px">
        The ledger settles in dollars, which is what every instrument here is quoted in. That means a real
        account funded in ${esc(p.currency === 'USD' ? 'a non-dollar currency' : p.currency)} holding these
        positions would also carry a dollar exposure of the same size, whose swings land in the profit
        alongside the position's. The desk states the size of that exposure rather than modelling it, which
        would require re-denominating every past fill at the rate that applied on the day.
      </p>`)}`;
}

function suitabilityPanel(sui) {
  const cap = sui.capacity;
  const colour = cap >= 66 ? 'var(--up)' : cap >= 40 ? 'var(--warn)' : 'var(--down)';
  return `
    ${head('Suitability', 'Appetite is what you want; capacity is what your circumstances survive. Sizing follows the smaller of the two.')}
    <div class="panel panel-pad">
      <div class="grid-2">
        <div>
          <div class="score-row" style="grid-template-columns:112px 1fr 44px">
            <span class="dim">${term('capacity', 'Risk capacity')}</span>
            <div class="score-track"><div class="score-fill" style="width:${cap}%;background:${colour}"></div></div>
            <span class="num dim">${cap.toFixed(0)}</span>
          </div>
          <span class="faint" style="font-size:11.5px">Computed from income, contributions, the buffer held
            elsewhere and the horizon. Your stated appetite is not an input.</span>
        </div>
        <div class="metric-grid" style="grid-template-columns:repeat(3,1fr)">
          <div class="metric"><div class="metric-label">You asked for</div>
            <div class="metric-value">${sui.statedRiskPct.toFixed(2)}%</div></div>
          <div class="metric"><div class="metric-label">Situation supports</div>
            <div class="metric-value">${sui.suitableRiskPct.toFixed(2)}%</div></div>
          <div class="metric"><div class="metric-label">Engine uses</div>
            <div class="metric-value ${sui.capped ? 'warn-text' : 'up'}">${sui.effectiveRiskPct.toFixed(2)}%</div></div>
        </div>
      </div>
      <div class="note ${sui.capped ? 'warn' : 'accent'}" style="margin-top:16px">
        <span class="note-icon">${sui.capped ? '!' : '›'}</span><span>${esc(sui.note)}</span>
      </div>
      <div class="faint" style="font-size:12px;margin-top:12px">
        Total open risk across every position at once is capped at ${plainPct(sui.maxHeatPct, 1)} of equity.
        Five positions each risking the full per-trade budget is a five-times bet, which the per-trade limit
        alone does not catch.
      </div>
    </div>`;
}

function intradayNote() {
  return `<div class="note warn" style="margin-top:14px">
    <span class="note-icon">!</span>
    <span><strong>Intraday here does less than the name suggests.</strong> Outside the Session tab the
    engine reads daily bars, which cannot resolve a trade opened and closed inside one session. This setting
    buys the tightest stops and fastest setups the daily data supports. The pattern-day-trader limit and the
    short-term tax rate are still enforced. For real intraday work, use the Session tab.</span>
  </div>`;
}

function costsPanel(p) {
  const f = p.frictions;
  return `
    ${head('Costs and rules', 'The frictions a paper account normally omits, switched on.')}
    ${aside('These are what trading costs. They are small on any one trade and decisive over a hundred of them.')}
    ${panel(`
      <div class="grid-2">
        ${field('frictions.commissionPerTrade', 'Commission per order, USD', f.commissionPerTrade, 'number',
          'Charged on the way in and again on the way out.')}
        ${field('frictions.commissionPctOfValue', 'Commission, % of notional', f.commissionPctOfValue, 'number',
          'How crypto venues and most non-US brokers charge.')}
      </div>
      <div class="grid-2" style="margin-top:16px">
        ${field('frictions.slippageAtrFraction', 'Slippage, × average daily range each way', f.slippageAtrFraction, 'number',
          'You buy at the ask and sell at the bid. Spreads scale with volatility rather than price, so this is denominated in the instrument\'s own daily range.')}
        ${field('frictions.shortTermTaxPct', 'Short-term tax rate, %', f.shortTermTaxPct, 'number',
          'Charged on gains realised inside a year and withheld at the sale, so the account does not compound money owed in tax.')}
      </div>
      <div class="grid-2" style="margin-top:16px">
        ${field('frictions.longTermTaxPct', 'Long-term tax rate, %', f.longTermTaxPct, 'number',
          'Applies once a parcel has been held past the threshold. The gap between the two rates is the main cost of trading frequently.')}
        ${field('frictions.longTermHoldingDays', 'Long-term threshold, days', f.longTermHoldingDays, 'number')}
      </div>
      <div class="row wrap" style="gap:10px;margin-top:18px">
        ${toggle('frictions.enforceMarketHours', 'Equity orders only during the session', f.enforceMarketHours)}
        ${toggle('frictions.enforcePDT', 'Enforce the pattern day trader rule', f.enforcePDT)}
      </div>
      <div class="faint" style="font-size:11.5px;margin-top:10px">
        The day-trader rule freezes a US margin account under $25,000 after three day trades in five business
        days. Crypto is exempt from both rules.
      </div>`)}`;
}

function learningPanel(s) {
  const l = s.learning ?? { applied: 0, proposed: 0, watching: 0, analysesRun: 0, calibrationLines: [], headline: '' };
  return `
    ${head('Calibration', 'What this account has changed in the engine, and what is waiting for a decision.')}
    ${panel(`
      <div class="metric-grid" style="grid-template-columns:repeat(4,1fr)">
        <div class="metric"><div class="metric-label">Applied</div><div class="metric-value">${l.applied}</div></div>
        <div class="metric"><div class="metric-label">Waiting on you</div>
          <div class="metric-value ${l.proposed ? 'warn-text' : ''}">${l.proposed}</div></div>
        <div class="metric"><div class="metric-label">Still watching</div><div class="metric-value">${l.watching}</div></div>
        <div class="metric"><div class="metric-label">Analyses run</div><div class="metric-value">${l.analysesRun}</div></div>
      </div>
      <p class="prose" style="margin-top:14px">${esc(l.headline)}</p>
      ${l.calibrationLines.length ? `<div class="note accent" style="margin-top:12px"><span class="note-icon">›</span>
        <span>The engine is currently running with: ${esc(l.calibrationLines.join('; '))}.</span></div>` : ''}
      <div class="row wrap" style="gap:8px;margin-top:16px">
        <button class="btn sm" data-goto="learning">Open the Calibration tab</button>
        <button class="btn danger sm" id="forgetBtn">Forget what it has learned</button>
      </div>
      <span class="faint" style="font-size:11.5px;display:block;margin-top:8px">Forgetting rolls every applied
      adjustment back to the textbook settings and clears the queue. The record of what was recommended is
      kept, so the same findings can be re-derived from the evidence.</span>`)}`;
}

function dangerPanel(s) {
  return `
    ${head('Reset', 'Each of these destroys part of the record.')}
    ${panel(`<div class="row wrap" style="gap:10px">
      <button class="btn danger sm" id="resetProfileBtn">Reset this account</button>
      <button class="btn danger sm" id="deleteProfileBtn" ${s.profiles.length < 2 ? 'disabled' : ''}>Delete this profile</button>
      <span class="faint" style="font-size:11.5px">Resetting restores the opening balance and erases the
      positions and history. Deleting removes the account entirely, including everything it has taught the engine.</span>
    </div>`)}

    ${head('Start completely over', 'Every account, every trade and every applied adjustment.')}
    ${panel(`
      <p class="prose" style="font-size:12.5px">
        This restores a first launch: the accounts, journals and calibration are removed, and the guided
        setup opens on its first question. Nothing is kept, and there is no copy anywhere — the ledgers
        exist only on this machine.
      </p>
      <p class="prose" style="font-size:12.5px">
        A saved API key is the exception. It is left in place unless you choose otherwise below.
      </p>
      <div class="row wrap" style="gap:10px;margin-top:14px">
        <button class="btn danger sm" id="factoryResetBtn">Erase everything and start again</button>
      </div>`)}`;
}

/* ------------------------------------------------------------------ render */

/**
 * @param {HTMLElement} host
 * @param {{ mode?: 'page'|'sheet' }} opts
 */
let analystLoaded = false;

export function renderSettings(host, { mode = 'page' } = {}) {
  sync();
  // Fetched on first sight rather than on every settings open: it reads the
  // Keychain and the last run's telemetry, neither of which is free.
  if (state.section === 'analyst' && !analystLoaded) {
    analystLoaded = true;
    loadAnalystPanel().then(() => renderSettings(host, { mode }));
  }
  const s = store.state;
  const p = state.draft;
  if (!p) return;

  const q = state.query.trim().toLowerCase();
  const matching = q
    ? SECTIONS.filter((sec) => (sec.label + ' ' + sec.keywords).toLowerCase().includes(q))
    : SECTIONS;
  const visible = matching.length ? matching : SECTIONS;
  const active = visible.find((sec) => sec.id === state.section) ?? visible[0];

  host.innerHTML = `
    <div class="settings ${mode === 'sheet' ? 'is-sheet' : ''}">
      <aside class="settings-nav">
        <div class="settings-search">
          <input type="search" id="settingsSearch" placeholder="Search settings…" value="${esc(state.query)}"
                 autocomplete="off" spellcheck="false">
        </div>
        ${visible.map((sec) => `
          <button class="settings-tab ${sec.id === active.id ? 'is-on' : ''}" data-section="${sec.id}">
            ${esc(sec.label)}
            ${sec.id === 'learning' && s.learning?.proposed ? `<span class="settings-badge">${s.learning.proposed}</span>` : ''}
          </button>`).join('')}
        ${q && !matching.length ? '<div class="faint" style="padding:10px 12px;font-size:11.5px">Nothing matches that.</div>' : ''}
      </aside>

      <div class="settings-body">
        <div class="settings-bar">
          <div>
            <div class="settings-title">${esc(active.label)}</div>
            <div class="faint" style="font-size:11.5px">${esc(s.profile.name)} · every limit here is enforced</div>
          </div>
          <span class="spacer"></span>
          ${state.dirty ? '<span class="chip warn">Unsaved changes</span>' : ''}
          <button class="btn sm" id="revertBtn" ${state.dirty ? '' : 'disabled'}>Revert</button>
          <button class="btn primary sm" id="saveBtn" ${state.dirty ? '' : 'disabled'}>Save</button>
        </div>
        <div class="settings-content">${active.render(p, s)}</div>
      </div>
    </div>`;

  wire(host, mode);
}

/* ----------------------------------------------------------------- wiring */

function wire(host, mode) {
  const repaint = () => renderSettings(host, { mode });

  host.querySelectorAll('[data-field]').forEach((el) => {
    el.addEventListener('change', () => {
      const raw = el.type === 'number' ? Number(el.value) : el.value;
      if (el.type === 'number' && !isFinite(raw)) return;
      set(el.dataset.field, raw);
      repaint();
    });
  });

  // Money is typed in dollars and stored in dollars. Nothing is converted on the
  // way in, so what comes back out on the next paint is exactly what was typed.
  host.querySelectorAll('[data-money]').forEach((el) => {
    // The echo updates on every keystroke; the draft only on commit, so a
    // half-typed "1" does not briefly resize a live position.
    el.addEventListener('input', () => {
      const echo = host.querySelector(`[data-echo="${el.dataset.money}"]`);
      if (!echo) return;
      const typed = Number(el.value);
      echo.textContent = isFinite(typed) ? `≈ ${homeAmount(typed, 0)}` : '';
    });
    el.addEventListener('change', () => {
      const typed = Number(el.value);
      if (!isFinite(typed)) return;
      set(el.dataset.money, typed);
      repaint();
    });
  });

  host.querySelectorAll('[data-slider]').forEach((el) => {
    el.addEventListener('input', () => {
      set(el.dataset.slider, Number(el.value));
      repaint();
      // Repainting steals focus mid-drag, so hand it back to the same control.
      host.querySelector(`[data-slider="${el.dataset.slider}"]`)?.focus();
    });
  });

  wireAnalystInputs(host, repaint);

  const search = host.querySelector('#settingsSearch');
  if (search) {
    search.addEventListener('input', () => {
      state.query = search.value;
      repaint();
      const again = host.querySelector('#settingsSearch');
      again?.focus();
      again?.setSelectionRange(again.value.length, again.value.length);
    });
  }

  if (host.dataset.settingsBound) return;
  host.dataset.settingsBound = '1';

  host.addEventListener('click', async (e) => {
    const nav = e.target.closest('[data-section]');
    if (nav) {
      state.section = nav.dataset.section;
      if (state.section === 'analyst' && !analystLoaded) {
        analystLoaded = true;
        await loadAnalystPanel();
      }
      return repaint();
    }

    if (state.section === 'analyst' && await handleAnalystClick(e, repaint)) return;

    const setBtn = e.target.closest('[data-set]');
    if (setBtn) {
      set(setBtn.dataset.set, setBtn.dataset.value);
      // A mode owns the plain-language switch. Leaving the switch behind would let
      // the mode's own description disagree with the screen it produces.
      if (setBtn.dataset.set === 'readingMode') {
        const m = (store.state?.readingModes ?? []).find((x) => x.id === setBtn.dataset.value);
        if (m) set('plainLanguage', m.explains);
      }
      return repaint();
    }

    /* Markets toggle rather than select: they are not alternatives. Refusing the
     * last one keeps the profile in a state the engine can act on — an account
     * with no exchange has no universe, and the failure is a blank screen with no
     * explanation on it. */
    const marketBtn = e.target.closest('[data-market]');
    if (marketBtn) {
      const key = marketBtn.dataset.market;
      const current = marketsOf(draft());
      const next = current.includes(key) ? current.filter((m) => m !== key) : [...current, key];
      if (!next.length) {
        toast('An account has to trade somewhere. Turn another market on before turning this one off.', 'err');
        return;
      }
      set('markets', MARKETS.map(([k]) => k).filter((k) => next.includes(k)));
      return repaint();
    }

    const toggleBtn = e.target.closest('[data-toggle]');
    if (toggleBtn) { set(toggleBtn.dataset.toggle, !get(toggleBtn.dataset.toggle)); return repaint(); }

    const activate = e.target.closest('[data-activate]');
    if (activate) return switchTo(activate.dataset.activate, repaint);

    if (e.target.closest('#saveBtn')) return save(repaint);
    if (e.target.closest('#revertBtn')) { resetDraft(); return repaint(); }
    if (e.target.closest('#newProfileBtn')) return createProfile(repaint);
    if (e.target.closest('#resetProfileBtn')) return resetProfile(repaint);
    if (e.target.closest('#deleteProfileBtn')) return removeProfile(repaint);
    if (e.target.closest('#forgetBtn')) return forget(repaint);
    if (e.target.closest('#factoryResetBtn')) return factoryReset();
  });
}

/* ---------------------------------------------------------------- actions */

async function switchTo(id, repaint) {
  if (state.dirty) {
    const ok = await modal({
      title: 'Switch account without saving?',
      confirmText: 'Discard and switch', tone: 'danger',
      body: '<p>The edits on this profile have not been saved. Switching now discards them.</p>',
    });
    if (!ok) return;
  }
  try {
    await api.activateProfile(id);
    resetDraft();
    store.markets = null; store.analysis = null; store.review = null; store.memory = null;
    await refreshView();
    repaint();
    toast('Switched account.');
  } catch (err) { toast(err.message, 'err'); }
}

async function save(repaint) {
  try {
    await api.saveProfile(state.draft);
    state.dirty = false;
    store.analysis = null; store.review = null; store.markets = null;
    await refreshView();
    repaint();
    toast('Saved. Position sizing, the eligible universe and every level on the board update immediately.');
  } catch (err) { toast(err.message, 'err'); }
}

async function createProfile(repaint) {
  const res = await modal({
    title: 'New account',
    confirmText: 'Create from preset',
    body: `<p>The guided setup asks a few questions about your circumstances and derives every setting
      from the answers.
      <button class="btn sm" data-act="wizard" style="margin-top:10px">Use the guided setup instead</button></p>
      <p style="margin-top:14px">Or start from a preset and edit it. Every field is editable afterwards, and
      the new account begins with an empty ledger.</p>
      <div class="pill-row" style="margin-top:12px" id="presetRow">
        ${PRESETS.map(([k, l], i) => `<button class="pill ${i === 0 ? 'is-on' : ''}" data-preset="${k}">${esc(l)}</button>`).join('')}
      </div>`,
  });
  if (!res) return;

  // The dialog's third exit: the questions, rather than a preset.
  if (res.action === 'wizard') {
    closeSheet();
    restartSetup();
    return go('start');
  }

  const chosen = document.querySelector('[data-preset].is-on')?.dataset.preset;
  try {
    await api.newProfile(chosen || 'learner');
    resetDraft();
    store.markets = null; store.analysis = null; store.review = null; store.memory = null;
    await refreshView();
    repaint();
    toast('Account created.');
  } catch (err) { toast(err.message, 'err'); }
}

async function resetProfile(repaint) {
  const ok = await modal({
    title: 'Reset this account?', confirmText: 'Reset everything', tone: 'danger',
    body: `<p>Cash goes back to ${money(state.draft.startingCapital, 0)} and every position, trade and journal
      entry on <strong>${esc(state.draft.name)}</strong> is erased. Other accounts are untouched.
      This cannot be undone.</p>`,
  });
  if (!ok) return;
  await api.reset();
  store.review = null;
  await refreshView();
  repaint();
  toast('Account reset.');
}

async function removeProfile(repaint) {
  const ok = await modal({
    title: `Delete ${state.draft.name}?`, confirmText: 'Delete the profile', tone: 'danger',
    body: '<p>The profile, its entire ledger and everything it taught the engine are removed. This cannot be undone.</p>',
  });
  if (!ok) return;
  try {
    await api.deleteProfile(state.draft.id);
    resetDraft();
    store.markets = null; store.analysis = null; store.review = null; store.memory = null;
    await refreshView();
    repaint();
    toast('Profile deleted.');
  } catch (err) { toast(err.message, 'err'); }
}

async function forget(repaint) {
  const ok = await modal({
    title: 'Forget what the engine has learned?', confirmText: 'Roll it all back', tone: 'danger',
    body: `<p>Every applied adjustment goes back to its textbook value and the proposal queue is cleared.</p>
      <p style="margin-top:10px">The record of what was recommended and what happened to it is kept, so the
      next review can re-derive whatever the evidence still supports.</p>`,
  });
  if (!ok) return;
  try {
    await api.resetMemory(true);
    store.memory = null;
    await refreshView();
    repaint();
    toast('Calibration rolled back to the textbook settings.');
  } catch (err) { toast(err.message, 'err'); }
}

/**
 * The full reset.
 *
 * Two things make this different from every other destructive action here. It is
 * the only one that is not scoped to a single account, so there is nothing left
 * afterwards to argue with about what was lost; and it is irreversible in a way the
 * others are not, because the ledgers exist only on this machine. So the dialog
 * counts what is about to go rather than asking whether you are sure about an
 * unspecified amount of work, and it wants a word typed rather than a second click
 * — a click is what you do when you have stopped reading.
 */
async function factoryReset() {
  let preview;
  try {
    preview = await api.getResetPreview();
  } catch (err) {
    return toast(err.message, 'err');
  }

  const age = preview.oldestAccountDays > 0
    ? `The oldest account here is ${preview.oldestAccountDays} day${preview.oldestAccountDays === 1 ? '' : 's'} old. `
    : '';

  const res = await modal({
    title: 'Erase everything?',
    confirmText: 'Erase it all',
    tone: 'danger',
    body: `<p>${age}This removes:</p>
      <ul class="next-list" style="margin:10px 0 0">
        ${preview.items.map((i) => `<li>${esc(i)}</li>`).join('')}
      </ul>
      <p style="margin-top:14px">The app reopens on the first question of the guided setup.
      <strong>There is no copy of any of this anywhere</strong>; it exists only on this machine.</p>
      ${preview.hasKeychainKey
        ? `<div class="row" style="gap:8px;margin-top:14px">
             <button class="pill" id="alsoRemoveKey" type="button"><span class="pill-dot"></span>Also delete the saved API key</button>
           </div>
           <span class="faint" style="font-size:11.5px;display:block;margin-top:6px">
             Left off, the key stays and the analyst still works afterwards.</span>`
        : `<p class="faint" style="font-size:11.5px;margin-top:12px">No API key is saved here, so there is
             none to delete. ${preview.keySource === 'environment'
               ? 'The key in use comes from outside Paper and is not affected.' : ''}</p>`}
      <div class="field" style="margin-top:16px">
        <label for="resetConfirm">Type <strong>reset</strong> to confirm</label>
        <input id="resetConfirm" type="text" autocomplete="off" spellcheck="false" placeholder="reset">
      </div>`,
  });
  if (!res) return;

  const typed = document.querySelector('#resetConfirm')?.value ?? res.resetConfirm ?? '';
  const removeKey = !!document.querySelector('#alsoRemoveKey.is-on');

  if (String(typed).trim().toLowerCase() !== 'reset') {
    return toast('Not erased. The confirmation word did not match.', 'err', 6000);
  }

  try {
    const out = await api.resetEverything(removeKey);
    toast(out.note, 'ok', 6000);
    // A reload rather than a re-render: every cached view, draft and module-level
    // bit of state in this page belongs to accounts that no longer exist.
    setTimeout(() => { location.hash = '#start'; location.reload(); }, 600);
  } catch (err) {
    toast(err.message, 'err', 8000);
  }
}

/** The key toggle inside the reset dialog, which the modal does not know about. */
document.addEventListener('click', (e) => {
  const pill = e.target.closest('#alsoRemoveKey');
  if (pill) pill.classList.toggle('is-on');
});

/** Closes the settings sheet if it is the surface we are on. */
function closeSheet() {
  const sheet = document.getElementById('settingsSheet');
  const scrim = document.getElementById('settingsScrim');
  if (sheet) sheet.hidden = true;
  if (scrim) scrim.hidden = true;
}

/* The preset picker inside the modal needs its own handler, since the modal
 * resolves on a button that is not one of the pills. */
document.addEventListener('click', (e) => {
  const pill = e.target.closest('[data-preset]');
  if (!pill) return;
  pill.parentElement.querySelectorAll('[data-preset]').forEach((x) => x.classList.remove('is-on'));
  pill.classList.add('is-on');
});
