/**
 * Review — what actually happened, and what it says about the person trading.
 *
 * The forensics half is arithmetic and always present: heat taken, move available,
 * and — the measurement almost no journal makes — what the instrument did *after*
 * the exit. The written half comes from the analyst and needs a key.
 *
 * The order matters. The report comes first because the portfolio-level finding is
 * usually the one that changes behaviour; the individual post-mortems below it are
 * the evidence for it.
 */

import { store, toast } from '../app.js';
import { morph } from '../morph.js';
import * as api from '../api.js';
import { money, signedMoney, price, pct, plainPct, dir, esc, when } from '../format.js';

let running = false;

const VERDICT_LABEL = {
  'sold-too-early': 'Sold too early',
  'good-exit': 'Good exit',
  'whipsawed': 'Whipsawed out',
  'stop-saved-you': 'Stop did its job',
  'gave-it-back': 'Gave it back',
  'survived-heat': 'Survived the heat',
  'clean': 'Went to plan',
  'too-soon': 'Too soon to judge',
};

const VERDICT_TONE = {
  'sold-too-early': 'warn', 'good-exit': 'up', 'whipsawed': 'warn',
  'stop-saved-you': 'up', 'gave-it-back': 'warn', 'survived-heat': 'accent',
  'clean': 'up', 'too-soon': 'ghost',
};

const GRADE_TONE = { good: 'up', acceptable: 'ghost', avoidable: 'down' };

export async function renderReview(host, { force } = {}) {
  if (!store.review || force) store.review = await api.getReview().catch(() => null);
  paint(host);
}

export function paintReview(host) { paint(host); }

function paint(host) {
  const r = store.review;
  const s = store.state;
  if (!r) {
    morph(host, `<div class="panel"><div class="empty">
      <div class="empty-sub">The review could not be loaded.</div></div></div>`);
    return;
  }

  const online = s.analyst.available;
  const hasWritten = r.at > 0 && (r.notes.length > 0 || r.report);
  const job = r.job;
  const isRunning = running || (job?.status === 'running' && job?.kind === 'review');

  /* Repainted every three seconds while the analyst works, which is the whole
   * length of a screen the reader is already part-way down. Only the stage
   * markers and the elapsed counter actually move. */
  morph(host, `
    <div class="section-head">
      <h2>Review</h2>
      <span class="hint">${r.reviews.length
        ? `${r.reviews.length} closed trade${r.reviews.length === 1 ? '' : 's'} measured against what happened next.`
        : 'Nothing closed yet.'}</span>
      <span class="spacer"></span>
      ${hasWritten ? `<span class="hint">Written ${when(r.at)}</span>` : ''}
      <button class="btn primary" id="reviewBtn" ${isRunning || !r.reviews.length ? 'disabled' : ''}>
        ${isRunning ? '<span class="spinner"></span> Working…' : hasWritten ? 'Review again' : 'Analyse the record'}
      </button>
    </div>

    ${r.reviews.length === 0 ? emptyState() : `
      ${isRunning ? runningNote(job) : ''}
      ${behaviourPanel(r.behaviour, r.tax, s)}
      ${r.report ? reportPanel(r.report) : (online ? '' : offlineNote(s))}
      ${tradeList(r.reviews, r.notes)}
    `}`);

  if (!host.dataset.reviewBound) {
    host.dataset.reviewBound = '1';
    host.addEventListener('click', (e) => {
      if (e.target.closest('#reviewBtn')) run(host);
    });
  }
}

function emptyState() {
  return `<div class="panel"><div class="empty">
    <div class="empty-title">Nothing to review yet</div>
    <div class="empty-sub">Once a position is closed, this measures what the instrument did afterwards —
      how far it ran on, or how much further it fell — and reads the pattern across every trade. It needs
      closed trades to work from.</div>
  </div></div>`;
}

function offlineNote(s) {
  return `<div class="note warn" style="margin-bottom:18px">
    <span class="note-icon">!</span>
    <span><strong>The written review is off.</strong> ${esc(s.analyst.reason)}
    Every measurement below is the engine's own arithmetic and is unaffected: the excursions, what happened
    after each exit, and the behavioural patterns.</span>
  </div>`;
}

const REVIEW_STAGES = [
  ['reviewing', 'Reading each closed trade', 'What happened, why, and whether the decision was right at the time.'],
  ['reporting', 'Writing the report', 'What the record says about how this account is being run.'],
];

