/** Paper — app shell. Owns routing, the shared state poll, and the toaster. */

import * as api from './api.js';
import { money, signedMoney, signedR, sub, homeAmount, hasHome, pct, dir, esc, price, setCurrency, currency, noteCurrencies } from './format.js';
import { setPlainLanguage } from './glossary.js';
import { renderDesk } from './views/desk.js';
import { renderMarkets } from './views/markets.js';
import { renderAnalyst, setAnalystSection } from './views/analyst.js';
import { renderJournal } from './views/journal.js';
import { renderLearn } from './views/learn.js';
import { renderProfile } from './views/profile.js';
import { renderLearning } from './views/learning.js';
import { renderSession } from './views/session.js';
import { renderPredict } from './views/predict.js';
import { renderDiagnostics } from './views/diagnostics.js';
import { renderStart, restartSetup } from './views/start.js';
import { renderSettings, resetDraft, state as settingsState } from './settings.js';
import { openDetail } from './detail.js';
import { showReconciliation } from './reconcile.js';
import { initTooltips } from './tooltip.js';
import { morph, clearMorph } from './morph.js';

const VIEWS = {
  desk: renderDesk, markets: renderMarkets, analyst: renderAnalyst,
  journal: renderJournal, profile: renderProfile, learn: renderLearn,
  learning: renderLearning, start: renderStart, session: renderSession,
  predict: renderPredict, diagnostics: renderDiagnostics,
};

export const store = {
  state: null,
  markets: null,
  analysis: null,
  review: null,
  memory: null,
  view: 'desk',
};

const main = document.getElementById('main');
const boot = document.getElementById('boot');

/* --------------------------------------------------------------- toasts */

export function toast(message, kind = 'ok', ms = 4200) {
  const host = document.getElementById('toasts');
  const node = document.createElement('div');
  node.className = `toast ${kind}`;
  node.innerHTML = `<span>${esc(message)}</span>`;
  host.append(node);
  setTimeout(() => {
    node.classList.add('is-out');
    setTimeout(() => node.remove(), 240);
  }, ms);
}

/* ---------------------------------------------------------------- header */

/* A ledger the server refused to write to. Loud, permanent while it lasts, and
 * never dismissable: the balance on screen is not this account's balance, and the
 * only safe action is to stop trading on it until the file is sorted out. */
function paintLedgerAlarm() {
  const host = document.getElementById('ledgerAlarm');
  if (!host) return;
  const message = store.state?.ledgerError;
  host.hidden = !message;
  if (!message) return;
  host.innerHTML = `
    <strong>This account is read-only.</strong>
    <span>${esc(message)}</span>
    <span class="faint">Nothing you do here will be saved. The numbers shown are not
    this account's real balance — do not trade on it until the file is restored.</span>`;
}

/* ------------------------------------------------------------ reading mode */

/**
 * Where this account opens and how much it explains. The catalog rides on the
 * state response rather than being kept here, so the interface and the engine
 * cannot hold different ideas of what a mode does.
 */
export function mode() {
  const all = store.state?.readingModes ?? [];
  const id = store.state?.profile?.readingMode;
  return all.find((m) => m.id === id)
    ?? all[0]
    ?? { id: 'dense', label: 'Desk', landing: 'desk', landingSection: null,
         explains: false, analystTabLabel: 'Analyst' };
}

/* The analyst tab holds ideas and the review of closed trades. One mode goes
 * there for the second, so the tab is named for what it is being opened for. */
function paintTabs() {
  const tab = document.querySelector('.tab[data-view="analyst"]');
  if (!tab) return;
  const label = mode().analystTabLabel;
  if (tab.textContent.trim() === label) return;
  tab.textContent = label;
  moveInk();
}

