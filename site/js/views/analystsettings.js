/**
 * analystsettings.js — the key, the budget, and what a run actually cost.
 *
 * Three jobs on one panel, in the order someone meets them:
 *
 *   **The key.** Typed here, verified with one real request before it is stored,
 *   and kept in the macOS Keychain rather than in a file next to the ledgers. The
 *   key is never sent back to this screen — the field is write-only and everything
 *   that has to refer to it shows a fingerprint instead.
 *
 *   **The budget.** What one run may spend before the governor stops it. Shown
 *   with a price attached, because "400,000 tokens" means nothing and "about $2.40
 *   at this model's rates" means something.
 *
 *   **The receipt.** Where the last run's tokens went, pass by pass, and — when it
 *   ended badly — the app's own explanation of why, worked out locally.
 */

import { toast } from '../app.js';
import * as api from '../api.js';
import { esc, when } from '../format.js';
import { modal } from '../modal.js';

let panel = null;
let busy = false;

export async function loadAnalystPanel() {
  panel = await api.getAnalystPanel().catch(() => null);
  return panel;
}

export function analystPanelData() { return panel; }

export function renderAnalystSection() {
  if (!panel) {
    return `<div class="panel panel-pad"><div class="row" style="gap:10px">
      <div class="spinner"></div><span class="dim">Reading the analyst's setup…</span></div></div>`;
  }
  return `
    ${keyPanel(panel)}
    ${modelPanel(panel)}
    ${budgetPanel(panel)}
    ${lastRunPanel(panel)}
    ${checkPanel(panel.selfCheck)}`;
}

/* ------------------------------------------------------------------- the key */

function keyPanel(p) {
  const c = p.credentials;
  return `
    <div class="section-head"><h2>API key</h2>
      <span class="hint">Switches the written analysis on. Everything numeric works without it.</span></div>
    <div class="panel panel-pad">
      <div class="row wrap" style="gap:10px;margin-bottom:14px">
        <span class="chip ${c.hasKey ? 'up' : 'warn'}">${c.hasKey ? 'Analyst on' : 'Analyst off'}</span>
        ${c.fingerprint ? `<span class="chip ghost" title="A fingerprint, not the key. Enough to recognise a key you have used before.">${esc(c.fingerprint)}</span>` : ''}
        <span class="faint" style="font-size:11.5px">${esc(c.sourceLabel)}</span>
      </div>

      <p class="prose" style="font-size:12.5px;margin-bottom:14px">${esc(c.note)}</p>

      <div class="field" data-search="api key anthropic analyst credential">
        <label for="apiKeyInput">Paste a key from console.anthropic.com</label>
        <input id="apiKeyInput" type="password" autocomplete="off" spellcheck="false"
               placeholder="sk-ant-..." value="">
        <span class="faint" style="font-size:11.5px">
          Verified with one request before saving, then stored in your login Keychain — not in the data
          folder, not in a backup of your ledgers, and never written to a log.
        </span>
      </div>

      <div class="row wrap" style="gap:8px;margin-top:14px">
        <button class="btn primary sm" id="saveKeyBtn" ${busy ? 'disabled' : ''}>Verify and save</button>
        <button class="btn sm" id="testKeyBtn" ${busy || !c.hasKey ? 'disabled' : ''}>Test the key in use</button>
        ${c.removable ? '<button class="btn danger sm" id="removeKeyBtn">Remove the saved key</button>' : ''}
      </div>

      <div id="keyResult"></div>

      <div class="faint" style="font-size:11.5px;margin-top:14px;line-height:1.6">
        <strong>Where it looks, in order:</strong> the key saved here, then <code>ANTHROPIC_API_KEY</code>
        in the environment. A key saved here takes precedence over the environment variable.
      </div>
    </div>`;
}

/* ----------------------------------------------------------------- the model */

/**
 * Two pickers rather than one, because the six passes are not the same job.
 *
 * Screening reads a metric pack and emits structured JSON — mechanical, already at
 * low effort, and the pass that runs most often. Ranking a basket against someone's
 * circumstances and writing the brief that explains why a stop belongs where it is
 * are judgement, and that is what the capable model is for. Splitting them is
 * usually a better trade than moving everything down a tier.
 *
 * Both default to the most capable option. Downgrading for cost is a decision to
 * make deliberately, not one an app should make quietly on your behalf.
 */