function runningNote(job) {
  const idx = REVIEW_STAGES.findIndex(([k]) => k === job?.stage);
  const elapsed = job?.startedAt ? Math.round((Date.now() - job.startedAt) / 1000) : 0;
  return `<div class="panel panel-pad" style="margin-bottom:16px">
    <div class="row" style="gap:12px;margin-bottom:14px">
      <div class="spinner"></div>
      <div style="flex:1">
        <div style="font-weight:600;font-size:13px">Two passes over the record</div>
        <div class="faint" style="font-size:12px">${job?.candidates ? `${job.candidates} closed trades. ` : ''}The
          post-mortems run first, then the report across them.</div>
      </div>
      <span class="chip ghost">${elapsed}s</span>
    </div>
    <div class="scores">
      ${REVIEW_STAGES.map(([key, label, detail], i) => {
        const state = idx < 0 ? (i === 0 ? 'now' : 'todo') : i < idx ? 'done' : i === idx ? 'now' : 'todo';
        return `<div class="row stage${state === 'todo' ? ' is-todo' : ''}" style="gap:11px;align-items:flex-start">
          <div class="pick-rank" style="background:${state === 'done' ? 'var(--up-soft)' : state === 'now' ? 'var(--accent-soft)' : 'var(--bg-hover)'};color:${state === 'done' ? 'var(--up)' : state === 'now' ? 'var(--accent)' : 'var(--text-faint)'}">
            ${state === 'done' ? '✓' : i + 1}</div>
          <div><div style="font-size:12.5px;font-weight:${state === 'now' ? '600' : '500'}">${label}</div>
            <div class="faint" style="font-size:11.5px">${detail}</div></div>
        </div>`;
      }).join('')}
    </div>
  </div>`;
}

/* ------------------------------------------------------- what the record says */

function behaviourPanel(b, tax, s) {
  const beat = b.accountReturnPct != null && b.benchmarkReturnPct != null
    ? b.accountReturnPct - b.benchmarkReturnPct : null;

  return `<div class="panel" style="margin-bottom:18px">
    <div class="stat-grid">
      <div class="stat"><span class="stat-label">Return, trading only</span>
        <span class="stat-value ${dir(b.accountReturnPct)}">${b.accountReturnPct == null ? '—' : pct(b.accountReturnPct, 2)}</span>
        <span class="stat-note">net of everything paid in</span></div>
      <div class="stat"><span class="stat-label">Owning the index instead</span>
        <span class="stat-value ${dir(b.benchmarkReturnPct)}">${b.benchmarkReturnPct == null ? '—' : pct(b.benchmarkReturnPct, 2)}</span>
        <span class="stat-note ${beat == null ? '' : dir(beat)}">${beat == null ? 'S&P 500, same window'
          : `${beat >= 0 ? 'ahead by' : 'behind by'} ${plainPct(Math.abs(beat), 2)}`}</span></div>
      <div class="stat"><span class="stat-label">Move captured</span>
        <span class="stat-value">${b.captureRatePct == null ? '—' : plainPct(b.captureRatePct, 0)}</span>
        <span class="stat-note">of what was available while held</span></div>
      <div class="stat"><span class="stat-label">Heat taken</span>
        <span class="stat-value">${b.avgMaeR == null ? '—' : b.avgMaeR.toFixed(2) + 'R'}</span>
        <span class="stat-note">average worst point before the exit</span></div>
      <div class="stat"><span class="stat-label">Left on the table</span>
        <span class="stat-value ${b.totalLeftOnTable > 0 ? 'warn-text' : ''}">${money(b.totalLeftOnTable, 0)}</span>
        <span class="stat-note">since selling, on positions that ran on</span></div>
      <div class="stat"><span class="stat-label">Hold time</span>
        <span class="stat-value" style="font-size:15px">${b.avgHoldWinnersDays == null ? '—' : b.avgHoldWinnersDays.toFixed(1)}
          · ${b.avgHoldLosersDays == null ? '—' : b.avgHoldLosersDays.toFixed(1)}</span>
        <span class="stat-note">days: winners · losers</span></div>
    </div>

    ${b.patterns.length ? `<div class="panel-pad" style="border-top:1px solid var(--line);display:flex;flex-direction:column;gap:10px">
      ${b.patterns.map((p) => `<div class="note"><span class="note-icon">›</span><span>${esc(p)}</span></div>`).join('')}
    </div>` : ''}

    <div class="panel-pad" style="border-top:1px solid var(--line)">
      <div class="row wrap" style="gap:8px">
        <span class="chip ghost" title="Spread and commission paid on every fill, in and out.">
          ${money(s.scorecard.totalCommission + s.scorecard.totalSlippage, 0)} in costs</span>
        <span class="chip ghost" title="Withheld at the moment each gain was realised.">
          ${money(s.scorecard.totalTax, 0)} in tax</span>
        ${s.scorecard.pnlBeforeCosts != null ? `<span class="chip ${dir(s.scorecard.pnlBeforeCosts)}">
          ${signedMoney(s.scorecard.pnlBeforeCosts)} before costs</span>` : ''}
        ${b.gappedExits ? `<span class="chip warn">${b.gappedExits} exit${b.gappedExits === 1 ? '' : 's'} gapped through the level</span>` : ''}
        ${b.backfilledExits ? `<span class="chip ghost" title="Rebuilt from daily bars for sessions Paper was closed for. The fills are right; their timing inside the day is inferred.">${b.backfilledExits} reconstructed after the fact</span>` : ''}
        ${b.dayTrades ? `<span class="chip ghost">${b.dayTrades} same-session round trips</span>` : ''}
        ${b.positionsWithoutStop ? `<span class="chip down">${b.positionsWithoutStop} closed with no stop</span>` : ''}
      </div>
      <div class="faint" style="font-size:12px;margin-top:10px">${esc(tax.note)}</div>
    </div>
  </div>`;
}