function paintHeader() {
  const s = store.state;
  if (!s) return;
  paintLedgerAlarm();
  paintTabs();
  const p = s.portfolio;

  document.getElementById('tk-equity').textContent = money(p.equity);
  const pnl = document.getElementById('tk-pnl');
  pnl.textContent = `${signedMoney(p.totalPnl)}  ${pct(p.totalPnlPct)}`;
  pnl.className = `ticker-value ${dir(p.totalPnl)}`;
  document.getElementById('tk-cash').textContent = money(p.cash);
  paintTickerSubs(p);

  paintFreshness();

  paintAccount();

  paintCurrency();
  paintLearningBadge();
  paintSessionBadge();

  /* Three markets, not two. Stockholm is its own read: a Swedish industrial
   * running while US tech stalls is an ordinary quarter, and one averaged figure
   * across both would show a flat market on a day with two clear trends in it.
   * Only markets this profile actually trades are shown. */
  const traded = new Set(s.profile?.markets?.length ? s.profile.markets : ['us', 'stockholm', 'crypto']);
  const reads = [
    ['us', s.regimes.stocks],
    ['stockholm', s.regimes.sweden],
    ['crypto', s.regimes.crypto],
  ].filter(([venue, r]) => r && traded.has(venue));

  morph(document.getElementById('regimes'), reads
    .map(([venue, r]) => `<span class="regime-pill" tabindex="0" data-r="${esc(r.label)}" title="${esc(r.detail)}">
      <span class="regime-dot"></span><span class="regime-what">${esc(r.what ?? r.headline)}</span><span class="regime-short">${esc(REGIME_SHORT[venue] ?? '')}</span><span class="regime-state">${esc(r.state ? `: ${r.state}` : '')}</span>
    </span>`).join(''));

  paintClocks();
  fitTopbar();
}

/* The ticker symbol for each read, for the width where the strip has room for a
 * name but not for the full one. "BTC" rather than "Crypto" because the crypto
 * read is measured off Bitcoin, which is what the hover text says too. */
const REGIME_SHORT = { us: 'US', stockholm: 'STO', crypto: 'BTC' };

/* Only Stockholm has anything to give up here — `Venue.label` is already "US". */
const CLOCK_SHORT = { us: 'US', stockholm: 'STO' };

/**
 * What the header gives up, and in what order.
 *
 * Read top to bottom, each row is less than the one above it. The regime strip
 * spends everything it has before the clocks give up their first word, because a
 * clock answers a question with a consequence — whether an order placed now can
 * fill — and the regime read is also on the Analyst tab in full. Nothing here
 * ever drops a market: the last rows still carry one dot per market and one per
 * exchange, each with its whole sentence on hover. The exchange rate goes last
 * and goes entirely, because it is the one line here that can be worked out from
 * two other numbers on the same screen.
 */
const FIT_LADDER = [
  ['full',    'full',  'all'],
  ['compact', 'full',  'all'],
  ['mini',    'full',  'all'],
  ['dots',    'full',  'all'],
  ['dots',    'short', 'all'],
  ['none',    'short', 'all'],
  ['none',    'dots',  'all'],
  ['none',    'dots',  'nofx'],
];

/**
 * Decide how much the regime strip may say, by measuring it.
 *
 * The room this strip has is whatever the rest of the header does not want, and
 * that is not a function of the window width: an account called "Learning the
 * ropes" is three times the width of one called "Main", a profile reading in
 * kronor carries a conversion under every figure in the ticker, and the session
 * badge is there or not depending on whether a run is live. The breakpoints this
 * replaces guessed at 1240px and 1080px and were wrong in both directions — at
 * 1400px the strip was being handed 89px for 454px of pills, which it hung
 * outside its own box and painted across the clocks, the exchange rate and the
 * freshness dot.
 *
 * So it is asked rather than guessed. Each level is applied and then measured:
 * reading `scrollWidth` flushes the layout the assignment just invalidated, so
 * the comparison on the next line is against the strip as it now really is. The
 * first level that fits wins, and the loop is at most five iterations of
 * arithmetic the browser has already done.
 */
function fitTopbar() {
  const right = document.querySelector('.topbar-right');
  const strip = document.getElementById('regimes');
  if (!right || !strip) return;

  /* Two questions, because there are two ways this row runs out of room and only
   * the second one is visible from the outside. A strip squeezed narrower than
   * its own pills reports a healthy parent and hangs its content over the clocks;
   * a group whose items have all stopped shrinking reports a healthy strip and
   * hangs the settings button off the end of the bar. Neither is acceptable, so
   * both are asked. */
  const tight = () => strip.scrollWidth > strip.clientWidth + 1
                   || right.scrollWidth > right.clientWidth + 1;

  for (const [regimes, clocks, extras] of FIT_LADDER) {
    strip.dataset.fit = regimes;
    right.dataset.clocks = clocks;
    right.dataset.extras = extras;
    if (!tight()) return;
  }
  // The last row of the ladder stands whether it fits or not — there is nothing
  // narrower to offer, and the media queries below 900px take it from here.
}

