/**
 * learning.js — what the app has worked out, and what it wants to change.
 *
 * This is the surface for the one part of Paper that is not the same on the
 * hundredth run as on the first. It shows three things, in this order:
 *
 *   1. **The engine's own scoreboard.** Every recommendation the desk has made,
 *      graded against what price actually did — including the ones that were never
 *      traded, which is the half that separates a badly calibrated engine from a
 *      badly traded account. No trade log can produce this number.
 *   2. **Proposals.** Each carries its evidence, its sample size and the exact
 *      numeric change it would make. Nothing has moved until you apply one.
 *   3. **What is live, what is still being watched, and what was turned down.**
 *
 * Applying and reverting are the same act, because the calibration is recomposed
 * from the whole lesson set every time — a revert cannot leave anything behind.
 */

import { store, toast, refreshView } from '../app.js';
import * as api from '../api.js';
import { esc, when, plainPct } from '../format.js';
import { aside, term } from '../glossary.js';
import { modal } from '../modal.js';

const STATUS_TONE = { proposed: 'warn', applied: 'up', watching: 'ghost', dismissed: 'ghost', retired: 'ghost' };
const STATUS_LABEL = {
  proposed: 'Waiting on you', applied: 'Live', watching: 'Gathering evidence',
  dismissed: 'Turned down', retired: 'Rolled back',
};

export async function renderLearning(host, { force } = {}) {
  if (!store.memory || force) store.memory = await api.getMemory().catch(() => null);
  paint(host);
}

function paint(host) {
  const m = store.memory;
  const s = store.state;
  if (!m) {
    host.innerHTML = `<section class="view"><div class="panel"><div class="empty">
      <div class="empty-sub">The learning record could not be loaded.</div></div></div></section>`;
    return;
  }

  const proposed = m.lessons.filter((l) => l.status === 'proposed');
  const applied = m.lessons.filter((l) => l.status === 'applied');
  const watching = m.lessons.filter((l) => l.status === 'watching');
  const settled = m.lessons.filter((l) => l.status === 'dismissed' || l.status === 'retired');

  host.innerHTML = `
    <section class="view">
      <div class="section-head">
        <h2>Calibration</h2>
        <span class="hint">From this account's own record: ${m.analysesRun} ${m.analysesRun === 1 ? 'analysis' : 'analyses'} run,
          ${m.scoreboard.graded} recommendation${m.scoreboard.graded === 1 ? '' : 's'} graded.</span>
        <span class="spacer"></span>
        <button class="btn sm" id="reviewFromLearning">Update from a review</button>
      </div>

      ${aside('Every finding below comes from measuring what price did. Nothing takes effect until you apply it, and anything applied can be rolled back.')}

      ${scoreboard(m.scoreboard)}
      ${calibration(m)}

      ${proposed.length ? group('Proposed changes', 'Each names its evidence, its sample size and what it would change.', proposed) : ''}
      ${m.notYetSupported ? notYet(m.notYetSupported) : ''}
      ${applied.length ? group('Live', 'Applied to every level the engine produces.', applied) : ''}
      ${watching.length ? group('Gathering evidence', 'Patterns that have appeared but have not reached their sample threshold.', watching) : ''}
      ${settled.length ? group('Settled', 'Turned down, or rolled back when the evidence stopped supporting them.', settled) : ''}

      ${!m.lessons.length ? empty(m, s) : ''}
      ${m.runs.length ? runHistory(m.runs) : ''}
    </section>`;

  if (!host.dataset.learningBound) {
    host.dataset.learningBound = '1';
    host.addEventListener('click', async (e) => {
      const apply = e.target.closest('[data-apply]');
      if (apply) return act(host, apply.dataset.apply, 'applied');
      const revert = e.target.closest('[data-revert]');
      if (revert) return act(host, revert.dataset.revert, 'proposed');
      const dismiss = e.target.closest('[data-dismiss]');
      if (dismiss) return act(host, dismiss.dataset.dismiss, 'dismissed');
      const restore = e.target.closest('[data-restore]');
      if (restore) return act(host, restore.dataset.restore, 'proposed');
      if (e.target.closest('#reviewFromLearning')) {
        toast('Open Analyst → Review and run it. The learning pass runs at the end of a review.');
      }
    });
  }
}

