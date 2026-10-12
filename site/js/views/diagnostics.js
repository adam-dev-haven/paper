/**
 * diagnostics.js — what the app has been saying to itself.
 *
 * Paper writes a running commentary: prices it could not reach and fell back on,
 * brackets it fired while nobody was looking, sessions it replayed, ledgers it
 * refused to write. All of it went to standard error, which in a bundled `.app`
 * launched from Finder goes nowhere anyone reads. So the commentary existed and
 * the record did not, and every question that starts "why did this position
 * close" had to be answered from the ledger alone — which is the thing being
 * questioned.
 *
 * This is that record, in the app. Two things share the screen on purpose:
 *
 *   The **alarms** at the top: accounts whose file could not be read and have
 *     therefore gone read-only, and learning memories in the same state. Those
 *     are the failures that look like nothing — a desk showing a plausible
 *     balance that is not this account's, or a calibration that reads as "nothing
 *     learned yet" because the lessons are sitting in a file that will not parse.
 *
 *   The **log** underneath, filtered by level and subsystem, because "why is the
 *     price stale" and "why did this trade close" are different investigations
 *     through the same stream.
 *
 * Nothing here is live-polled. A diagnostic that repaints under you while you are
 * reading it is harder to use than one with a refresh button.
 */

import * as api from '../api.js';
import { esc } from '../format.js';

let level = 'debug';
let subsystem = '';

const LEVEL_LABEL = {
  debug: 'Everything',
  info: 'Notes and above',
  warn: 'Warnings and above',
  error: 'Errors only',
};

export async function renderDiagnostics(host) {
  host.innerHTML = `<section class="view"><div class="panel"><div class="empty">
    <div class="spinner"></div><div class="empty-sub">Reading the log…</div>
  </div></div></section>`;

  let data;
  try {
    data = await api.getLogs({ level, subsystem });
  } catch (err) {
    host.innerHTML = `<section class="view"><div class="note warn">
      <span class="note-icon">›</span><span>${esc(err.message)}</span></div></section>`;
    return;
  }

  const tally = data.tally ?? {};
  const errors = tally.error ?? 0;
  const warnings = tally.warn ?? 0;

  host.innerHTML = `
    <section class="view">
      <div class="section-head">
        <h2>Diagnostics</h2>
        <span class="hint">What the app has been saying to itself since it started.</span>
        <span class="spacer"></span>
        <button class="btn sm" data-reload-log>Refresh</button>
      </div>

      ${alarms(data)}

      <div class="panel" style="margin-bottom:14px;padding:0">
        <div class="stat-grid">
          <div class="stat">
            <span class="stat-label">Errors this run</span>
            <span class="stat-value ${errors ? 'down' : ''}">${errors}</span>
          </div>
          <div class="stat">
            <span class="stat-label">Warnings</span>
            <span class="stat-value ${warnings ? 'warn-text' : ''}">${warnings}</span>
          </div>
          <div class="stat">
            <span class="stat-label">Kept on disk</span>
            <span class="stat-value">${data.retainDays}d · ${(data.files ?? []).length} file${(data.files ?? []).length === 1 ? '' : 's'}</span>
          </div>
        </div>
        <div style="padding:13px 15px;border-top:1px solid var(--line)">
          <div class="stat-label" style="margin-bottom:4px">Written to</div>
          <div style="font-size:11.5px;font-family:var(--mono);color:var(--text-dim);word-break:break-all">${esc(data.directory ?? '')}</div>
          <p class="faint" style="font-size:11.5px;line-height:1.6;margin:10px 0 0">
            One file a day, alongside the ledgers, so <code>PAPER_DATA_DIR</code> moves the log
            with the accounts it describes. The list below is this run; the files hold the rest.
          </p>
        </div>
      </div>

      <div class="row wrap" style="gap:10px;margin-bottom:12px">
        <select class="btn sm" data-log-level style="width:auto">
          ${(data.levels ?? []).map((l) => `<option value="${esc(l)}"${l === level ? ' selected' : ''}>${esc(LEVEL_LABEL[l] ?? l)}</option>`).join('')}
        </select>
        <select class="btn sm" data-log-subsystem style="width:auto">
          <option value=""${subsystem === '' ? ' selected' : ''}>Every subsystem</option>
          ${(data.subsystems ?? []).map((s) => `<option value="${esc(s)}"${s === subsystem ? ' selected' : ''}>${esc(s)}</option>`).join('')}
        </select>
        <span class="spacer"></span>
        <span class="hint">Recording</span>
        <select class="btn sm" data-log-threshold style="width:auto"
                title="Lower this to record more. Takes effect immediately; no rebuild, no relaunch.">
          ${(data.levels ?? []).map((l) => `<option value="${esc(l)}"${l === data.threshold ? ' selected' : ''}>${esc(l)} and above</option>`).join('')}
        </select>
      </div>

      ${(data.entries ?? []).length === 0 ? nothing() : table(data.entries)}
    </section>`;

  host.querySelector('[data-reload-log]').onclick = () => renderDiagnostics(host);
  host.querySelector('[data-log-level]').onchange = (e) => {
    level = e.target.value;
    renderDiagnostics(host);
  };
  host.querySelector('[data-log-subsystem]').onchange = (e) => {
    subsystem = e.target.value;
    renderDiagnostics(host);
  };
  host.querySelector('[data-log-threshold]').onchange = async (e) => {
    await api.setLogLevel(e.target.value);
    renderDiagnostics(host);
  };
}

