/**
 * start.js — the guided setup.
 *
 * The profile screen asks for risk per trade as a percentage of equity and a
 * drawdown tolerance. Those are the right controls and they are unanswerable by
 * someone who has not traded; asked cold they get guessed, and a guessed risk
 * setting is worse than a default because it carries the authority of having been
 * chosen. So this asks about circumstances instead — how much, what happens if it
 * halves, what the job situation is, when the money might be needed — and derives
 * every trading parameter from the answers.
 *
 * Then it stops and shows the working. The reality check is the point of the whole
 * screen: it names every combination of answers that does not hold together, says
 * what each one means *for this kind of trading* specifically, and puts the
 * recommendation next to what the answers literally asked for. Everything is
 * overridable, because a warning you cannot overrule is a lecture, and this is
 * meant to be a first day at a desk rather than a compliance form.
 *
 * The assessment is computed server-side by the same suitability arithmetic the
 * profile screen runs, so the two can never disagree about what a situation
 * supports.
 */

import { store, toast, go, refreshView } from '../app.js';
import * as api from '../api.js';
import { esc, plainPct, homeAmount, currency as readingCurrency, setCurrency } from '../format.js';

/* --------------------------------------------------------------- questions */

/* What the small second figure is read in. Not what the account is kept in — the
   account is always dollars, because that is what these instruments trade in. */
const CURRENCIES = [
  ['USD', '$ US dollar'], ['EUR', '€ Euro'], ['GBP', '£ Pound'],
  ['SEK', 'kr Swedish krona'], ['NOK', 'kr Norwegian krone'], ['DKK', 'kr Danish krone'],
  ['CHF', 'CHF Swiss franc'], ['CAD', 'C$ Canadian dollar'],
  ['AUD', 'A$ Australian dollar'], ['JPY', '¥ Japanese yen'],
];