/* ------------------------------------------------------------- scoreboard */

function scoreboard(sb) {
  return `
    <div class="panel panel-pad" style="margin-bottom:18px">
      <div class="explain-label" style="margin-bottom:10px">The engine, graded on its own picks</div>
      <div class="metric-grid" style="grid-template-columns:repeat(auto-fit,minmax(104px,1fr))">
        <div class="metric"><div class="metric-label">Graded</div><div class="metric-value">${sb.graded}</div></div>
        <div class="metric"><div class="metric-label">Hit target</div><div class="metric-value up">${sb.hitTarget}</div></div>
        <div class="metric"><div class="metric-label">Hit stop</div><div class="metric-value down">${sb.hitStop}</div></div>
        <div class="metric"><div class="metric-label" title="Stopped out, then traded back above the entry. This is what a stop placed inside the ordinary noise produces.">Recovered after</div>
          <div class="metric-value ${sb.hitStop && sb.recoveredAfterStop / sb.hitStop >= 0.4 ? 'warn-text' : ''}">${sb.recoveredAfterStop}</div></div>
        <div class="metric"><div class="metric-label">Average ${term('r', 'R')}</div>
          <div class="metric-value ${sb.avgR == null ? '' : sb.avgR >= 0 ? 'up' : 'down'}">${sb.avgR == null ? '—' : sb.avgR.toFixed(2)}</div></div>
        ${sb.takenAvgR != null ? `<div class="metric"><div class="metric-label">You funded</div>
          <div class="metric-value ${sb.takenAvgR >= 0 ? 'up' : 'down'}">${sb.takenAvgR.toFixed(2)}R</div></div>` : ''}
        ${sb.untakenAvgR != null ? `<div class="metric"><div class="metric-label">You passed on</div>
          <div class="metric-value ${sb.untakenAvgR >= 0 ? 'up' : 'down'}">${sb.untakenAvgR.toFixed(2)}R</div></div>` : ''}
      </div>
      <p class="prose" style="margin-top:14px">${esc(sb.verdict)}</p>
      <p class="faint" style="font-size:11.5px;margin-top:10px;line-height:1.6">
        Every recommendation is graded, whether or not it was traded. An ignored pick still has an answer:
        price reached its target or its stop, and the bars needed to check are already here. Grading both is
        what separates a badly calibrated engine from a badly traded account.
      </p>
    </div>`;
}

function calibration(m) {
  if (!m.calibrationLines.length) {
    return `<div class="note accent" style="margin-bottom:18px"><span class="note-icon">›</span><span>
      The engine is running on its textbook settings. Nothing has been changed by the record yet.</span></div>`;
  }
  return `<div class="panel panel-pad" style="margin-bottom:18px">
    <div class="explain-label" style="margin-bottom:8px">${term('calibration', 'How the engine is currently tuned')}</div>
    <ul class="next-list">${m.calibrationLines.map((l) => `<li>${esc(l)}</li>`).join('')}</ul>
    <p class="faint" style="font-size:11.5px;margin-top:10px">
      These apply to every level on the board, in the drawer and in the analyst's picks. Turning a finding
      off below recomputes them from what is left.
    </p>
  </div>`;
}

function notYet(text) {
  return `<div class="note" style="margin-bottom:18px"><span class="note-icon">›</span><span>
    <strong>What the record does not yet support:</strong> ${esc(text)}</span></div>`;
}

/* ---------------------------------------------------------------- lessons */

function group(title, hint, lessons) {
  return `
    <div class="section-head" style="margin-top:26px"><h2>${esc(title)}</h2>
      <span class="hint">${esc(hint)}</span></div>
    ${lessons.map(lessonCard).join('')}`;
}