/**
 * One chip per exchange, saying whether it is trading.
 *
 * Worth its space now that the board spans two of them six and a half hours
 * apart. "The market is closed" was an unambiguous sentence when there was one
 * market; with two it is the question rather than the answer, and a Swedish
 * morning is precisely the window where the old single badge was wrong.
 */
function paintClocks() {
  const host = document.getElementById('clocks');
  const clocks = store.state?.session?.clocks ?? [];
  if (!host) return;
  if (clocks.length < 2) { morph(host, ''); return; }
  morph(host, clocks.map((c) => `
    <span class="clock-pill" data-open="${c.open ? '1' : '0'}" title="${esc(c.note)}">
      <span class="clock-dot"></span><span class="clock-name">${esc(c.label)}</span><span class="clock-short">${esc(CLOCK_SHORT[c.venue] ?? c.label.slice(0, 3))}</span>
    </span>`).join(''));
}

/** The account switcher. Each profile is a separate ledger, so this is a real
 *  switch of accounts rather than a change of view. */
function paintAccount() {
  const host = document.getElementById('account');
  const s = store.state;
  if (!host || !s) return;
  // An open menu is a menu being read. The poll behind this fires every thirty
  // seconds and its only news here is a changed equity figure, which can wait.
  if (document.getElementById('accountMenu')?.hidden === false) return;
  morph(host, `
    <button class="account-btn" id="accountBtn" title="Switch account">
      <span class="account-name">${esc(s.profile.name)}</span>
      <span class="account-sub">${esc(s.profile.horizon.split(' —')[0])} · ${money(s.portfolio.equity, 0)}</span>
      <svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.4"
           stroke-linecap="round"><path d="M6 9l6 6 6-6"/></svg>
    </button>
    <div class="account-menu" id="accountMenu" hidden>
      ${s.profiles.map((x) => `
        <button class="account-item ${x.active ? 'is-on' : ''}" data-switch="${esc(x.id)}">
          <span class="account-item-name">${esc(x.name)}</span>
          <span class="account-item-meta">${money(x.equity, 0)} · ${x.openPositions} open ·
            <span class="${x.totalPnlPct >= 0 ? 'up' : 'down'}">${x.totalPnlPct >= 0 ? '+' : ''}${x.totalPnlPct.toFixed(1)}%</span></span>
        </button>`).join('')}
      <button class="account-item account-manage" data-switch-manage>Manage accounts…</button>
    </div>`);
}

/**
 * The second line under each headline figure — the same dollars, read in the
 * currency the profile thinks in.
 *
 * The P/L one is signed off the dollar amount rather than the converted one, so a
 * loss reads as a loss in both. Rounding to whole units is deliberate: this is the
 * "what is that in real money" glance, and öre in it would only invite the wrong
 * kind of precision about a figure that moves with the rate anyway.
 */
function paintTickerSubs(p) {
  const on = hasHome();
  const put = (id, amount, prefix = '') => {
    const el = document.getElementById(id);
    if (!el) return;
    const text = on ? homeAmount(amount, 0) : '';
    el.hidden = !text;
    el.textContent = text ? `≈ ${prefix}${text}` : '';
  };
  put('tk-equity-sub', p.equity);
  put('tk-pnl-sub', Math.abs(p.totalPnl), p.totalPnl >= 0 ? '+' : '−');
  put('tk-cash-sub', p.cash);
}

/**
 * The rate, stated wherever a converted figure appears. A converted number whose
 * rate is unknown is a wrong number, not a slightly old one — and since the second
 * figure is only ever a translation, the chip has to say so rather than let it
 * read as a balance the account holds.
 */
function paintCurrency() {
  const el = document.getElementById('fxNote');
  const s = store.state;
  if (!el || !s) return;
  const cur = currency();
  if (cur.code === 'USD') { el.hidden = true; return; }
  el.hidden = false;
  el.dataset.stale = cur.live ? '0' : '1';
  el.textContent = `${cur.code} @ ${cur.rate.toFixed(2)}`;
  el.title = s.fx?.live === false
    ? `The account trades and settles in dollars. The smaller ${cur.code} figures are converted at a standing estimate of ${cur.rate.toFixed(4)} per USD, because the rate feed is unreachable.`
    : `The account trades and settles in dollars. The smaller ${cur.code} figures are converted at ${cur.rate.toFixed(4)} per USD, live. They are a reading aid — no order is ever placed in ${cur.code}.`;
}