const STEPS = [
  {
    id: 'purpose',
    question: 'What brings you here?',
    hint: 'Sets how the rest of your answers are read.',
    kind: 'choice', field: 'purpose',
    options: [
      ['learn', 'I want to understand how this works', 'Balanced settings, weighted toward explanation over performance.'],
      ['grow', 'I want to grow money over time', 'Fewer, larger, longer trades. Most growth comes from deposits.'],
      ['active', 'I want to try active trading', 'More trades, tighter stops, higher costs.'],
      ['test', 'I have a method and want to test it', 'Your rules, measured including what they cost.'],
    ],
  },
  {
    id: 'explaining',
    question: 'How much should be explained?',
    hint: 'Changes what the interface shows. It changes no trading setting.',
    kind: 'choice', field: 'explaining',
    options: [
      ['full', 'Explain the terms where they are used', 'Headings carry a plain line underneath. Every term is underlined.'],
      ['onHover', 'Only when I ask', 'Nothing is added to the screen. Definitions stay on hover.'],
      ['none', 'Not at all', 'No underlines and no added lines.'],
    ],
  },
  {
    id: 'currency',
    question: 'Which currency do you think in?',
    hint: 'Balances, prices and input fields stay in dollars, because these instruments trade in dollars. This adds a second figure underneath in your currency, detected from your Mac.',
    kind: 'pills', field: 'currency', options: CURRENCIES,
  },
  {
    id: 'amount',
    question: 'How much would you put in?',
    hint: 'Simulated money. Use a figure you would be willing to risk, because every limit below is derived from it.',
    kind: 'money', field: 'amount',
    suggestions: [1000, 5000, 10000, 50000, 100000],
  },
  {
    id: 'income',
    question: 'What is your job situation?',
    hint: 'The largest single input into how much you can risk per trade.',
    kind: 'choice', field: 'income',
    options: [
      ['none', 'No income right now', 'Nothing replaces what this account loses.'],
      ['irregular', 'Irregular or freelance', 'Income arrives without a schedule you can plan against.'],
      ['salaried', 'A steady salary', 'Losses get refilled over time.'],
      ['abundant', 'Income well above what I spend', 'This money is spare.'],
    ],
  },
  {
    id: 'expenses',
    question: 'Roughly what do you spend in a month?',
    hint: 'Used to express losses in months of expenses — a $2,000 loss reads as most of a month. Nothing is taken from the account.',
    kind: 'money', field: 'monthlyExpenses',
    suggestions: [1500, 2500, 4000, 6000],
  },
  {
    id: 'savings',
    question: 'How much cash do you have set aside elsewhere?',
    hint: 'Cash you could reach tomorrow, outside this account. Three to six months of expenses is the conventional floor before risking any of it.',
    kind: 'money', field: 'savingsOutside',
    suggestions: [0, 5000, 15000, 30000],
  },
  {
    id: 'add',
    question: 'Could you add to it each month?',
    hint: 'Regular deposits change what a losing run does to the balance. Enter 0 if there are none.',
    kind: 'money', field: 'monthlyAdd',
    suggestions: [0, 100, 500, 1000],
  },
  {
    id: 'need',
    question: 'When might you need this money for something else?',
    hint: 'Markets can stay down for a year while behaving normally. Money claimed inside that window may have to be sold at a loss.',
    kind: 'choice', field: 'needWindow',
    options: [
      ['anyTime', 'I might need it at any time', 'Rent, bills or an emergency could claim it.'],
      ['withinYear', 'Possibly within a year', 'There is a plan it may be needed for.'],
      ['oneToFive', 'Not for a few years', 'It can stay invested through a downturn.'],
      ['fivePlus', 'Not for five years or more', 'Nothing is expected to claim it.'],
    ],
  },
  {
    id: 'drop',
    question: 'It falls 30%. What do you do?',
    hint: 'Sets your risk per trade. Answer for how you have reacted before, not how you intend to react.',
    kind: 'choice', field: 'dropReaction',
    options: [
      ['sellAll', "I'd get out — I couldn't watch that", 'Sets the lowest risk per trade.'],
      ['uncomfortable', "I'd be very uncomfortable but probably hold", 'Sets a moderate risk per trade.'],
      ['holdOn', "I'd hold. That's part of it", 'Raises risk per trade, still capped by your circumstances.'],
      ['buyMore', "I'd be looking to buy more", 'Highest risk per trade, and only with cash set aside for it.'],
    ],
  },
  {
    id: 'attention',
    question: 'How often could you look at this?',
    hint: 'Sets how fast a trade can be run. It does not change how long a trade you can afford, which the previous answer decides.',
    kind: 'choice', field: 'attention',
    options: [
      ['rarely', 'A few minutes a week', 'Longer holds, wider stops, fewer decisions.'],
      ['daily', 'Once or twice a day', 'Swing and position trades.'],
      ['allDay', 'I can watch it through the day', 'Adds intraday sessions on five-minute bars.'],
    ],
  },
  {
    id: 'experience',
    question: 'Have you traded before?',
    hint: 'Sets how much is explained inline, and adjusts the starting limits. It does not change what your circumstances can absorb.',
    kind: 'choice', field: 'experience',
    options: [
      ['none', 'None at all', 'Terms are explained where they appear.'],
      ['some', "I've bought a few things", 'Fewer inline explanations.'],
      ['experienced', "I've traded actively before", 'Plain-language mode off. Definitions stay available on hover.'],
    ],
  },
  {
    id: 'appetite',
    question: 'What would you like to trade?',
    hint: 'Instruments outside your choice stay visible on the board, but cannot be bought.',
    kind: 'choice', field: 'appetite',
    options: [
      ['both', 'Shares and crypto', 'The full board — US and Stockholm listings plus crypto.'],
      ['stocks-only', 'Shares only', 'Twenty-two companies, no crypto.'],
      ['crypto-only', 'Crypto only', 'Eight pairs, trading continuously, with larger swings.'],
      ['index-first', 'Mostly index funds', 'Makes the two benchmark indices tradeable.'],
    ],
  },
  {
    id: 'key',
    question: 'Do you want the written analysis too?',
    hint: 'Optional. Adds written briefs on candidates, post-mortems on closed trades and periodic reports on your record. Everything else works without it.',
    kind: 'apikey', field: 'apiKey',
  },
];

/* ------------------------------------------------------------------ state */

let answers = {
  currency: 'USD', purpose: 'learn', explaining: 'full', amount: 10000, income: 'salaried',
  monthlyExpenses: 2500, savingsOutside: 0, monthlyAdd: 0,
  needWindow: 'oneToFive', dropReaction: 'uncomfortable', attention: 'daily',
  experience: 'none', appetite: 'both', name: '',
};

let step = 0;              // index into STEPS, or STEPS.length for the reality check
let assessment = null;
let assessing = false;
/** Whether the currency question has been seeded from the machine's own setting. */
let currencySeeded = false;
/** Local mirror of the key panel, so the step can show what is already there. */
let keyState = { checked: false, hasKey: false, sourceLabel: '', fingerprint: null, busy: false, error: '' };
/** Fields the user has deliberately overruled on the reality-check screen. */
const overrides = {};

