/**
 * The "what happened while you were away" dialog.
 *
 * Paper is shut most of the time. The server replays every session it missed on
 * launch and closes anything whose stop or target was reached in the meantime —
 * which is right, because a resting stop at a real broker fires whether or not
 * you are logged in. But it means the ledger can legitimately differ from how you
 * left it, and finding that out by noticing the equity curve looks wrong is not
 * good enough. So it is stated, once, before anything else.
 *
 * Reconstructed fills are labelled as reconstructed throughout. A daily bar
 * proves a level was touched; it does not prove when, and the dialog says which
 * exits were settled by finer data and which were an assumption.
 */

import * as api from './api.js';
import { modal } from './modal.js';
import { esc, money, price, signedMoney, dateTime } from './format.js';

/* A daily bar fixes the day, not the minute. Printing a clock time next to an exit
 * the engine has just said it cannot time to the minute would undo the honesty the
 * rest of this dialog is for, so only intraday-resolved exits get one. */
const dayOnly = (ts) => new Date(ts).toLocaleDateString(undefined,
  { year: 'numeric', month: 'short', day: 'numeric' });

const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

function exitRow(x) {
  const stop = x.trigger === 'stop';
  const tone = stop ? 'down' : 'up';
  const how = x.resolution === 'intraday'
    ? 'settled against five-minute bars'
    : x.assumedStopFirst
      ? 'both legs sat in one daily bar — the stop is assumed to have gone first'
      : 'from the daily bar';
  return `
    <div class="rec-row">
      <div class="rec-row-head">
        <strong>${esc(x.symbol)}</strong>
        <span class="rec-trigger ${tone}">${stop ? 'stopped out' : 'target hit'}</span>
        <span class="rec-pnl ${x.pnl >= 0 ? 'up' : 'down'}">${signedMoney(x.pnl)}</span>
      </div>
      <div class="rec-row-detail faint">
        ${esc(x.resolution === 'intraday' ? dateTime(x.at) : dayOnly(x.at))} · ${x.shares.toFixed(2)} @ ${price(x.fill, x.symbol)}
        ${x.gapped ? ` · gapped through ${price(x.level, x.symbol)}` : ''}
        · ${esc(how)}
      </div>
    </div>`;
}

export async function showReconciliation() {
  let report = null;
  try {
    report = await api.getReconciliation();
  } catch { return false; }
  if (!report || !report.profileName) return false;

  const exits = report.exits || [];
  const flagged = report.flagged || [];
  const splits = report.splitsApplied || [];

  const lead = exits.length
    ? `While Paper was closed, ${plural(exits.length, 'position was', 'positions were')}
       closed by ${exits.length === 1 ? 'its' : 'their'} own bracket. These fills were
       rebuilt from the bars for the sessions you missed — a stop left with a broker
       fires whether or not you are logged in, so the record now says what the account
       actually did rather than what it looked like when you last had the app open.`
    : `Paper caught the account up on the sessions it was closed for. Nothing was
       triggered, but the record and the equity curve now cover that window.`;

  const body = `
    <p>${lead}</p>
    ${exits.length ? `
      <div class="rec-list">${exits.map(exitRow).join('')}</div>
      <div class="rec-total">
        Net across ${plural(exits.length, 'reconstructed exit', 'reconstructed exits')}:
        <strong class="${report.netPnl >= 0 ? 'up' : 'down'}">${signedMoney(report.netPnl)}</strong>
      </div>` : ''}
    ${splits.length ? `
      <p class="faint">Restated for ${esc(splits.join(', '))} — the feed rewrites price
      history after a split, so the entry and the bracket were divided to match before
      any level was compared.</p>` : ''}
    ${flagged.length ? `
      <div class="rec-flags">
        ${flagged.map((fl) => `<p><strong>${esc(fl.symbol)} needs a look.</strong> ${esc(fl.reason)}</p>`).join('')}
      </div>` : ''}
    ${report.contributionsPaid ? `
      <p class="faint">${plural(report.contributionsPaid, 'monthly contribution', 'monthly contributions')}
      paid in for the months that passed.</p>` : ''}
    <p class="faint">${plural(report.sessionsReplayed, 'session', 'sessions')} replayed,
    ${esc(dateTime(report.from))} to ${esc(dateTime(report.to))}. Reconstructed exits are
    marked as such in the journal and counted separately in the review.</p>`;

  await modal({
    title: exits.length ? 'While you were away' : 'Caught up',
    body,
    confirmText: 'Got it',
    // Nothing to decline: these fills already happened, and the dialog is the
    // record being stated rather than a change being proposed.
    cancelText: null,
  });
  try { await api.ackReconciliation(); } catch { /* the dialog has done its job */ }
  return true;
}