/**
 * The two failures that are quiet rather than loud.
 *
 * Both mean a file exists, could not be read, and is now deliberately not being
 * written — which is the right behaviour and completely invisible from any other
 * screen. A ledger in this state shows a balance that is not the account's; a
 * memory in this state reads as a desk that has never learned anything.
 */
function alarms(data) {
  const ledgers = data.ledgerErrors ?? [];
  const memories = data.memoryErrors ?? [];
  if (!ledgers.length && !memories.length) return '';
  const row = (x, what) => `
    <div class="note warn" style="margin-bottom:8px">
      <span class="note-icon">!</span>
      <span><strong>${esc(x.profile)} — ${what} is read-only.</strong> ${esc(x.error)}</span>
    </div>`;
  return `<div style="margin-bottom:18px">
    ${ledgers.map((x) => row(x, 'the ledger')).join('')}
    ${memories.map((x) => row(x, 'the learning memory')).join('')}
  </div>`;
}

function nothing() {
  return `<div class="panel"><div class="empty">
    <div class="empty-title">Nothing at this level</div>
    <div class="empty-sub">A quiet log is the good outcome. Widen the filter to see the routine notes.</div>
  </div></div>`;
}

function table(entries) {
  return `<div class="panel scroll-x"><table>
    <thead><tr>
      <th style="width:96px">Time</th><th style="width:70px">Level</th>
      <th style="width:100px">Subsystem</th><th>Message</th>
    </tr></thead>
    <tbody>${entries.map((e) => `<tr>
      <td class="faint" style="white-space:nowrap;font-size:12px;font-family:var(--mono)">${esc(clock(e.at))}</td>
      <td><span class="chip ${toneFor(e.level)}" style="font-size:10.5px">${esc(e.level)}</span></td>
      <td class="faint" style="font-size:12px;font-family:var(--mono)">${esc(e.subsystem)}</td>
      <td style="font-size:12.5px;line-height:1.5">${esc(e.message)}</td>
    </tr>`).join('')}</tbody>
  </table></div>`;
}

const toneFor = (l) => (l === 'error' ? 'down' : l === 'warn' ? 'ghost warn-text' : 'ghost');

/** Time only — the date is the file's job, and every row here is from today. */
function clock(ms) {
  const d = new Date(ms);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}