export function restartSetup() {
  step = 0;
  assessment = null;
  currencySeeded = false;
  keyState = { checked: false, hasKey: false, sourceLabel: '', fingerprint: null, busy: false, error: '' };
  for (const k of Object.keys(overrides)) delete overrides[k];
}

/* Amounts are dollars here as everywhere else, so the suggestion pills are too.
   The reading currency shows up under the field rather than inside these, which
   keeps the pills short enough to sit on one row. */
const showMoney = (n) =>
  '$' + Number(n || 0).toLocaleString('en-US', { maximumFractionDigits: 0 });

/** The same amount in whatever currency the previous question picked. */
const echoMoney = (n) => {
  const text = homeAmount(Number(n) || 0, 0);
  return text ? `≈ ${text}` : '';
};

/* ----------------------------------------------------------------- render */

export async function renderStart(host) {
  // The machine already knows what currency the person reads in, so the question
  // arrives answered rather than defaulting to dollars and waiting to be corrected.
  // Seeded once: after that it is whatever they last picked.
  if (!currencySeeded) {
    const detected = store.state?.currency;
    if (detected && CURRENCIES.some(([code]) => code === detected)) answers.currency = detected;
    setCurrency(answers.currency, store.state?.fx);
    currencySeeded = true;
  }
  // The key step needs to know whether one is already set — from the environment
  // as well as from the Keychain — before it offers to take a new one.
  if (STEPS[step]?.kind === 'apikey' && !keyState.checked) await loadKeyState();
  if (step >= STEPS.length && !assessment && !assessing) await assess(host);
  paint(host);
}

async function loadKeyState() {
  try {
    const panel = await api.getAnalystPanel();
    const c = panel?.credentials ?? {};
    keyState = { ...keyState, checked: true, hasKey: !!c.hasKey, sourceLabel: c.sourceLabel ?? '', fingerprint: c.fingerprint ?? null };
  } catch {
    // A panel that will not load is not a reason to block the setup. The step
    // simply offers the field, and the gear can sort it out afterwards.
    keyState = { ...keyState, checked: true, hasKey: false };
  }
}

function paint(host) {
  host.innerHTML = step >= STEPS.length
    ? `<section class="view">${realityCheck()}</section>`
    : `<section class="view">${question(STEPS[step])}</section>`;
  wire(host);
}

function question(q) {
  const value = answers[q.field];
  return `
    <div class="wizard">
      <div class="wizard-rail">
        <div class="wizard-progress"><div style="width:${(step / STEPS.length) * 100}%"></div></div>
        <div class="wizard-step">Question ${step + 1} of ${STEPS.length}</div>
        <button class="wizard-skip" id="skipSetup">Skip setup</button>
      </div>

      <h1 class="wizard-question">${esc(q.question)}</h1>
      <p class="wizard-hint">${esc(q.hint)}</p>

      ${q.kind === 'choice' ? `
        <div class="wizard-choices">
          ${q.options.map(([k, label, note]) => `
            <button class="wizard-choice ${value === k ? 'is-on' : ''}" data-answer="${esc(k)}">
              <span class="wizard-choice-label">${esc(label)}</span>
              <span class="wizard-choice-note">${esc(note)}</span>
            </button>`).join('')}
        </div>` : ''}

      ${q.kind === 'pills' ? `
        <div class="pill-row" style="margin-top:22px">
          ${q.options.map(([k, label]) => `
            <button class="pill ${value === k ? 'is-on' : ''}" data-answer="${esc(k)}">${esc(label)}</button>`).join('')}
        </div>` : ''}

      ${q.kind === 'money' ? `
        <div class="wizard-money">
          <div class="wizard-amount">
            <span class="wizard-currency">$</span>
            <input type="number" id="amountInput" value="${Number(value) || 0}" step="any" autocomplete="off">
          </div>
          <div class="money-echo" id="amountEcho" style="margin-top:6px">${esc(echoMoney(value))}</div>
          <div class="pill-row" style="margin-top:14px">
            ${q.suggestions.map((n) => `<button class="pill ${Number(value) === n ? 'is-on' : ''}" data-amount="${n}">${esc(showMoney(n))}</button>`).join('')}
          </div>
        </div>` : ''}

      ${q.kind === 'apikey' ? keyStep() : ''}

      <div class="wizard-foot">
        <button class="btn" id="backBtn" ${step === 0 ? 'disabled' : ''}>Back</button>
        <button class="btn primary" id="nextBtn">${
          q.kind === 'apikey' ? (keyState.hasKey ? 'Continue' : 'Skip and continue')
          : step === STEPS.length - 1 ? 'Review the setup' : 'Next'}</button>
      </div>
    </div>`;
}