function modelPanel(p) {
  const current = p.model;
  const fast = p.fastModel ?? '';
  const known = p.models.some((m) => m.modelId === current);
  const saving = p.relativeCost < 0.98
    ? `about ${Math.round((1 - p.relativeCost) * 100)}% less than it would on the default`
    : p.relativeCost > 1.02
      ? `about ${Math.round((p.relativeCost - 1) * 100)}% more than it would on the default`
      : 'what it would on the default';

  return `
    <div class="section-head" style="margin-top:26px"><h2>Model</h2>
      <span class="hint">Which model ranks and writes, and whether the mechanical passes run somewhere cheaper.</span></div>

    <div class="panel panel-pad">
      <div class="field" data-search="model opus sonnet haiku choose switch cheaper">
        <label>The model that ranks and writes</label>
        <div class="model-grid">
          ${p.models.filter((m) => m.suitableForJudgement).map((m) => `
            <button class="model-card ${m.modelId === current ? 'is-on' : ''}" data-model="${esc(m.modelId)}">
              <span class="model-name">${esc(m.name)}</span>
              <span class="model-price">$${m.inputPerMTok} in · $${m.outputPerMTok} out <span class="faint">per million</span></span>
              <span class="model-note">${esc(m.note)}</span>
            </button>`).join('')}
        </div>
        ${known ? '' : `<span class="faint" style="font-size:11.5px">Currently on <strong>${esc(current)}</strong>,
          set by PAPER_MODEL in the environment. Choosing here overrides it.</span>`}
      </div>

      <div class="field" style="margin-top:20px" data-search="fast model screening mechanical cheaper split">
        <label>Screening and trade notes</label>
        <div class="pill-row">
          <button class="pill ${!fast ? 'is-on' : ''}" data-fast="">Same model as above</button>
          ${p.models.filter((m) => m.modelId !== current).map((m) => `
            <button class="pill ${fast === m.modelId ? 'is-on' : ''}" data-fast="${esc(m.modelId)}">${esc(m.name)}</button>`).join('')}
        </div>
        <span class="faint" style="font-size:11.5px">
          The ${esc(p.mechanicalPasses.join(' and '))} passes read prepared evidence and emit structured
          JSON. They run most often and depend least on depth, so a cheaper model costs least here. The
          ranking, the brief, the period report and the learning pass stay on the model above.
        </span>
      </div>

      <div class="note accent" style="margin-top:16px"><span class="note-icon">›</span><span>
        As set, a run costs <strong>${esc(saving)}</strong>${p.lastRun ? ', measured from what the passes in your last run used' : ''}.
        ${p.fastModel ? 'Mixing models costs nothing in cache terms: each pass carries a different output schema and writes its own cache entry regardless. The shared cache is between repeated calls inside the screening pass, which all use one model.' : ''}
      </span></div>

      <p class="faint" style="font-size:11.5px;margin-top:12px">
        The model in force comes from ${esc(p.modelSource)}. Changing it takes effect on the next run and
        does not alter a level already on the board. If an account does not have a model enabled,
        <strong>Test the key</strong> above reports it.
      </p>
    </div>`;
}

/* ---------------------------------------------------------------- the budget */

const BUDGETS = [100_000, 250_000, 400_000, 750_000, 1_500_000];

