/**
 * Analyst — the recommendation surface.
 *
 * Two modes. With a key, Claude's three chained passes produce the written
 * thesis, the ranking and the teaching brief. Without one, the same candidate
 * set is presented with a narrative built from the metrics themselves, because
 * a simulator that shows nothing until you supply a credential teaches nothing.
 */

import { store, toast, refreshView } from '../app.js';
import * as api from '../api.js';
import { morph, clearMorph } from '../morph.js';
import { money, price, pct, plainPct, dir, esc, when, REGIME_LABEL, regimeClass, scoreColor } from '../format.js';
import { modal } from '../modal.js';
import { diagnosisBlock } from './analystsettings.js';
import { renderReview } from './review.js';

let running = false;

/**
 * The horizon this run is for.
 *
 * Deliberately separate from the profile's own. The account decides how much can
 * be risked and what it can survive; this decides what kind of trade is being
 * looked for, and the same board answers the two questions differently — a name
 * that is a good five-year hold is usually a bad two-day trade, and the engine
 * now says so instead of returning one list to both.
 *
 * Null means "whatever the profile says", which is what the button always did.
 */
let style = null;

/** Whether the near-misses are expanded. Off by default: the shortlist is the
 *  answer, and the refusals are the working. */
let showMisses = false;

/**
 * The engine's own shortlist for the horizon currently selected, and whether a
 * fetch for it is in flight.
 *
 * Kept because it is free. The scoring is arithmetic over bars already on the
 * board, so the four horizons can be compared without paying to find out whether
 * they differ — which was the actual complaint: running the analyst repeatedly
 * and getting the same names back, with no way to see why except to run it again.
 */
let preview = null;
let previewing = false;

async function loadPreview(host, wanted) {
  previewing = true;
  paint(host);
  try {
    preview = await api.getShortlist(wanted ?? undefined);
  } catch {
    preview = null;   // a failed preview is not worth an error banner; the run still works
  }
  previewing = false;
  paint(host);
}

/* The analyst does two different jobs, and they are worth keeping apart: ideas
 * look forward from the board, the review looks backward from the record. */
let section = 'ideas';

const SECTIONS = [
  ['ideas', 'Ideas', 'What to fund now, for this profile.'],
  ['review', 'Review', 'What the closed trades say, and what happened after each exit.'],
];

/** Which segment the tab opens on, set by the account's reading mode. */
export function setAnalystSection(id) {
  if (SECTIONS.some(([k]) => k === id)) section = id;
}

function segmented() {
  return `<div class="section-head" style="margin-bottom:18px">
    <div class="range-tabs">
      ${SECTIONS.map(([k, l, d]) =>
        `<button data-section="${k}" class="${section === k ? 'is-active' : ''}" title="${d}">${l}</button>`).join('')}
    </div>
  </div>`;
}

function wireSegments(host) {
  // Assigned rather than added: the segments survive a repaint now, so a listener
  // added to each of them would stack up one per paint.
  host.querySelectorAll('[data-section]').forEach((b) => {
    b.onclick = () => {
      if (section === b.dataset.section) return;
      section = b.dataset.section;
      renderAnalyst(host, {});
    };
  });
}

export async function renderAnalyst(host, { force } = {}) {
  if (section === 'review') {
    host.innerHTML = `<section class="view">${segmented()}<div id="analystBody"></div></section>`;
    // Written past the patcher, so it is told to forget what it thinks is there —
    // otherwise coming back to the ideas half with unchanged markup would be read
    // as a no-op and leave the review on screen.
    clearMorph(host);
    wireSegments(host);
    await renderReview(host.querySelector('#analystBody'), { force });
    return;
  }
  if (!store.analysis || force) store.analysis = await api.getAnalysis().catch(() => null);
  paint(host);
}