/* ------------------------------------------------------------ the API key */

/**
 * The one optional thing in the setup, asked rather than buried.
 *
 * Every other question here changes what the app does. This one changes only
 * whether a second, written layer sits on top of it — so it is the only step with
 * a real "no", and the copy leads with what still works rather than with what is
 * missing. An optional step that reads as a paywall gets skipped resentfully; one
 * that says plainly "here is the whole app either way, and here is the part a key
 * adds" gets a decision instead of an escape.
 *
 * The key is verified with one real request before it is stored, and it goes into
 * the login Keychain rather than into a file beside the ledgers. Nothing sends it
 * back to this screen — the field is write-only, and it is cleared the moment the
 * save returns.
 */
function keyStep() {
  const k = keyState;
  const found = k.checked && k.hasKey;
  return `
    <div class="key-step">
      ${found ? `
        <div class="note up" style="margin-top:6px"><span class="note-icon">✓</span><span>
          <strong>A key is already set.</strong> ${esc(k.sourceLabel)}${k.fingerprint ? ` · ${esc(k.fingerprint)}` : ''}.
          Written analysis is on.
        </span></div>` : `
        <div class="grid-2" style="gap:18px;margin-top:18px;align-items:start">
          <div>
            <div class="key-col-head">With a key</div>
            <ul class="key-list">
              <li>A written brief on each candidate: what the setup is, where the stop sits, and why this one
                over the others.</li>
              <li>A post-mortem on each closed trade: what the exit cost, and what holding would have returned.</li>
              <li>A periodic report naming the patterns in your own record.</li>
            </ul>
          </div>
          <div>
            <div class="key-col-head">Without one</div>
            <ul class="key-list">
              <li>Real prices, the full board, trading, brackets and sessions.</li>
              <li>Screening and ranking still run; they are arithmetic, not a model. You get the scores
                without the written explanation.</li>
              <li>Costs, tax lots, the pattern-day-trader rule, MAE/MFE review, the behavioural patterns.</li>
            </ul>
          </div>
        </div>

        <div class="field" style="max-width:420px;margin-top:20px">
          <label for="wizKeyInput">Anthropic API key</label>
          <input id="wizKeyInput" type="password" autocomplete="off" spellcheck="false"
                 placeholder="sk-ant-…" ${k.busy ? 'disabled' : ''}>
          <span class="faint" style="font-size:11.5px">
            From <strong>console.anthropic.com</strong>. Verified with one request before saving, then stored
            in your login Keychain — not in the data folder, the logs or any export.
          </span>
        </div>

        <div class="btn-row" style="margin-top:12px">
          <button class="btn primary sm" id="wizSaveKey" ${k.busy ? 'disabled' : ''}>
            ${k.busy ? 'Checking…' : 'Verify and save'}</button>
        </div>
        ${k.error ? `<div class="note down" style="margin-top:12px"><span class="note-icon">!</span><span>${esc(k.error)}</span></div>` : ''}

        <p class="faint" style="font-size:11.5px;margin-top:16px;line-height:1.6">
          A key can be added or removed later under the gear → Analyst. Usage is billed by Anthropic to your
          own account; each run has a spend cap and reports its cost.
        </p>`}
    </div>`;
}

/* ------------------------------------------------------- the reality check */

const SEVERITY_TONE = { blocking: 'down', serious: 'warn', note: 'accent', good: 'up' };
const SEVERITY_LABEL = {
  blocking: 'Read first', serious: 'Important', note: 'Rule applied', good: 'Consistent',
};