function lessonCard(l) {
  const tone = STATUS_TONE[l.status] ?? 'ghost';
  return `<div class="lesson ${l.status}">
    <div class="lesson-head">
      <div style="flex:1;min-width:0">
        <div class="lesson-title">${esc(l.title)}</div>
        <div class="lesson-meta">
          <span class="chip ${tone}">${esc(STATUS_LABEL[l.status])}</span>
          <span>${l.sampleSize} observation${l.sampleSize === 1 ? '' : 's'}</span>
          <span>·</span>
          <span>${l.source === 'analyst' ? 'proposed by the analyst' : 'from the arithmetic'}</span>
          ${l.status === 'applied' && l.runsSinceApplied ? `<span>· live for ${l.runsSinceApplied} analys${l.runsSinceApplied === 1 ? 'is' : 'es'}</span>` : ''}
          <span>· ${esc(when(l.updatedAt))}</span>
        </div>
      </div>
      ${actions(l)}
    </div>

    <div class="lesson-body">
      <div class="explain-block"><div class="explain-label">What was measured</div>
        <p class="prose">${esc(l.finding)}</p></div>
      <div class="explain-block"><div class="explain-label">Why that means this</div>
        <p class="prose">${esc(l.reasoning)}</p></div>

      ${changeBlock(l)}

      ${l.evidence?.length ? `<div class="lesson-evidence">
        <div class="explain-label">The observations</div>
        <ul class="next-list">${l.evidence.map((e) => `<li>${esc(e)}</li>`).join('')}</ul>
      </div>` : ''}

      ${l.outcomeNote ? `<div class="faint" style="font-size:12px">${esc(l.outcomeNote)}</div>` : ''}

      ${l.status === 'watching' ? `<div class="faint" style="font-size:11.5px">
        Not offered yet. This pattern needs a larger sample before a change to the engine would be more than
        noise.</div>` : ''}
    </div>
  </div>`;
}

/**
 * What this finding would change.
 *
 * Three cases, and conflating them is how a screen like this becomes untrustworthy:
 * a finding with a dial, a finding that is a habit and deliberately has none, and a
 * finding still gathering evidence — whose dial has not been withheld on principle,
 * it simply has not earned one yet.
 */
function changeBlock(l) {
  if (l.adjustment) {
    return `<div class="lesson-change">
      <span class="lesson-change-label">The change</span>
      <span class="lesson-change-body">${esc(l.adjustment.summary ?? changeText(l.adjustment))}</span>
    </div>`;
  }
  if (l.status === 'watching') return '';
  return `<div class="note accent"><span class="note-icon">›</span><span>
    This is a habit rather than a setting. No dial changes it, so applying it keeps the finding visible and
    tells the analyst to write around it.</span></div>`;
}

/** The Swift side sends `summary`; this is the fallback if it ever does not. */
function changeText(a) {
  return `${a.knob}${a.key ? ` (${a.key})` : ''}: ${a.from} → ${a.to}`;
}

function actions(l) {
  if (l.status === 'proposed') {
    return `<div class="btn-row">
      <button class="btn sm" data-dismiss="${esc(l.id)}">Turn down</button>
      <button class="btn primary sm" data-apply="${esc(l.id)}">Apply</button>
    </div>`;
  }
  if (l.status === 'applied') {
    return `<div class="btn-row"><button class="btn sm" data-revert="${esc(l.id)}">Roll back</button></div>`;
  }
  if (l.status === 'dismissed' || l.status === 'retired') {
    return `<div class="btn-row"><button class="btn sm" data-restore="${esc(l.id)}">Reconsider</button></div>`;
  }
  return '';
}

/* ------------------------------------------------------------ run history */