/**
 * A running session has a clock and a loss limit, and neither of them cares which
 * tab is open — so the state of it lives in the top bar rather than only on its
 * own screen.
 */
function paintSessionBadge() {
  const host = document.getElementById('sessionBadge');
  const live = store.state?.liveSession;
  if (!host) return;
  if (!live || live.status !== 'running') { host.hidden = true; return; }
  host.hidden = false;
  const mins = Math.max(0, Math.round(live.secondsLeft / 60));
  host.dataset.tone = live.total < 0 ? 'down' : live.total > 0 ? 'up' : 'flat';
  const homeTotal = homeAmount(Math.abs(live.total), 0);
  morph(host, `<span class="session-dot"></span>
    <span>Session · ${mins}m · ${live.total >= 0 ? '+' : '−'}${money(Math.abs(live.total), 0).replace(/^[-−]/, '')}</span>`);
  host.title = `${live.tradesTaken} of ${live.maxTrades} trades taken. `
    + `The session ends if it is ${money(live.lossLimit, 0)} down or ${money(live.targetAmount, 0)} up.`
    + (homeTotal ? ` Currently ${live.total >= 0 ? 'up' : 'down'} about ${homeTotal}.` : '');
}

/** A count of proposed changes, so a finding is never sitting in a tab nobody opens. */
function paintLearningBadge() {
  const tab = document.querySelector('.tab[data-view="learning"]');
  const gear = document.getElementById('settingsBtn');
  const n = store.state?.learning?.proposed ?? 0;
  if (tab) {
    tab.dataset.badge = n > 0 ? String(n) : '';
    tab.classList.toggle('has-badge', n > 0);
  }
  if (gear) gear.classList.toggle('has-dot', n > 0);
}

/**
 * How old the newest quote on the board is. Shown rather than hidden, because
 * "is this live?" is the first question anyone asks of a trading screen, and the
 * honest answer here is "within a minute, usually within seconds" — the feed is
 * free and edge-cached, so claiming tick accuracy would be a lie.
 */
function paintFreshness() {
  const el = document.getElementById('freshness');
  const text = document.getElementById('freshnessText');
  if (!el || !text || !store.state?.pricesAt) return;

  const secs = Math.max(0, Math.round((Date.now() - store.state.pricesAt) / 1000));
  el.dataset.stale = secs < 90 ? '0' : secs < 600 ? '1' : '2';
  text.textContent =
    secs < 75 ? `live · ${secs}s` :
    secs < 3600 ? `${Math.round(secs / 60)}m old` :
    `${Math.round(secs / 3600)}h old`;
}

/* ---------------------------------------------------------------- router */

function moveInk() {
  const active = document.querySelector('.tab.is-active');
  const ink = document.getElementById('tabInk');
  if (!active) return;
  ink.style.width = `${active.offsetWidth}px`;
  ink.style.transform = `translateX(${active.offsetLeft - 20}px)`;
}

export async function go(view, { force = false } = {}) {
  if (!VIEWS[view]) view = 'desk';
  const changed = store.view !== view;
  store.view = view;

  // The guided setup is a full-screen takeover with no tab of its own — it is a
  // thing you are doing, not a place you are.
  const isSetup = view === 'start';
  document.getElementById('tabs').classList.toggle('is-hidden', isSetup);
  document.body.classList.toggle('in-setup', isSetup);

  document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('is-active', t.dataset.view === view));
  moveInk();
  if (changed) {
    /* Views patch themselves in place now, which is only ever right against their
     * own previous draw. Arriving from another screen, the slate is cleared so the
     * new one is built rather than reconciled against something unrelated. */
    main.innerHTML = '';
    clearMorph(main);
    history.replaceState(null, '', `#${view}`);
    // A new view starts at its own top. Arriving halfway down a screen you have
    // never seen, because the last one was longer, reads as a broken page.
    window.scrollTo({ top: 0, behavior: 'instant' });
  }

  await VIEWS[view](main, { force });
}