function realityCheck() {
  if (assessing || !assessment) {
    return `<div class="wizard"><div class="row" style="gap:12px;justify-content:center;padding:60px 0">
      <div class="spinner"></div><span class="dim">Calculating your limits…</span></div></div>`;
  }

  const a = assessment;
  const p = a.profile;
  const serious = a.flags.filter((f) => f.severity === 'blocking' || f.severity === 'serious');

  return `
    <div class="wizard is-wide">
      <div class="wizard-rail">
        <div class="wizard-progress"><div style="width:100%"></div></div>
        <div class="wizard-step">Your setup</div>
        <button class="wizard-skip" id="editAnswers">Change an answer</button>
      </div>

      <h1 class="wizard-question">${serious.length ? 'Before you start' : 'Your setup'}</h1>
      <p class="prose" style="font-size:14.5px;margin-top:10px">${esc(a.summary)}</p>

      <div class="panel panel-pad" style="margin-top:22px">
        <div class="metric-grid" style="grid-template-columns:repeat(4,1fr)">
          <div class="metric"><div class="metric-label">Risk capacity</div>
            <div class="metric-value ${a.capacity >= 60 ? 'up' : a.capacity >= 35 ? 'warn-text' : 'down'}">${a.capacity.toFixed(0)}/100</div></div>
          <div class="metric"><div class="metric-label">Risk per trade</div>
            <div class="metric-value">${a.effectiveRiskPct.toFixed(2)}%</div></div>
          <div class="metric"><div class="metric-label">Horizon</div>
            <div class="metric-value" style="font-size:12.5px">${esc(p.horizon)}</div></div>
          <div class="metric"><div class="metric-label">Objective</div>
            <div class="metric-value" style="font-size:12.5px">${esc(p.goal)}</div></div>
        </div>
      </div>

      ${a.flags.map(flagCard).join('')}
      ${a.recommendations.length ? recommendations(a) : ''}

      <div class="panel panel-pad" style="margin-top:20px">
        <div class="field" style="max-width:340px">
          <label for="acctName">Name this account</label>
          <input id="acctName" type="text" value="${esc(p.name)}" autocomplete="off">
        </div>
      </div>

      <div class="wizard-foot" style="margin-top:24px">
        <button class="btn" id="editAnswers2">Back to the questions</button>
        <button class="btn primary" id="createBtn">Create this account</button>
      </div>

      <p class="faint" style="font-size:11.5px;margin-top:18px;line-height:1.6">
        Every setting is editable afterwards, from the gear in the top bar or ⌘,. This is a simulation, not
        investment advice, and the money in it is not real.
      </p>
    </div>`;
}

function flagCard(flag) {
  const tone = SEVERITY_TONE[flag.severity] ?? 'accent';
  return `<div class="flag-card ${tone}">
    <div class="flag-head">
      <span class="chip ${tone}">${esc(SEVERITY_LABEL[flag.severity] ?? '')}</span>
      <span class="flag-title">${esc(flag.title)}</span>
    </div>
    <p class="prose">${esc(flag.body)}</p>
    <div class="flag-consequence"><span class="note-icon">›</span><span>${esc(flag.consequence)}</span></div>
  </div>`;
}

function recommendations(a) {
  return `
    <div class="section-head" style="margin-top:26px">
      <h2>Where the recommendation differs from your answer</h2>
      <span class="hint">Each is a suggestion. Keep your own answer if you prefer; the reason is shown again where it applies.</span>
    </div>
    ${a.recommendations.map((r) => `
      <div class="rec-card">
        <div class="rec-label">${esc(r.label)}</div>
        <div class="rec-values">
          <button class="rec-option ${overrides[r.id] ? 'is-on' : ''}" data-override="${esc(r.id)}">
            <span class="rec-option-label">What you said</span>
            <span class="rec-option-value">${esc(r.yours)}</span>
          </button>
          <button class="rec-option ${overrides[r.id] ? '' : 'is-on'}" data-accept="${esc(r.id)}">
            <span class="rec-option-label">Recommended</span>
            <span class="rec-option-value">${esc(r.recommended)}</span>
          </button>
        </div>
        <p class="prose" style="font-size:12.5px">${esc(r.why)}</p>
      </div>`).join('')}`;
}

/* ----------------------------------------------------------------- wiring */

async function assess(host) {
  assessing = true;
  paint(host);
  try {
    assessment = await api.assessOnboarding(answers);
  } catch (err) {
    toast(err.message, 'err');
    step = STEPS.length - 1;
  } finally {
    assessing = false;
  }
}