function paint(host) {
  const s = store.state;
  const a = store.analysis;
  const online = s.analyst.available;
  const hasRun = a && a.at > 0;

  /* Repainted every two and a half seconds while a run is going: patched so the
   * stage markers and the counter move and the rest of the screen sits still. */
  morph(host, `
    <section class="view">
      ${segmented()}
      <div class="section-head">
        <h2>Ideas</h2>
        <span class="hint">${hasRun ? `Last run ${when(a.at)}` : 'Not run yet'} · sized and filtered for
          <strong>${esc(s.profile.name)}</strong></span>
        <span class="spacer"></span>
        <button class="btn primary" id="runBtn" ${running ? 'disabled' : ''}>
          ${running ? '<span class="spinner"></span> Working…' : hasRun ? 'Run again' : 'Run the analyst'}
        </button>
      </div>

      ${stylePicker(a, s)}
      ${previewBlock(a, s)}

      ${backdrop(s)}
      ${online ? '' : offlineNote(s)}
      ${a?.job?.status === 'error' ? jobError(a.job) : ''}
      ${running ? runningNote(online, a?.job) : ''}
      ${!running && a?.diagnosis && a.diagnosis.findings?.some((f) => f.severity !== 'ok')
        ? `<div class="panel panel-pad" style="margin-bottom:18px">${diagnosisBlock(a.diagnosis, { title: 'Why the last run ended as it did' })}</div>`
        : ''}
      ${hasRun ? results(a, online) : (running ? '' : idle())}
    </section>`);

  // Delegated once per host rather than re-bound per node: paint() replaces the
  // whole subtree on every render, and per-node listeners silently stop existing
  // the moment anything repaints between binding and clicking.
  wireSegments(host);

  if (!host.dataset.analystBound) {
    host.dataset.analystBound = '1';
    host.addEventListener('click', async (e) => {
      if (e.target.closest('#runBtn')) return run(host);
      if (e.target.closest('#stopRunBtn')) {
        try {
          const res = await api.stopAnalysis();
          toast(res.note, res.stopped ? 'ok' : 'err', 7000);
        } catch (err) { toast(err.message, 'err'); }
        return;
      }
      const styleBtn = e.target.closest('[data-style]');
      if (styleBtn) {
        if (style === styleBtn.dataset.style) return;
        style = styleBtn.dataset.style;
        preview = null;
        return loadPreview(host, style);
      }
      if (e.target.closest('#missToggle')) {
        showMisses = !showMisses;
        return paint(host);
      }
      const take$ = e.target.closest('[data-take]');
      if (take$) return take(take$);
    });
  }
}

/* ------------------------------------------------------------ the mandate */

/**
 * What kind of trade this run is for.
 *
 * The thing the engine was missing. Horizon used to live on the profile alone,
 * where it scaled the stop and the target and did nothing at all to the scoring —
 * so a day trader and a pension holder were handed the same twelve names in the
 * same order, and the names were always the large, slow ones because the risk
 * axis punished movement and nothing rewarded it.
 *
 * Choosing here rescores the whole board for that question. Nothing about the
 * account changes: the risk per trade, the position limits and the ledger stay
 * exactly where the profile set them. Running all four over one afternoon and
 * reading where they disagree is the point.
 */
function stylePicker(a, s) {
  const options = a?.styles ?? [];
  if (!options.length) return '';
  const active = style ?? a?.style ?? s.profile.horizon;
  const chosen = options.find((o) => o.id === active) ?? options[0];

  return `<div class="panel panel-pad style-picker" style="margin-bottom:18px">
    <div class="row wrap" style="gap:10px;align-items:center">
      <span class="faint" style="font-size:12px;letter-spacing:.02em">What kind of trade</span>
      <div class="range-tabs">
        ${options.map((o) => `<button data-style="${esc(o.id)}"
          class="${o.id === active ? 'is-active' : ''}"
          title="${esc(o.emphasis)}">${esc(o.short)}</button>`).join('')}
      </div>
      ${style && style !== s.profile.horizon
        ? `<span class="chip warn" title="This account's own horizon is ${esc(s.profile.horizon)}. The limits and sizing are still the profile's; only the read has changed.">overriding the account</span>`
        : ''}
    </div>
    <p class="prose" style="font-size:12.5px;margin-top:10px">
      ${esc(chosen.emphasis)} Trades are expected to resolve in ${esc(chosen.holdFor)}.
      ${a?.at > 0 && a.style && a.style !== active
        ? '<strong>The results below were scored for a different horizon.</strong> Run again to rescore the board for this one.'
        : ''}
    </p>
  </div>`;
}

/**
 * What the engine would put in front of the analyst, before a penny is spent.
 *
 * Shown only when the selected horizon is not the one the last run used, because
 * that is the moment the question arises. It is the engine's read alone — no
 * thesis, no ranking, no allocation — and it says so, since the difference
 * between "twelve names cleared the rules" and "these are the trades to take" is
 * the entire value of the passes that follow.
 */