/** Re-renders the current view in place after a trade or a data change. */
export async function refreshView() {
  await loadState();
  paintHeader();
  await VIEWS[store.view](main, { force: false });
}

async function loadState(force = false) {
  store.state = await api.getState(force);
  // Both of these change how every subsequent render reads, so they are applied
  // before anything paints rather than being passed down through each view.
  setCurrency(store.state.currency, store.state.fx);
  // What each held instrument is quoted in, so a kronor stop is never drawn with
  // a dollar sign. The markets tab tops this up with the rest of the board.
  noteCurrencies(store.state.portfolio?.positions);
  setPlainLanguage(store.state.profile?.plainLanguage !== false);
  return store.state;
}

/* -------------------------------------------------------- the settings sheet */

/**
 * Settings, from anywhere. The same module that renders the Profile tab renders
 * into this sheet, so there is exactly one implementation of every control and
 * the two can never disagree about what the engine is using.
 */
export function openSettings(section) {
  const sheet = document.getElementById('settingsSheet');
  const scrim = document.getElementById('settingsScrim');
  if (!sheet || !scrim) return;
  if (section) settingsState.section = section;
  scrim.hidden = false;
  sheet.hidden = false;
  // Rendered into a mount inside the sheet: the close button has to survive a
  // repaint, and renderSettings owns its host's innerHTML.
  renderSettings(document.getElementById('settingsMount'), { mode: 'sheet' });
  sheet.querySelector('#settingsSearch')?.focus();
}

export function closeSettings() {
  const sheet = document.getElementById('settingsSheet');
  const scrim = document.getElementById('settingsScrim');
  if (!sheet || !scrim) return;
  sheet.hidden = true;
  scrim.hidden = true;
  // The Profile tab shares the draft, so it has to redraw with whatever changed.
  if (store.view === 'profile') VIEWS.profile(main, {});
}

export function isSettingsOpen() {
  return !document.getElementById('settingsSheet')?.hidden;
}

/* ------------------------------------------------------------------ boot */

document.getElementById('tabs').addEventListener('click', (e) => {
  const tab = e.target.closest('.tab');
  if (tab) go(tab.dataset.view);
});

document.getElementById('refresh').addEventListener('click', async (e) => {
  const btn = e.currentTarget;
  btn.classList.add('is-spinning');
  try {
    store.markets = null;
    store.memory = null;
    await loadState(true);
    paintHeader();
    await VIEWS[store.view](main, { force: true });
    toast('Market data refreshed.');
  } catch (err) {
    toast(err.message, 'err');
  } finally {
    btn.classList.remove('is-spinning');
  }
});

document.addEventListener('click', async (e) => {
  const menu = document.getElementById('accountMenu');
  if (e.target.closest('#accountBtn')) {
    if (menu) menu.hidden = !menu.hidden;
    return;
  }
  const pick = e.target.closest('[data-switch]');
  if (pick) {
    if (menu) menu.hidden = true;
    try {
      await api.activateProfile(pick.dataset.switch);
      // Every cached view belongs to the account that was open a moment ago.
      store.markets = null; store.analysis = null; store.review = null; store.memory = null;
      resetDraft();
      await refreshView();
      if (isSettingsOpen()) openSettings();
      toast('Switched account.');
    } catch (err) { toast(err.message, 'err'); }
    return;
  }
  if (e.target.closest('[data-switch-manage]')) {
    if (menu) menu.hidden = true;
    return openSettings('accounts');
  }
  if (menu && !e.target.closest('#account')) menu.hidden = true;
});

// Any element carrying data-symbol opens the instrument drawer.
document.addEventListener('click', (e) => {
  const t = e.target.closest('[data-symbol]');
  if (t && !e.target.closest('button, a')) openDetail(t.dataset.symbol);
});

document.getElementById('settingsBtn')?.addEventListener('click', () => {
  isSettingsOpen() ? closeSettings() : openSettings();
});
document.getElementById('settingsScrim')?.addEventListener('click', closeSettings);
document.getElementById('settingsClose')?.addEventListener('click', closeSettings);

// Anything anywhere can send you to a view or into settings.
document.addEventListener('click', (e) => {
  const goto = e.target.closest('[data-goto]');
  if (goto) {
    closeSettings();
    return go(goto.dataset.goto);
  }
  const opens = e.target.closest('[data-settings]');
  if (opens) return openSettings(opens.dataset.settings || undefined);
  if (e.target.closest('[data-start-setup]')) {
    closeSettings();
    restartSetup();
    return go('start');
  }
});

