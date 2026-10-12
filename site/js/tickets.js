/**
 * The two confirmations a manual trade goes through: closing a position, and
 * buying from the instrument drawer.
 *
 * Both used to fire on one click. Every fill is written to the ledger the
 * learning engine grades, so a misclick is not a harmless undo — it is a trade
 * on the record that nobody meant. The Analyst ticket already showed what you
 * were about to commit to; these show the same lines, from wherever the order
 * starts.
 */

import { store } from './app.js';
import { money, signedMoney, price, pct, plainPct, dir, esc, currencyOf } from './format.js';
import { modal } from './modal.js';

const units = (n) => (n < 1 ? n.toFixed(4) : n.toFixed(2));

/**
 * Dollars for an amount quoted in `symbol`'s own currency, or null when the rate
 * is not known. Null, not the unconverted number: a kronor figure printed with a
 * dollar sign is out by a factor of ten and looks exactly like a real price.
 */
export function usdOf(amount, symbol) {
  const cur = currencyOf(symbol);
  if (cur === 'USD') return amount;
  const rate = Number(store.state?.fx?.perUSD?.[cur]);
  return isFinite(rate) && rate > 0 ? amount / rate : null;
}

/** A dollar figure when the rate is known, the native one otherwise. */
const value = (nativeAmount, symbol, dp = 0) => {
  const usd = usdOf(nativeAmount, symbol);
  return usd == null ? price(nativeAmount, symbol) : money(usd, dp);
};

/** @returns {Promise<boolean>} true when the close was confirmed. */
export async function confirmClose(pos) {
  const sym = pos.symbol;
  const hasPlan = pos.stop != null || pos.target != null;
  const plan = [
    pos.stop != null ? `stop ${price(pos.stop, sym)}` : null,
    pos.target != null ? `target ${price(pos.target, sym)}` : null,
  ].filter(Boolean).join(' · ');

  const ok = await modal({
    title: `Close ${sym}`,
    confirmText: 'Close position',
    tone: 'danger',
    body: `
      <div class="ticket-line"><span>Sell</span><span>${units(pos.shares)} units at about ${price(pos.price, sym)}</span></div>
      <div class="ticket-line"><span>Position value</span><span>${money(pos.value, 0)}</span></div>
      <div class="ticket-line"><span>Open P/L</span><span class="${dir(pos.pnl)}">${signedMoney(pos.pnl)} · ${pct(pos.pnlPct)}</span></div>
      <div class="ticket-line"><span>Exit plan</span><span>${hasPlan ? plan : 'None set'}</span></div>
      <div class="note" style="margin-top:14px;font-size:12px"><span class="note-icon">›</span><span>
        Sells at the bid, a little under the last price.
        ${hasPlan ? 'Neither exit has been touched, so the journal records this as a manual exit.' : ''}</span></div>`,
  });
  return ok != null;
}

/**
 * The drawer's buy. On a setup the engine refused, the refusal is on the
 * ticket and the confirm button says in words that this overrides it; with no
 * stop, it says that too. Neither is blocked — it is your paper money — but
 * neither can happen without reading what it is.
 *
 * @returns {Promise<boolean>}
 */
export async function confirmBuy({ symbol, shares, px, target, stop, refused }) {
  const equity = store.state.portfolio.equity;
  const risk = stop != null ? usdOf((px - stop) * shares, symbol) : null;

  const confirmText = refused && stop == null ? 'Buy with no stop, against the engine'
    : refused ? 'Buy against the engine'
    : stop == null ? 'Buy without a stop'
    : 'Place simulated order';

  const ok = await modal({
    title: `Simulated order — ${symbol}`,
    confirmText,
    tone: refused || stop == null ? 'danger' : 'default',
    body: `
      ${refused ? `<div class="note warn" style="margin-bottom:12px"><span class="note-icon">!</span><span>
        <strong>The engine refused this setup.</strong> ${esc(refused)}</span></div>` : ''}
      <div class="ticket-line"><span>Buy</span><span>${units(shares)} units at about ${price(px, symbol)}</span></div>
      <div class="ticket-line"><span>Position value</span><span>${value(shares * px, symbol)}</span></div>
      <div class="ticket-line"><span>Target</span><span${target != null ? ' class="up"' : ''}>${target != null ? `${price(target, symbol)} · ${pct(((target - px) / px) * 100, 1)}` : 'None'}</span></div>
      <div class="ticket-line"><span>Stop</span><span${stop != null ? ' class="down"' : ''}>${stop != null ? `${price(stop, symbol)} · ${pct(((stop - px) / px) * 100, 1)}` : 'None'}</span></div>
      <div class="ticket-line"><span>At risk if the stop fills</span><span class="down">${stop == null
        ? 'No defined loss'
        : risk == null ? price((px - stop) * shares, symbol)
        : `${money(risk, 0)} · ${plainPct((risk / equity) * 100)} of the account`}</span></div>
      <div class="note" style="margin-top:14px;font-size:12px"><span class="note-icon">›</span><span>
        ${stop != null || target != null
          ? 'The exits are attached to the position, which closes when either is touched.'
          : 'Without a stop the position stays open until you close it.'}
        Simulated money; no order reaches a market.</span></div>`,
  });
  return ok != null;
}