function runHistory(runs) {
  return `
    <div class="section-head" style="margin-top:30px"><h2>Every analysis this account has run</h2>
      <span class="hint">What was recommended, and what price has done since.</span></div>
    <div class="panel scroll-x"><table>
      <thead><tr><th>When</th><th>Picks</th><th>Graded</th><th>Target</th><th>Stop</th>
        <th class="right">Average R</th><th>Running with</th></tr></thead>
      <tbody>
        ${runs.slice(0, 20).map((r) => {
          const rs = r.outcomes.map((o) => o.rMultiple).filter((x) => x != null);
          const avg = rs.length ? rs.reduce((a, b) => a + b, 0) / rs.length : null;
          const lines = calibrationOf(r.calibration);
          return `<tr>
            <td class="dim">${esc(when(r.at))}</td>
            <td class="num">${r.picks.length}</td>
            <td class="num dim">${r.outcomes.length || '—'}</td>
            <td class="num up">${r.outcomes.filter((o) => o.hitTarget).length || '—'}</td>
            <td class="num down">${r.outcomes.filter((o) => o.hitStop).length || '—'}</td>
            <td class="right num ${avg == null ? 'dim' : avg >= 0 ? 'up' : 'down'}">${avg == null ? '—' : avg.toFixed(2)}</td>
            <td class="dim" style="font-size:11.5px">${lines.length ? esc(lines.join('; ')) : 'textbook settings'}</td>
          </tr>`;
        }).join('')}
      </tbody>
    </table></div>
    <p class="faint" style="font-size:11.5px;margin-top:10px">
      The last column is what the engine was tuned to at the time. Comparing average R across runs made under
      different calibrations is how a change is judged, and it needs a large number of runs.
    </p>`;
}

/** A compact read of a stored calibration, for the history table. */
function calibrationOf(c) {
  if (!c) return [];
  const out = [];
  if (c.stopScale !== 1) out.push(`stops ×${c.stopScale.toFixed(2)}`);
  if (c.targetScale !== 1) out.push(`targets ×${c.targetScale.toFixed(2)}`);
  if (c.minRewardToRiskDelta) out.push(`R:R ${c.minRewardToRiskDelta > 0 ? '+' : ''}${c.minRewardToRiskDelta.toFixed(2)}`);
  if (c.riskScale !== 1) out.push(`risk ×${c.riskScale.toFixed(2)}`);
  if (c.convictionFloor > 0) out.push(`floor ${c.convictionFloor.toFixed(0)}`);
  if (c.holdScale !== 1) out.push(`patience ×${c.holdScale.toFixed(2)}`);
  if (c.rangeCeilingScale !== 1) out.push(`volatility ×${c.rangeCeilingScale.toFixed(2)}`);
  const keyed = Object.entries({ ...(c.sectorBias ?? {}), ...(c.regimeBias ?? {}), ...(c.symbolBias ?? {}) });
  for (const [k, v] of keyed) out.push(`${k} ${v > 0 ? '+' : ''}${v.toFixed(0)}`);
  return out;
}

function empty(m, s) {
  return `<div class="panel"><div class="empty">
    <div class="empty-title">Nothing learned yet</div>
    <div class="empty-sub">
      The engine starts from its textbook settings. Run an analysis, let the picks resolve over a few
      sessions, then run a review. The review grades every recommendation against what price did and proposes
      what to adjust.
      ${m.analysesRun ? `${m.analysesRun === 1 ? '1 analysis has' : `${m.analysesRun} analyses have`} run so far; each pick needs three sessions of history before it counts.` : 'No analysis has run on this account yet.'}
    </div>
  </div></div>`;
}

/* ---------------------------------------------------------------- actions */

async function act(host, id, status) {
  const lesson = store.memory?.lessons?.find((l) => l.id === id);
  if (status === 'applied' && lesson?.adjustment) {
    const ok = await modal({
      title: 'Apply this change?',
      confirmText: 'Apply it',
      body: `<p><strong>${esc(lesson.title)}</strong></p>
        <div class="ticket-line"><span>Changes</span><span>${esc(lesson.adjustment.summary ?? '')}</span></div>
        <div class="ticket-line"><span>Resting on</span><span>${lesson.sampleSize} observations</span></div>
        <p style="margin-top:12px">It takes effect on every level the engine produces from now on: the board,
        the drawer and the next analyst run. Positions already held are not affected, and it can be rolled back
        from this tab at any time.</p>`,
    });
    if (!ok) return;
  }
  try {
    await api.setLessonStatus(id, status);
    store.memory = null;
    store.analysis = null;
    store.markets = null;
    await refreshView();
    await renderLearning(host, { force: true });
    toast(status === 'applied' ? 'Applied. Every level the engine produces now reflects it.'
      : status === 'dismissed' ? 'Turned down. It will not be offered again unless you reconsider it here.'
      : 'Rolled back. The calibration has been recomputed without it.');
  } catch (err) {
    toast(err.message, 'err');
  }
}