function previewBlock(a, s) {
  const active = style ?? a?.style ?? s.profile.horizon;
  const lastRun = a?.at > 0 ? a.style : null;
  if (!style || style === lastRun) return '';

  if (previewing || !preview) {
    return `<div class="panel panel-pad" style="margin-bottom:18px">
      <div class="row" style="gap:12px"><div class="spinner"></div>
        <div class="faint" style="font-size:12.5px">Rescoring the board for a ${esc(active)} horizon…</div>
      </div></div>`;
  }
  if (preview.style !== active) return '';

  const funded = new Set((a?.ranking?.picks ?? []).map((p) => p.symbol));
  return `<div class="panel panel-pad" style="margin-bottom:18px">
    <div class="section-head" style="margin-bottom:10px">
      <h2 style="font-size:13px">What a ${esc(preview.label.split(' —')[0].toLowerCase())} run would look at</h2>
      <span class="hint">${preview.considered} instruments rescored · free, nothing called</span>
    </div>
    <div class="row wrap" style="gap:6px">
      ${preview.picks.map((p) => `<span class="chip ${funded.has(p.symbol) ? 'ghost' : 'accent'}"
        title="${esc(p.name)} · ${esc(p.sector)} · ${esc(p.venue)} — engine read ${p.conviction.toFixed(0)}/100, ${p.rr.toFixed(2)}:1, stop ${price(p.stop, p.symbol)}">
        ${esc(p.symbol.replace('-USD', ''))} <span class="faint">${p.conviction.toFixed(0)}</span></span>`).join('')}
    </div>
    <p class="prose" style="font-size:12.5px;margin-top:12px">
      ${funded.size
        ? `Shaded names were already funded by the last run; the rest are what changing the horizon surfaces.`
        : `These cleared the risk engine for this horizon.`}
      This is the engine's read only — no thesis, no ranking, no allocation. Run the analyst to get those.
    </p>
  </div>`;
}

/* ---------------------------------------------------------- the near misses */

const MISS_LABEL = {
  rejected: 'refused by the risk engine',
  floor: 'below the conviction floor',
  sector: 'sector already full',
  complex: 'same bet, different ticker',
  venue: 'made room for another market',
  rank: 'ranked below the cut',
};

/**
 * What the engine looked at and did not fund.
 *
 * A shortlist on its own is unfalsifiable. Twelve names tell you nothing about
 * whether the board had fourteen good ideas or two, and nothing about whether a
 * name is absent because its chart is poor or because two others from the same
 * complex were funded first. All of this was already being computed and thrown
 * away; the refusals are where most of the teaching is.
 */
function nearMisses(a) {
  const misses = a?.nearMisses ?? [];
  if (!misses.length) return '';
  const shown = showMisses ? misses : misses.slice(0, 6);

  return `<div style="margin-top:28px">
    <div class="section-head">
      <h2 style="font-size:13px">What did not make the list</h2>
      <span class="hint">${a.considered ? `${a.considered} instruments read` : ''}${a.considered ? ' · ' : ''}${misses.length} set aside</span>
      <span class="spacer"></span>
      ${misses.length > 6
        ? `<button class="btn ghost sm" id="missToggle">${showMisses ? 'Show fewer' : `Show all ${misses.length}`}</button>`
        : ''}
    </div>
    <div class="panel scroll-x"><table>
      <thead><tr><th>Instrument</th><th>Market</th><th class="right">Read</th><th>Why not</th></tr></thead>
      <tbody>${shown.map((mi) => `<tr>
        <td><div class="sym">
          <span class="sym-ticker clickable" data-symbol="${esc(mi.symbol)}" style="cursor:pointer">${esc(mi.symbol.replace('-USD', ''))}</span>
          <span class="sym-name">${esc(mi.name)} · ${esc(mi.sector)}</span>
        </div></td>
        <td class="dim" style="font-size:12px">${esc(mi.venue)}</td>
        <td class="right num ${mi.conviction == null ? 'dim' : ''}">
          ${mi.conviction == null ? '—' : mi.conviction.toFixed(0)}
          ${mi.rank ? `<span class="faint" style="font-size:10.5px"> #${mi.rank}</span>` : ''}</td>
        <td style="max-width:460px">
          <span class="chip ghost" style="font-size:9.5px">${esc(MISS_LABEL[mi.kind] ?? mi.kind)}</span>
          <div class="faint" style="font-size:12px;margin-top:4px">${esc(mi.reason)}</div></td>
      </tr>`).join('')}</tbody>
    </table></div>
  </div>`;
}

/* -------------------------------------------------------------- backdrop */