/* ----------------------------------------------------------------- report */

function reportPanel(r) {
  return `<div class="panel" style="margin-bottom:18px">
    <div class="panel-pad">
      <div class="pick-headline" style="font-size:15px;margin-bottom:4px">${esc(r.headline)}</div>
      <div class="faint" style="font-size:11.5px">Across the whole record.</div>
    </div>
    <div class="panel-pad" style="border-top:1px solid var(--line);display:flex;flex-direction:column;gap:16px">
      ${block('Performance', r.performance)}
      ${block('What is working', r.whatIsWorking)}
      ${block('What is not', r.whatIsNot)}
      ${block('How you are trading', r.behaviouralRead)}
      ${block('What frequency is costing', r.costDrag)}
      ${block('Fit with the profile', r.suitabilityRead)}
      ${r.nextPeriod?.length ? `<div class="explain-block">
        <div class="explain-label">For the next period</div>
        <ul class="next-list">${r.nextPeriod.map((x) => `<li>${esc(x)}</li>`).join('')}</ul>
      </div>` : ''}
      <div class="note accent"><span class="note-icon">›</span>
        <span><strong>The one number to watch:</strong> ${esc(r.oneNumberToWatch)}</span></div>
    </div>
  </div>`;
}

function block(label, text) {
  if (!text) return '';
  return `<div class="explain-block">
    <div class="explain-label">${esc(label)}</div>
    <p class="prose">${esc(text)}</p>
  </div>`;
}

/* ------------------------------------------------------------ the trades */

function tradeList(reviews, notes) {
  const byId = new Map(notes.map((n) => [n.tradeId, n]));
  return `<div class="section-head" style="margin-top:26px">
      <h2>Trade by trade</h2>
      <span class="hint">Newest first, including what each instrument did after the exit.</span>
    </div>
    ${reviews.map((r) => tradeCard(r, byId.get(r.tradeId))).join('')}`;
}