function budgetPanel(p) {
  const l = p.limits;
  const priced = p.modelPriced;
  return `
    <div class="section-head" style="margin-top:26px"><h2>What a run may spend</h2>
      <span class="hint">Checked before every call, and able to refuse one.</span></div>
    <div class="panel panel-pad">
      <div class="field" data-search="budget tokens limit spend cost cap">
        <label>Token budget for one analysis</label>
        <div class="pill-row">
          ${BUDGETS.map((n) => `<button class="pill ${l.budgetTokens === n ? 'is-on' : ''}" data-budget="${n}">
            ${tokenLabel(n)}${priced ? ` · ~${estCost(n, p)}` : ''}</button>`).join('')}
        </div>
        <span class="faint" style="font-size:11.5px">
          ${priced
            ? `Costed at this model's published rates: $${p.inputPerMTok} per million in, $${p.outputPerMTok} per million out. A run rarely uses its whole budget, so this is the ceiling rather than the bill.`
            : 'This model has no published rate here. Token counts are exact and the cost estimate is left blank.'}
        </span>
      </div>

      <div class="grid-2" style="margin-top:18px">
        <div class="field" data-search="time limit wall clock seconds">
          <label>Time limit — ${Math.round(l.wallClockSeconds / 60)} minutes</label>
          <input type="range" data-limit="wallClockSeconds" min="60" max="1800" step="60" value="${l.wallClockSeconds}">
          <span class="faint" style="font-size:11.5px">A hung request spends no tokens but holds the run open, so time is capped separately from spend.</span>
        </div>
        <div class="field" data-search="attempts retries per pass">
          <label>Attempts per pass — ${l.attemptsPerPass}</label>
          <input type="range" data-limit="attemptsPerPass" min="1" max="4" step="1" value="${l.attemptsPerPass}">
          <span class="faint" style="font-size:11.5px">A pass that fails identically twice is stopped regardless, since a repeating failure is deterministic.</span>
        </div>
      </div>

      <div class="note accent" style="margin-top:16px"><span class="note-icon">›</span><span>
        A run that is going nowhere is also stopped: several calls in a row completing and returning
        nothing usable is billed but produces nothing, so it is counted separately and ends the
        run.</span></div>
    </div>`;
}

const tokenLabel = (n) => (n >= 1_000_000
  ? `${(n / 1_000_000).toFixed(n % 1_000_000 === 0 ? 0 : 1)}M`
  : `${(n / 1000).toFixed(0)}K`);

function estCost(tokens, p) {
  if (!p.modelPriced) return '';
  // A rough split: these runs are input-heavy, roughly four to one.
  const input = tokens * 0.8, output = tokens * 0.2;
  const usd = (input / 1e6) * p.inputPerMTok + (output / 1e6) * p.outputPerMTok;
  return `$${usd.toFixed(2)}`;
}

/* -------------------------------------------------------------- the receipt */

function lastRunPanel(p) {
  const r = p.lastRun;
  if (!r) {
    return `
      <div class="section-head" style="margin-top:26px"><h2>Last run</h2></div>
      <div class="panel"><div class="empty">
        <div class="empty-sub">No analyst run on record yet. After one has been made, this shows where
        the tokens went, pass by pass.</div></div></div>`;
  }

  const byPass = {};
  for (const c of r.calls) {
    byPass[c.pass] ??= { calls: 0, tokens: 0, ms: 0, failed: 0, model: c.model };
    const b = byPass[c.pass];
    b.model ||= c.model;
    b.calls += 1;
    b.tokens += c.inputTokens + c.outputTokens + c.cacheReadTokens + c.cacheWriteTokens;
    b.ms += c.ms;
    if (!c.ok) b.failed += 1;
  }
  const rows = Object.entries(byPass).sort((a, b) => b[1].tokens - a[1].tokens);
  const cacheRate = cacheHitRate(r);

  const models = [...new Set(r.calls.map((c) => c.model).filter(Boolean))];

  return `
    <div class="section-head" style="margin-top:26px"><h2>Last run</h2>
      <span class="hint">${esc(r.kind)} · ${esc(when(r.startedAt))}${models.length ? ` · ${esc(models.join(' + '))}` : ''}</span></div>
    <div class="panel panel-pad">
      <div class="metric-grid" style="grid-template-columns:repeat(auto-fit,minmax(104px,1fr))">
        <div class="metric"><div class="metric-label">Tokens</div>
          <div class="metric-value">${fmtInt(billed(r))}</div></div>
        <div class="metric"><div class="metric-label">Of budget</div>
          <div class="metric-value">${r.budgetTokens ? ((billed(r) / r.budgetTokens) * 100).toFixed(0) + '%' : '—'}</div></div>
        ${r.estimatedCost != null ? `<div class="metric"><div class="metric-label">Cost</div>
          <div class="metric-value">$${r.estimatedCost.toFixed(2)}</div></div>` : ''}
        <div class="metric"><div class="metric-label">Calls</div>
          <div class="metric-value">${r.calls.length}${r.calls.filter((c) => !c.ok).length ? `<span class="down" style="font-size:12px"> ${r.calls.filter((c) => !c.ok).length} failed</span>` : ''}</div></div>
        <div class="metric" title="Every pass sends the same instructions ahead of its own content, marked cacheable so it is billed once. A zero across a multi-pass run means each pass paid full price for text already sent.">
          <div class="metric-label">From cache</div>
          <div class="metric-value ${cacheRate != null && cacheRate < 1 && r.calls.length > 2 ? 'warn-text' : ''}">${cacheRate == null ? '—' : cacheRate.toFixed(0) + '%'}</div></div>
        <div class="metric"><div class="metric-label">Took</div>
          <div class="metric-value">${r.finishedAt ? Math.round((r.finishedAt - r.startedAt) / 1000) + 's' : '—'}</div></div>
      </div>

      <div class="scroll-x" style="margin-top:16px"><table>
        <thead><tr><th>Pass</th><th>Model</th><th class="right">Calls</th><th class="right">Tokens</th>
          <th class="right">Share</th><th class="right">Seconds</th></tr></thead>
        <tbody>${rows.map(([pass, b]) => `<tr>
          <td>${esc(pass)}${b.failed ? ` <span class="chip down" style="font-size:10px">${b.failed} failed</span>` : ''}</td>
          <td class="dim" style="font-size:11.5px">${esc(b.model || '—')}</td>
          <td class="right num">${b.calls}</td>
          <td class="right num">${fmtInt(b.tokens)}</td>
          <td class="right num dim">${billed(r) ? ((b.tokens / billed(r)) * 100).toFixed(0) + '%' : '—'}</td>
          <td class="right num dim">${(b.ms / 1000).toFixed(1)}</td></tr>`).join('')}</tbody>
      </table></div>

      ${r.diagnosis ? diagnosisBlock(r.diagnosis) : ''}
    </div>`;
}

const billed = (r) => r.calls.reduce((n, c) => n + c.inputTokens + c.outputTokens + c.cacheReadTokens + c.cacheWriteTokens, 0);

function cacheHitRate(r) {
  const read = r.calls.reduce((n, c) => n + c.cacheReadTokens, 0);
  const write = r.calls.reduce((n, c) => n + c.cacheWriteTokens, 0);
  const input = r.calls.reduce((n, c) => n + c.inputTokens, 0);
  const total = read + write + input;
  return total > 0 ? (read / total) * 100 : null;
}

const fmtInt = (n) => (n ?? 0).toLocaleString('en-US');

/* ------------------------------------------------------------ the diagnosis */

const SEV_TONE = { fault: 'down', warning: 'warn', note: 'ghost', ok: 'up' };
const SEV_LABEL = { fault: 'Fault', warning: 'Fix recommended', note: 'Note', ok: 'Checked' };

export function diagnosisBlock(d, { title = 'What this means' } = {}) {
  return `
    <div class="diagnosis">
      <div class="diagnosis-head">
        <span class="explain-label">${esc(title)}</span>
        <span class="spacer"></span>
        <span class="faint" style="font-size:11px">worked out locally · no API call</span>
      </div>
      <p class="prose" style="font-weight:600;color:var(--text)">${esc(d.headline)}</p>
      <p class="prose" style="font-size:12.5px">${esc(d.verdict)}</p>
      ${d.findings.map((f) => `
        <div class="finding ${SEV_TONE[f.severity] ?? 'ghost'}">
          <div class="finding-head">
            <span class="chip ${SEV_TONE[f.severity] ?? 'ghost'}">${esc(SEV_LABEL[f.severity] ?? '')}</span>
            <span class="finding-title">${esc(f.title)}</span>
          </div>
          <div class="finding-line"><span class="finding-key">Observed</span><span>${esc(f.observed)}</span></div>
          <div class="finding-line"><span class="finding-key">Means</span><span>${esc(f.meaning)}</span></div>
          ${f.fix ? `<div class="finding-line"><span class="finding-key">Do</span><span>${esc(f.fix)}</span></div>` : ''}
        </div>`).join('')}
    </div>`;
}

function checkPanel(check) {
  return `
    <div class="section-head" style="margin-top:26px"><h2>Check the setup</h2>
      <span class="hint">All of these run locally. None of them calls the API.</span></div>
    <div class="panel panel-pad">
      ${diagnosisBlock(check, { title: 'The standing checks' })}
      <button class="btn sm" id="recheckBtn" style="margin-top:12px">Run the checks again</button>
    </div>`;
}

/* ----------------------------------------------------------------- actions */

/** Wired by settings.js, which owns the host element and its repaint. */
export async function handleAnalystClick(e, repaint) {
  const model = e.target.closest('[data-model]');
  if (model) {
    try {
      await api.saveAnalystModel(model.dataset.model, panel.fastModel ?? '');
      panel = await api.getAnalystPanel();
      repaint();
      toast(`The analyst will use ${model.querySelector('.model-name')?.textContent ?? model.dataset.model} from the next run.`);
    } catch (err) { toast(err.message, 'err', 8000); }
    return true;
  }

  const fast = e.target.closest('[data-fast]');
  if (fast) {
    try {
      await api.saveAnalystModel(panel.model, fast.dataset.fast);
      panel = await api.getAnalystPanel();
      repaint();
      toast(fast.dataset.fast
        ? 'Screening and the trade notes will run on the cheaper model.'
        : 'Every pass will use the same model.');
    } catch (err) { toast(err.message, 'err', 8000); }
    return true;
  }

  const budget = e.target.closest('[data-budget]');
  if (budget) {
    const limits = { ...panel.limits, budgetTokens: Number(budget.dataset.budget) };
    try {
      panel.limits = await api.saveAnalystLimits(limits);
      repaint();
      toast('Budget saved. It applies to the next run.');
    } catch (err) { toast(err.message, 'err'); }
    return true;
  }

  if (e.target.closest('#saveKeyBtn')) {
    const input = document.querySelector('#apiKeyInput');
    const key = input?.value?.trim();
    if (!key) { toast('Paste a key first.', 'err'); return true; }
    busy = true; repaint();
    setResult('<div class="row" style="gap:10px;margin-top:12px"><div class="spinner"></div>'
      + '<span class="dim">Sending one request to check it…</span></div>');
    try {
      panel.credentials = await api.saveAnalystKey(key);
      // The field is cleared the moment it is no longer needed. There is no reason
      // for a live key to sit in a DOM node for the rest of the session.
      const field = document.querySelector('#apiKeyInput');
      if (field) field.value = '';
      panel = await api.getAnalystPanel();
      busy = false; repaint();
      toast('Key verified and saved to your Keychain. The analyst is on.');
    } catch (err) {
      busy = false; repaint();
      setResult(`<div class="note warn" style="margin-top:12px"><span class="note-icon">!</span>
        <span>${esc(err.message)}</span></div>`);
    }
    return true;
  }

  if (e.target.closest('#testKeyBtn')) {
    setResult('<div class="row" style="gap:10px;margin-top:12px"><div class="spinner"></div>'
      + '<span class="dim">One request, one token…</span></div>');
    try {
      const res = await api.testAnalystKey();
      setResult(`<div class="note ${res.ok ? 'accent' : 'warn'}" style="margin-top:12px">
        <span class="note-icon">${res.ok ? '✓' : '!'}</span><span>${esc(res.note)}</span></div>`);
    } catch (err) {
      setResult(`<div class="note warn" style="margin-top:12px"><span class="note-icon">!</span>
        <span>${esc(err.message)}</span></div>`);
    }
    return true;
  }

  if (e.target.closest('#removeKeyBtn')) {
    const ok = await modal({
      title: 'Remove the saved key?', confirmText: 'Remove it', tone: 'danger',
      body: `<p>The Keychain entry is deleted. If a key is also set in your environment,
        the analyst falls back to that one. Otherwise the written analysis
        switches off and everything numeric continues unchanged.</p>`,
    });
    if (!ok) return true;
    try {
      panel.credentials = await api.removeAnalystKey();
      panel = await api.getAnalystPanel();
      repaint();
      toast('Key removed from the Keychain.');
    } catch (err) { toast(err.message, 'err'); }
    return true;
  }

  if (e.target.closest('#recheckBtn')) {
    try {
      panel.selfCheck = await api.runSelfCheck();
      repaint();
    } catch (err) { toast(err.message, 'err'); }
    return true;
  }

  return false;
}

/** Sliders live outside the delegated click handler. */
export function wireAnalystInputs(host, repaint) {
  host.querySelectorAll('[data-limit]').forEach((el) => {
    el.addEventListener('change', async () => {
      const limits = { ...panel.limits, [el.dataset.limit]: Number(el.value) };
      try {
        panel.limits = await api.saveAnalystLimits(limits);
        repaint();
      } catch (err) { toast(err.message, 'err'); }
    });
  });
}

function setResult(html) {
  const host = document.querySelector('#keyResult');
  if (host) host.innerHTML = html;
}