window.addEventListener('resize', () => { moveInk(); fitTopbar(); });
window.addEventListener('keydown', (e) => {
  // ⌘, is the settings shortcut everywhere on this platform, and the menu bar
  // claims it too — so the page has to answer it whether or not the menu fired.
  if (e.key === ',' && (e.metaKey || e.ctrlKey)) {
    e.preventDefault();
    return isSettingsOpen() ? closeSettings() : openSettings();
  }
  if (e.key === 'Escape') {
    if (isSettingsOpen()) return closeSettings();
    document.getElementById('scrim')?.click();
  }
});

(async function start() {
  // Bound before anything renders: every view writes `title` attributes as it
  // goes, and the tooltip claims them lazily on first hover.
  initTooltips();
  try {
    await loadState();
  } catch (err) {
    boot.innerHTML = `<div class="boot-mark">Paper</div>
      <div class="boot-sub">Could not reach the server.<br>${esc(err.message)}</div>`;
    return;
  }

  paintHeader();
  document.getElementById('topbar').hidden = false;
  document.getElementById('tabs').hidden = false;
  main.hidden = false;
  boot.classList.add('is-gone');
  setTimeout(() => boot.remove(), 340);

  // A first run opens on the first question rather than on a desk full of numbers
  // that mean nothing yet. Skipping is one click and it is remembered.
  const requested = location.hash.slice(1);
  if (!requested && store.state.hasOnboarded) {
    const m = mode();
    if (m.landingSection) setAnalystSection(m.landingSection);
    await go(m.landing);
  } else {
    await go(requested || (store.state.hasOnboarded ? 'desk' : 'start'));
  }
  requestAnimationFrame(moveInk);

  /* If brackets fired while the app was shut, say so before anything else. The
   * alternative is the principal working out from a changed equity curve that
   * positions they left open are gone, which is the one way an honest catch-up
   * could still read as the app quietly doing things behind their back. Skipped
   * during setup, where there is no account to reconcile yet. */
  if (store.state.hasOnboarded) {
    try {
      if (await showReconciliation()) { store.review = null; await loadState(); paintHeader(); }
    } catch { /* never block the desk on the catch-up notice */ }
  }

  // Quiet background poll. Brackets are swept server-side on each board refresh,
  // so this is also what makes a target or stop fire while the tab sits open.
  // The age counter ticks locally every second so the readout is never itself stale.
  setInterval(paintFreshness, 1000);

  setInterval(async () => {
    if (document.hidden) return;
    try {
      const before = store.state?.trades?.[0]?.id;
      await loadState();
      paintHeader();
      const after = store.state?.trades?.[0]?.id;
      if (after && after !== before) {
        const t = store.state.trades[0];
        if (t.trigger === 'target' || t.trigger === 'stop') {
          // `Trade.price` is the fill in the instrument's OWN currency — a
          // Stockholm stop fills in kronor — while `pnl` is in the dollars the
          // ledger settles in. Printing the fill with a dollar sign is the exact
          // two-currencies-for-one-quantity bug Currency.swift exists to prevent.
          // A stop filling is the plan working, not something going wrong. It
          // arrives in the neutral voice, with the loss measured in the R the
          // plan set out to risk.
          const r = t.rMultiple != null ? `, ${signedR(t.rMultiple)}` : t.pnl != null ? `, ${signedMoney(t.pnl)}` : '';
          toast(`${t.symbol}: ${t.trigger} filled at ${price(t.price, t.symbol)}${r} — closed as planned.`, t.trigger === 'target' ? 'ok' : 'info', 8000);
        }
        // A bracket firing changes the record, so the journal and the review both
        // need redrawing.
        store.review = null;
        if (store.view === 'journal') await VIEWS.journal(main, {});
      }

      // Both of these price every row they show, so they redraw on every poll —
      // otherwise the header ticks while the P/L underneath it sits frozen.
      if (store.view === 'desk') await VIEWS.desk(main, {});
      if (store.view === 'markets') {
        store.markets = null; // the view caches its rows; prices have moved
        await VIEWS.markets(main, {});
      }
    } catch { /* a dropped poll is not worth a toast */ }
  }, 30_000);
})();