function tradeCard(r, note) {
  const tone = VERDICT_TONE[r.verdict] ?? 'ghost';
  const after = r.sinceExitPct;

  return `<div class="pick">
    <div class="pick-head">
      <div class="pick-rank" style="background:var(--bg-hover);color:var(--text-dim);font-size:11px">
        ${r.pnl >= 0 ? '+' : '−'}</div>
      <div class="pick-title">
        <div class="pick-headline">${esc(note?.headline ?? `${r.symbol} — ${VERDICT_LABEL[r.verdict]}`)}</div>
        <div class="pick-meta">
          <span data-symbol="${esc(r.symbol)}" style="cursor:pointer;color:var(--text-dim)">${esc(r.symbol)}</span>
          · held ${r.holdingDays < 1 ? 'under a day' : `${r.holdingDays.toFixed(1)} days`}
          · closed ${when(r.closedAt)}
          ${r.trigger ? ` · ${esc(r.trigger)} exit` : ''}
          ${r.gapped ? ' · <span class="warn-text">gapped through</span>' : ''}
          ${r.backfilled ? ' · <span class="faint">reconstructed</span>' : ''}
          ${r.dayTrade ? ' · same session' : ''}
        </div>
      </div>
      <div class="row" style="gap:6px">
        ${note ? `<span class="chip ${GRADE_TONE[note.grade] ?? 'ghost'}">${esc(note.grade)}</span>` : ''}
        <span class="chip ${tone}">${VERDICT_LABEL[r.verdict]}</span>
      </div>
    </div>

    <div class="pick-body">
      <div class="plan">
        <div class="plan-cell entry">
          <div class="plan-label">In and out</div>
          <div class="plan-price">${price(r.entry, r.symbol)} → ${price(r.exit, r.symbol)}</div>
          <div class="plan-delta ${dir(r.pnl)}">${signedMoney(r.pnl)}${r.rMultiple != null ? ` · ${r.rMultiple >= 0 ? '+' : ''}${r.rMultiple.toFixed(2)}R` : ''}</div>
        </div>
        <div class="plan-cell target">
          <div class="plan-label">Best while held</div>
          <div class="plan-price up">${pct(r.mfePct, 1)}</div>
          <div class="plan-delta faint">${r.mfeR != null ? `${r.mfeR.toFixed(2)}R was available` : 'no stop set, so no R'}</div>
        </div>
        <div class="plan-cell stop">
          <div class="plan-label">Worst while held</div>
          <div class="plan-price down">${pct(r.maePct, 1)}</div>
          <div class="plan-delta faint">${r.maeR != null ? `${r.maeR.toFixed(2)}R of heat taken` : '—'}</div>
        </div>
      </div>

      ${r.sessionsSinceExit >= 1 ? `
      <div class="after-strip">
        <div class="after-label">Since you sold, ${r.sessionsSinceExit} session${r.sessionsSinceExit === 1 ? '' : 's'}</div>
        <div class="row wrap" style="gap:7px">
          <span class="chip ${dir(after)}">${pct(after, 1)} from your exit</span>
          <span class="chip ghost">best ${pct(r.postExitBestPct, 1)}</span>
          <span class="chip ghost">worst ${pct(r.postExitWorstPct, 1)}</span>
          ${r.leftOnTable != null ? `<span class="chip ${r.leftOnTable > 0 ? 'warn' : 'up'}">
            holding on would be ${signedMoney(r.leftOnTable)}</span>` : ''}
        </div>
      </div>` : `<div class="faint" style="font-size:12px">No sessions have printed since the exit, so there
        is nothing yet to measure.</div>`}

      ${note ? `
        ${block('What happened', note.whatHappened)}
        ${block('Why it moved', note.whyItMoved)}
        ${block('Was the decision right at the time', note.executionCall)}
        ${block('Do differently', note.doDifferently)}
        <div class="note accent"><span class="note-icon">›</span>
          <span><strong>Transfers to any instrument:</strong> ${esc(note.transferable)}</span></div>
      ` : `<div class="explain-block">
        <div class="explain-label">The measured record</div>
        <p class="prose">${esc(r.evidence)}</p>
      </div>`}

      ${r.thesis ? `<div class="faint" style="font-size:12px">
        <strong style="color:var(--text-dim)">Recorded at the time:</strong> ${esc(r.thesis)}</div>` : ''}

      <div class="row wrap" style="gap:7px">
        <span class="chip ghost">${money(r.costs, 2)} in costs</span>
        ${r.taxDue ? `<span class="chip ghost">${money(r.taxDue, 2)} tax</span>` : ''}
        ${r.stop != null ? `<span class="chip ghost">stop was ${price(r.stop, r.symbol)}</span>`
          : '<span class="chip down">no stop was set</span>'}
      </div>
    </div>
  </div>`;
}

/* ------------------------------------------------------------------ run it */

async function run(host) {
  if (running) return;
  running = true;
  paint(host);
  try {
    await api.runReview();
    toast('Reviewing the record. Two passes, a couple of minutes.');
  } catch (err) {
    running = false;
    toast(err.message, 'err');
    return paint(host);
  }

  const poll = setInterval(async () => {
    try {
      const snapshot = await api.getReview();
      store.review = snapshot;
      if (snapshot.job?.status === 'running' && snapshot.job?.kind === 'review') return paint(host);
      clearInterval(poll);
      running = false;
      paint(host);
      if (snapshot.job?.status === 'error') toast(snapshot.job.error ?? 'The review did not finish.', 'err');
      else toast('Review complete.');
    } catch { /* a dropped poll is not worth a toast */ }
  }, 3000);
}