function backdrop(s) {
  const g = s.cryptoGlobal;
  const reads = [s.regimes.stocks, s.regimes.sweden, s.regimes.crypto].filter(Boolean);
  return `<div class="panel panel-pad" style="margin-bottom:18px">
    <div class="${reads.length > 2 ? 'grid-auto' : 'grid-2'}">
      ${reads.map((r) => `
        <div>
          <div class="row" style="gap:8px;margin-bottom:6px">
            <span class="regime-pill" data-r="${esc(r.label)}"><span class="regime-dot"></span>${esc(r.headline)}</span>
            ${r.breadthPct != null ? `<span class="chip ghost">${plainPct(r.breadthPct, 0)} breadth</span>` : ''}
          </div>
          <p class="prose" style="font-size:12.5px">${esc(r.detail)}</p>
        </div>`).join('')}
    </div>
    ${g ? `<div class="row wrap" style="margin-top:14px;gap:8px;padding-top:12px;border-top:1px solid var(--line)">
      <span class="chip ghost">Crypto market cap $${(g.totalMarketCapUsd / 1e12).toFixed(2)}T</span>
      <span class="chip ${dir(g.marketCapChangePct24h)}">${pct(g.marketCapChangePct24h, 1)} in 24h</span>
      <span class="chip ghost" title="When dominance rises in a falling market, money is hiding in Bitcoin rather than leaving crypto.">Bitcoin dominance ${plainPct(g.btcDominance, 1)}</span>
      <span class="chip ghost">Ether ${plainPct(g.ethDominance, 1)}</span>
    </div>` : ''}
  </div>`;
}

function offlineNote(s) {
  return `<div class="note warn" style="margin-bottom:18px">
    <span class="note-icon">!</span>
    <span><strong>Written analysis is off.</strong> ${esc(s.analyst.reason)}
    Ranking, levels and position sizes below still come from the risk engine. A key adds the news reading
    and a written brief on each pick.</span>
  </div>`;
}

const STAGES = [
  ['screening', 'Screening candidates', 'Reading each name against its own chart and headlines.'],
  ['ranking', 'Ranking the survivors', 'Weighing them against each other and allocating the risk budget.'],
  ['briefing', 'Writing the briefs', 'Explaining what is happening, why, and how each trade is run.'],
];