function wire(host) {
  const q = STEPS[step];

  host.querySelectorAll('[data-answer]').forEach((el) => {
    el.addEventListener('click', () => {
      answers[q.field] = el.dataset.answer;
      // The reading currency drives every "≈" from here on, including the echo
      // under the amount fields two questions later.
      if (q.field === 'currency') setCurrency(answers.currency, store.state?.fx);
      // A single-choice answer is also the click that moves on. Waiting for a
      // second click on Next is friction with no purpose.
      if (step < STEPS.length - 1) step += 1; else return next(host);
      assessment = null;
      // Through renderStart rather than paint, because the step being landed on
      // may need to fetch something before it can draw itself honestly.
      renderStart(host);
    });
  });

  host.querySelectorAll('[data-amount]').forEach((el) => {
    el.addEventListener('click', () => {
      answers[q.field] = Number(el.dataset.amount);
      assessment = null;
      paint(host);
    });
  });

  const amount = host.querySelector('#amountInput');
  if (amount) {
    amount.focus();
    amount.addEventListener('input', () => {
      answers[q.field] = Number(amount.value) || 0;
      assessment = null;
      const echo = host.querySelector('#amountEcho');
      if (echo) echo.textContent = echoMoney(answers[q.field]);
    });
    amount.addEventListener('keydown', (e) => { if (e.key === 'Enter') next(host); });
  }

  const name = host.querySelector('#acctName');
  if (name) name.addEventListener('input', () => { answers.name = name.value; });

  host.querySelector('#wizSaveKey')?.addEventListener('click', async () => {
    const input = host.querySelector('#wizKeyInput');
    const key = input?.value?.trim();
    if (!key) { keyState.error = 'Paste a key first, or continue without one.'; return paint(host); }
    keyState.busy = true; keyState.error = ''; paint(host);
    try {
      const c = await api.saveAnalystKey(key);
      // Never leave a live key sitting in a DOM node for the rest of the session.
      const field = host.querySelector('#wizKeyInput');
      if (field) field.value = '';
      keyState = { checked: true, hasKey: !!c?.hasKey, sourceLabel: c?.sourceLabel ?? '', fingerprint: c?.fingerprint ?? null, busy: false, error: '' };
      toast('Key verified and saved to your Keychain. Written analysis is on.');
    } catch (err) {
      keyState.busy = false;
      keyState.error = err.message;
    }
    paint(host);
  });

  host.querySelector('#nextBtn')?.addEventListener('click', () => next(host));
  host.querySelector('#backBtn')?.addEventListener('click', () => {
    if (step > 0) step -= 1;
    assessment = null;
    renderStart(host);
  });
  host.querySelector('#skipSetup')?.addEventListener('click', () => skip());
  host.querySelector('#editAnswers')?.addEventListener('click', () => back(host));
  host.querySelector('#editAnswers2')?.addEventListener('click', () => back(host));
  host.querySelector('#createBtn')?.addEventListener('click', () => create());

  host.querySelectorAll('[data-override]').forEach((el) => {
    el.addEventListener('click', () => { overrides[el.dataset.override] = true; paint(host); });
  });
  host.querySelectorAll('[data-accept]').forEach((el) => {
    el.addEventListener('click', () => { delete overrides[el.dataset.accept]; paint(host); });
  });
}

function back(host) {
  step = STEPS.length - 1;
  assessment = null;
  paint(host);
}

async function next(host) {
  if (step < STEPS.length - 1) { step += 1; assessment = null; return renderStart(host); }
  step = STEPS.length;
  assessment = null;
  await renderStart(host);
}

async function skip() {
  try {
    await api.setSettings({ hasOnboarded: true });
    await refreshView();
    go('desk');
    toast('Setup skipped. It is available again under the gear.');
  } catch (err) { toast(err.message, 'err'); }
}

/**
 * Applies whatever the user overruled, then creates the account.
 *
 * The overrides are applied to the recommended profile rather than re-derived,
 * because the assessment already computed both sides — re-running the derivation
 * with different inputs would produce a third answer that was on neither card.
 */
async function create() {
  if (!assessment) return;
  const p = structuredClone(assessment.profile);
  const name = document.querySelector('#acctName')?.value?.trim();
  if (name) p.name = name;

  if (overrides.risk) p.riskPctPerTrade = assessment.profile.riskPctPerTrade;
  if (overrides.horizon) {
    const literal = answers.attention === 'allDay' ? 'swing' : answers.attention === 'daily' ? 'position' : 'long-term';
    p.horizon = literal;
  }
  if (overrides.drawdown) p.drawdownTolerancePct = 45;
  if (overrides.positions) p.maxOpenPositions = assessment.profile.maxOpenPositions;
  else if (assessment.recommendations.some((r) => r.id === 'positions')) p.maxOpenPositions = 4;

  try {
    await api.applyOnboarding(p);
    store.markets = null; store.analysis = null; store.review = null; store.memory = null;
    await refreshView();
    go('desk');
    toast(`${p.name} is ready. Settings are under the gear, or ⌘,.`);
    restartSetup();
  } catch (err) {
    toast(err.message, 'err');
  }
}