function runningNote(online, job) {
  const stage = job?.stage ?? null;
  const elapsed = job?.startedAt ? Math.round((Date.now() - job.startedAt) / 1000) : 0;
  const idx = STAGES.findIndex(([k]) => k === stage);

  if (!online) {
    return `<div class="panel panel-pad" style="margin-bottom:16px">
      <div class="row" style="gap:12px"><div class="spinner"></div>
        <div><div style="font-weight:600;font-size:13px">Scoring the universe</div>
        <div class="faint" style="font-size:12px">Pulling fresh bars and rebuilding every trade plan.</div></div>
      </div></div>`;
  }

  const spent = job?.tokensSpent ?? 0;
  const budget = job?.tokensBudget ?? 0;
  const used = budget > 0 ? Math.min(100, (spent / budget) * 100) : 0;

  return `<div class="panel panel-pad" style="margin-bottom:16px">
    <div class="row" style="gap:12px;margin-bottom:14px">
      <div class="spinner"></div>
      <div style="flex:1">
        <div style="font-weight:600;font-size:13px">Three passes, back to back</div>
        <div class="faint" style="font-size:12px">
          ${job?.candidates ? `${job.candidates} candidates cleared the risk engine. ` : ''}Each pass reads the one before it. A few minutes end to end.</div>
      </div>
      <span class="chip ghost">${elapsed}s</span>
      <button class="btn danger sm" id="stopRunBtn">Stop</button>
    </div>

    ${budget > 0 ? `<div class="meter-row">
      <div class="meter-row-head">
        <span class="faint">Tokens</span>
        <span class="num ${used > 85 ? 'warn-text' : 'dim'}">${(spent).toLocaleString('en-US')} of ${(budget).toLocaleString('en-US')}${job?.estimatedCost != null ? ` · about $${job.estimatedCost.toFixed(2)}` : ''}</span>
      </div>
      <div class="score-track"><div class="score-fill" style="width:${used}%;background:${used > 85 ? 'var(--warn)' : 'var(--accent)'}"></div></div>
      <div class="faint" style="font-size:11px;margin-top:5px">
        ${job?.callsMade ?? 0} call${job?.callsMade === 1 ? '' : 's'} made. The budget is checked before each
        call, and a pass it cannot finish is not started.
      </div>
    </div>` : ''}
    <div class="scores">
      ${STAGES.map(([key, label, detail], i) => {
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

function jobError(job) {
  return `<div class="note warn" style="margin-bottom:16px">
    <span class="note-icon">!</span>
    <span><strong>The last run did not finish.</strong> ${esc(job.error ?? 'Unknown error.')}
    Any ranking below came from the engine and is still valid. Only the written analysis is missing.</span>
  </div>`;
}

function idle() {
  return `<div class="panel"><div class="empty">
    <div class="empty-title">No analysis yet</div>
    <div class="empty-sub">The analyst pulls a year of bars for every instrument, computes trend, momentum,
      volatility and levels, refuses every setup whose reward does not justify its risk, then ranks and
      explains what is left.</div>
  </div></div>`;
}

/* --------------------------------------------------------------- results */

function results(a, online) {
  const plans = a.plans ?? {};
  const readBy = new Map((a.reads ?? []).map((r) => [r.symbol, r]));
  const briefBy = new Map((a.briefs ?? []).map((b) => [b.symbol, b]));
  const picks = a.ranking?.picks ?? [];

  // Without a ranking pass, fall back to the engine's own ordering.
  const ordered = picks.length
    ? picks
    : Object.keys(plans)
        .map((sym) => ({ symbol: sym, rank: 0, allocationPct: 0, why: '' }))
        .sort((x, y) => (plans[y.symbol]?.rr ?? 0) - (plans[x.symbol]?.rr ?? 0))
        .slice(0, 5);

  if (!ordered.length) {
    // Nothing funded is a result, not a blank screen. The refusals below say what
    // was looked at and why none of it cleared, which is the more useful half.
    return `<div class="panel"><div class="empty">
      <div class="empty-title">No setup clears the bar right now</div>
      <div class="empty-sub">Every candidate was refused, usually because the reward does not justify a
        stop placed far enough away to survive ordinary noise.</div>
    </div></div>
    ${nearMisses(a)}`;
  }

  const totalRisk = ordered.reduce((sum, p) => sum + (plans[p.symbol]?.riskTaken ?? 0), 0);

  return `
    ${a.ranking ? portfolioNote(a.ranking) : ''}
    <div class="section-head"><h2>Funded ideas</h2>
      <span class="hint">${ordered.length} picks · ${money(totalRisk, 0)} of total capital at risk if every stop fills</span></div>
    ${ordered.map((p, i) => pickCard(p, i, plans[p.symbol], readBy.get(p.symbol), briefBy.get(p.symbol), online, a.metrics)).join('')}
    ${a.ranking?.passed?.length ? passedList(a.ranking.passed) : ''}
    ${nearMisses(a)}`;
}

function portfolioNote(r) {
  return `<div class="panel panel-pad" style="margin-bottom:18px">
    <div class="explain-block">
      <div class="explain-label">The basket as a whole</div>
      <p class="prose">${esc(r.portfolioNote)}</p>
    </div>
    ${r.concentrationWarning ? `<div class="note warn" style="margin-top:12px">
      <span class="note-icon">!</span><span>${esc(r.concentrationWarning)}</span></div>` : ''}
  </div>`;
}

function pickCard(pick, i, plan, read, brief, online, metrics) {
  if (!plan) return '';
  const m = metrics?.[pick.symbol];
  const headline = brief?.headline ?? read?.thesis ?? engineHeadline(plan, m);

  return `<div class="pick">
    <div class="pick-head">
      <div class="pick-rank">${i + 1}</div>
      <div class="pick-title">
        <div class="pick-headline">${esc(headline)}</div>
        <div class="pick-meta">
          <span data-symbol="${esc(pick.symbol)}" style="cursor:pointer;color:var(--text-dim)">${esc(pick.symbol)}</span>
          ${m ? ` · ${REGIME_LABEL[m.regime]} · engine read ${m.conviction.toFixed(0)}/100` : ''}
          ${pick.allocationPct ? ` · ${plainPct(pick.allocationPct, 0)} of the risk budget` : ''}
          ${plan.tightStop ? ' · tightened stop' : ''}
        </div>
      </div>
      <button class="btn primary sm" data-take="${esc(pick.symbol)}">Take this trade</button>
    </div>

    <div class="pick-body">
      <div class="plan">
        <div class="plan-cell entry">
          <div class="plan-label">${plan.entryKind === 'pullback' ? 'Entry — wait for a pullback' : 'Entry — at market'}</div>
          <div class="plan-price">${price(plan.entry, plan.symbol)}</div>
          <div class="plan-delta faint">${money(plan.cost, 0)} position · ${plan.shares < 1 ? plan.shares.toFixed(4) : plan.shares.toFixed(2)} units</div>
        </div>
        <div class="plan-cell target">
          <div class="plan-label">Target</div>
          <div class="plan-price up">${price(plan.target, plan.symbol)}</div>
          <div class="plan-delta up">${pct(plan.targetPct, 1)} · ${money(plan.shares * (plan.target - plan.entry), 0)} if it works</div>
        </div>
        <div class="plan-cell stop">
          <div class="plan-label">Stop</div>
          <div class="plan-price down">${price(plan.stop, plan.symbol)}</div>
          <div class="plan-delta down">${pct(plan.stopPct, 1)} · ${money(plan.riskTaken, 0)} at risk</div>
        </div>
      </div>

      <div class="row wrap" style="gap:7px">
        <span class="chip up">${plan.rr.toFixed(2)}:1 reward to risk</span>
        <span class="chip ghost" title="How often you need to be right at this ratio just to break even.">breaks even at a ${plan.breakevenWinRate.toFixed(0)}% win rate</span>
        <span class="chip ghost">~${plan.horizonDays} sessions to target</span>
        ${m?.atrPct != null ? `<span class="chip ghost" title="Average daily range. The stop is placed in multiples of this.">${plainPct(m.atrPct)} daily range</span>` : ''}
      </div>

      ${brief ? briefBlocks(brief) : engineBlocks(plan, m, read, online)}
    </div>
  </div>`;
}

function briefBlocks(b) {
  return `
    <div class="explain-block"><div class="explain-label">What is happening</div><p class="prose">${esc(b.what)}</p></div>
    <div class="explain-block"><div class="explain-label">Why the opportunity exists</div><p class="prose">${esc(b.why)}</p></div>
    <div class="explain-block"><div class="explain-label">How the trade is run</div><p class="prose">${esc(b.how)}</p></div>
    <div class="note warn"><span class="note-icon">!</span><span><strong>What would end it early:</strong> ${esc(b.invalidation)}</span></div>
    ${b.jargon?.length ? `<div class="jargon">${b.jargon.map((j) => `
      <div class="jargon-item"><span class="jargon-term">${esc(j.term)}</span> — ${esc(j.plain)}</div>`).join('')}</div>` : ''}`;
}

/**
 * The engine's own account of itself. This is what a user sees with no API key,
 * and it has to stand on its own rather than read as a placeholder.
 */
function engineBlocks(plan, m, read, online) {
  if (!m) return '';
  const atrMult = m.atr14 ? ((plan.entry - plan.stop) / m.atr14) : null;
  const stackText = m.sma20 && m.sma50 && m.sma200
    ? (m.sma20 > m.sma50 && m.sma50 > m.sma200
        ? 'the 20-, 50- and 200-day averages are stacked in order, which is what defines an uptrend'
        : m.price > m.sma200
          ? 'price is above its 200-day average but the shorter averages have not lined up behind it yet'
          : 'price is below its 200-day average, so this is a counter-trend attempt rather than a trend trade')
    : 'there is not enough history to read the moving-average stack';

  return `
    ${read ? `<div class="explain-block"><div class="explain-label">Thesis</div>
      <p class="prose">${esc(read.thesis)}</p></div>` : ''}

    <div class="explain-block">
      <div class="explain-label">What the numbers say</div>
      <p class="prose">
        ${esc(m.symbol)} is in ${REGIME_LABEL[m.regime].toLowerCase()} — ${stackText}.
        It has moved ${pct(m.ret1mo, 1)} in a month and ${pct(m.ret6mo, 1)} in six, and sits
        ${plainPct(Math.abs(m.fromHigh52 ?? 0))} ${(m.fromHigh52 ?? 0) < 0 ? 'below' : 'above'} its 52-week high.
        RSI is ${m.rsi14?.toFixed(0) ?? '—'}${m.rsi14 > 70 ? ', which is stretched' : m.rsi14 < 35 ? ', which is washed out' : ', which is neither stretched nor washed out'}.
        Its average day covers ${plainPct(m.atrPct)}, which sets every distance below.
      </p>
    </div>

    <div class="explain-block">
      <div class="explain-label">How the levels were derived</div>
      <p class="prose">
        ${stopSentence(plan, m, atrMult)}
        ${targetSentence(plan, m)}
        ${plan.sizedBy === 'concentration'
          ? `Size is capped here. The risk budget of ${money(plan.riskBudget, 0)} over ${price(plan.entry - plan.stop, plan.symbol)} per unit
             would have bought a position larger than the ${plainPct(store.state.profile.maxPositionPct, 0)}
             single-position ceiling allows, so the ceiling decided instead — ${plan.shares < 1 ? plan.shares.toFixed(4) : plan.shares.toFixed(2)} units,
             a ${money(plan.cost, 0)} position risking ${money(plan.riskTaken, 0)}. A tight stop on a quiet instrument permits a
             very large position, and the concentration ceiling is what prevents it.`
          : `Size follows from the gap between entry and stop: risking ${money(plan.riskTaken, 0)} over
             ${price(plan.entry - plan.stop, plan.symbol)} per unit gives ${plan.shares < 1 ? plan.shares.toFixed(4) : plan.shares.toFixed(2)} units,
             a ${money(plan.cost, 0)} position. You choose how much to lose rather than how much to invest, and the position
             size follows from it.`}
      </p>
    </div>

    <div class="note warn"><span class="note-icon">!</span><span>
      <strong>What would end it early:</strong> a close below ${price(plan.stop, plan.symbol)}. That is the level at which
      the reason for the trade stops being true.
    </span></div>

    ${online ? '' : `<div class="note" style="font-size:12px"><span class="note-icon">›</span><span>
      This reading is generated from the metrics. The Claude analyst adds what the chart cannot show: what
       the news means, and what the basket as a whole is betting on.
    </span></div>`}`;
}

/**
 * These two describe what the engine actually did, which is not always what the
 * textbook rule would have done. Saying "the stop sits just under support" when
 * support is nowhere near it would be the exact kind of plausible-sounding
 * wrongness this app is supposed to train people out of.
 */
function stopSentence(plan, m, atrMult) {
  const ranges = atrMult ? atrMult.toFixed(1) : '—';
  const hugsSupport = m.support != null && plan.stop < m.support && m.support < plan.entry;
  const base = `The stop sits ${ranges} average daily ranges below the entry`;

  const where = hugsSupport
    ? `, just beneath support at ${price(m.support, m.symbol)} — a level price has already turned at, so a stop under it is only reached if that level fails`
    : m.support != null && m.support < plan.stop
      ? `. The nearest support is well below at ${price(m.support, m.symbol)}; waiting for that level would mean accepting a loss roughly ${((plan.entry - m.support) / (plan.entry - plan.stop)).toFixed(1)}× larger, which the risk rules will not fund`
      : `, far enough that an ordinary session will not reach it and close enough to keep the loss small`;

  const tight = plan.tightStop
    ? ' It was pulled in from the default trend distance because overhead supply caps the target, and the ratio would not otherwise clear the floor.'
    : '';
  return `${base}${where}.${tight}`;
}

function targetSentence(plan, m) {
  const r = m.resistance;
  if (r == null) {
    return `The target at ${price(plan.target, plan.symbol)} is the measured move from the same volatility unit, with no overhead supply standing in the way.`;
  }
  if (plan.target <= r) {
    return `The target at ${price(plan.target, plan.symbol)} sits just under ${price(r, plan.symbol)}, a level where earlier buyers tend to sell at break-even. Rallies stall there, so the target is set below it.`;
  }
  return `The target at ${price(plan.target, plan.symbol)} is the full measured move. There is a minor level near ${price(r, plan.symbol)}, but it sits within a couple of average days of the entry and is not treated as a ceiling in a trend this established.`;
}

function engineHeadline(plan, m) {
  if (!m) return 'Setup identified';
  const map = {
    'strong-uptrend': 'Established uptrend, entry against a defined stop',
    'uptrend': 'Uptrend intact, buying into a defined risk',
    'range': 'Range setup with the stop under support',
    'downtrend': 'Counter-trend attempt, smaller size',
    'strong-downtrend': 'Against the trend; the engine advises passing',
  };
  return map[m.regime] ?? 'Setup identified';
}

function passedList(passed) {
  return `<div class="section-head" style="margin-top:26px"><h2>Passed on</h2>
      <span class="hint">Why each instrument was refused.</span></div>
    <div class="panel scroll-x"><table>
      <thead><tr><th>Instrument</th><th>Reason</th></tr></thead>
      <tbody>${passed.map((p) => `<tr>
        <td><span class="sym-ticker" data-symbol="${esc(p.symbol)}" style="cursor:pointer">${esc(p.symbol)}</span></td>
        <td class="dim" style="font-size:12.5px">${esc(p.why)}</td></tr>`).join('')}</tbody>
    </table></div>`;
}

/* ---------------------------------------------------------------- actions */

/**
 * Starts the run, then polls for progress. The work happens server-side as a
 * background job, so a slow analyst cannot time the request out — and the poll
 * is what drives the stage indicator.
 */
async function run(host) {
  running = true;
  try {
    await api.runAnalysis(style ?? undefined);
  } catch (err) {
    running = false;
    toast(err.message, 'err', 8000);
    return renderAnalyst(host, {});
  }

  paint(host);

  for (;;) {
    await new Promise((r) => setTimeout(r, 2500));
    let snapshot;
    try {
      snapshot = await api.getAnalysis();
    } catch {
      continue; // a dropped poll is not a failed run
    }
    store.analysis = snapshot;

    if (snapshot.job?.status === 'running') {
      paint(host); // refresh the stage and the elapsed counter
      continue;
    }

    running = false;
    store.markets = null; // the board was force-refreshed server-side
    if (snapshot.job?.status === 'error') {
      toast(`The run did not finish: ${snapshot.job.error}`, 'err', 9000);
    } else {
      const passes = snapshot.passes?.join(' → ') || 'engine only';
      const secs = snapshot.job?.finishedAt && snapshot.job?.startedAt
        ? Math.round((snapshot.job.finishedAt - snapshot.job.startedAt) / 1000) : null;
      const spend = snapshot.job?.tokensSpent
        ? ` · ${snapshot.job.tokensSpent.toLocaleString('en-US')} tokens${snapshot.job.estimatedCost != null ? `, about $${snapshot.job.estimatedCost.toFixed(2)}` : ''}`
        : '';
      toast(`Analysis complete${secs ? ` in ${secs}s` : ''} (${passes})${spend}.`);
    }
    return paint(host);
  }
}

async function take(btn) {
  const sym = btn.dataset.take;
  const plan = store.analysis?.plans?.[sym];
  if (!plan) return toast('That plan is no longer in the current analysis. Run it again.', 'err');

  const equity = store.state.portfolio.equity;
  const ok = await modal({
    title: `Simulated order — ${sym}`,
    confirmText: 'Place simulated order',
    body: `
      <div class="ticket-line"><span>Buy</span><span>${plan.shares < 1 ? plan.shares.toFixed(4) : plan.shares.toFixed(2)} units ${plan.entryKind === 'pullback' ? 'on a pullback to' : 'at'} ${price(plan.entry, plan.symbol)}</span></div>
      <div class="ticket-line"><span>Position value</span><span>${money(plan.cost, 0)}</span></div>
      <div class="ticket-line"><span>Target</span><span class="up">${price(plan.target, plan.symbol)} · ${pct(plan.targetPct, 1)}</span></div>
      <div class="ticket-line"><span>Stop</span><span class="down">${price(plan.stop, plan.symbol)} · ${pct(plan.stopPct, 1)}</span></div>
      <div class="ticket-line"><span>At risk if the stop fills</span><span class="down">${money(plan.riskBudget, 0)} · ${plainPct((plan.riskBudget / equity) * 100)} of the account</span></div>
      <div class="ticket-line"><span>Reward to risk</span><span>${plan.rr.toFixed(2)}:1</span></div>
      <div class="note" style="margin-top:14px;font-size:12px"><span class="note-icon">›</span><span>
        The target and stop are attached to the position, which closes when either is touched, whether or
        not this tab is open. Simulated money; no order reaches a market.</span></div>`,
  });
  if (!ok) return;

  btn.disabled = true;
  try {
    const brief = store.analysis.briefs?.find((b) => b.symbol === sym);
    const read = store.analysis.reads?.find((r) => r.symbol === sym);
    const m = store.analysis.metrics?.[sym];
    // Store the actual reasoning, never a generic label — the journal's whole
    // value is being able to read back what you believed at the time.
    const thesis = brief?.headline ?? read?.thesis ?? (m
      ? `${engineHeadline(plan, m)} — ${REGIME_LABEL[m.regime].toLowerCase()}, engine read ${m.conviction.toFixed(0)}/100, ${plan.rr.toFixed(2)}:1 with the stop at ${price(plan.stop, plan.symbol)}.`
      : `Analyst pick at ${plan.rr.toFixed(2)}:1.`);

    await api.trade({
      action: 'buy',
      symbol: sym,
      shares: plan.shares,
      target: plan.target,
      stop: plan.stop,
      thesis,
    });
    toast(`${sym} opened with the target and stop attached. It closes when either is touched.`);
    await refreshView();
  } catch (err) {
    toast(err.message, 'err');
  } finally {
    btn.disabled = false;
  }
}
