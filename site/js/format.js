/**
 * Formatting. Money is always signed where a sign carries meaning.
 *
 * There is **one** currency for *money* in this interface and it is dollars. The
 * ledger is in dollars, the cash is in dollars, the entry fields are in dollars,
 * and every sentence the app writes about an amount is in dollars.
 *
 * **Prices are the exception, and the only one.** An instrument is quoted in
 * whatever its exchange quotes it in: a Stockholm listing is kronor, and its
 * entry, stop and target are kronor, because that is what an order there would
 * carry. Drawing a 337 kr stop as "$337" is not a formatting slip — it is a level
 * a hundredfold away from anything that exists. So `money()` is always dollars and
 * `price()` asks the symbol. Those are the two rules, and there is no third.
 *
 * That rule replaced a two-currency arrangement that converted account figures
 * into the profile's currency while leaving prices in dollars. It was coherent on
 * paper and wrong in practice: every figure composed on the Swift side spoke
 * through a formatter that hardcoded a dollar sign, so an account set to kronor
 * showed `104 600 kr` of equity in the header and quoted a `$500` session limit
 * four lines below it. Both numbers were right about different quantities, which
 * is the least useful thing two numbers can be. One unit removes the entire class
 * of bug rather than fixing the instances of it.
 *
 * What the reading currency buys instead is `home()` — a **second, smaller figure**
 * printed beside the dollar one on the amounts worth translating: equity, cash,
 * the day's profit, what a trade puts at risk, what a session may lose. It is a
 * companion, never a substitute, and it is styled small and dim so which of the
 * two is the real number is never in question.
 */

/* The reading currency, set once from the app state on every poll. */
const CURRENCIES = {
  USD: { symbol: '$', trails: false, locale: 'en-US', dp: 2 },
  EUR: { symbol: '€', trails: false, locale: 'de-DE', dp: 2 },
  SEK: { symbol: 'kr', trails: true, locale: 'sv-SE', dp: 2 },
  GBP: { symbol: '£', trails: false, locale: 'en-GB', dp: 2 },
  NOK: { symbol: 'kr', trails: true, locale: 'nb-NO', dp: 2 },
  DKK: { symbol: 'kr', trails: true, locale: 'da-DK', dp: 2 },
  CHF: { symbol: 'CHF', trails: true, locale: 'de-CH', dp: 2 },
  CAD: { symbol: 'C$', trails: false, locale: 'en-CA', dp: 2 },
  AUD: { symbol: 'A$', trails: false, locale: 'en-AU', dp: 2 },
  JPY: { symbol: '¥', trails: false, locale: 'ja-JP', dp: 0 },
};

const USD = CURRENCIES.USD;

/** The currency the companion figure is written in. Never the ledger's. */
let home = { code: 'USD', ...USD, rate: 1, live: true };

/** Called from the app shell whenever state arrives. */
export function setCurrency(code, fx) {
  const spec = CURRENCIES[code] ?? USD;
  const rate = Number(fx?.perUSD?.[code]);
  home = {
    code: CURRENCIES[code] ? code : 'USD',
    ...spec,
    rate: isFinite(rate) && rate > 0 ? rate : 1,
    live: fx?.live !== false,
  };
}

/** What the interface is reading alongside. `code === 'USD'` means no companion. */
export const currency = () => ({ ...home });

/** True when a second figure is worth printing at all. */
export const hasHome = () => home.code !== 'USD';

const write = (v, spec, dp) => {
  const body = Math.abs(v).toLocaleString(spec.locale, { minimumFractionDigits: dp, maximumFractionDigits: dp });
  const signed = (v < 0 ? '-' : '') + body;
  return spec.trails ? `${signed}\u00a0${spec.symbol}` : signed.replace(/^(-?)/, `$1${spec.symbol}`);
};

/** Account money. Dollars, always — this is the number, not a view of it. */
export const money = (n, dp = 2) =>
  n == null || !isFinite(n) ? '—' : write(n, USD, dp);

/**
 * The same amount in the reading currency, for the small figure beside it.
 *
 * Empty when there is nothing to translate, so callers can concatenate blindly —
 * and empty when the conversion rounds to nothing, because "≈ 0 kr" under a
 * "+$0.00" is a line of type that answers a question nobody asked. A companion
 * earns its space by telling you something the figure above it did not.
 */
export const homeAmount = (n, dp) => {
  if (!hasHome() || n == null || !isFinite(n)) return '';
  const v = n * home.rate;
  const places = dp ?? home.dp;
  if (Math.abs(v) < 0.5 / 10 ** places) return '';
  return write(v, home, places);
};

const title = () =>
  `${home.live ? 'Converted' : 'Converted at a standing estimate; the rate feed is unreachable'}`
  + ` at ${home.rate.toFixed(4)} ${home.code} per USD. The account itself trades and settles in dollars.`;

/**
 * The companion, ready to drop into markup: a small dim span, or nothing at all.
 *
 * `≈` is doing real work here. It says this figure is a conversion at today's
 * rate rather than a second balance the account holds, which is the distinction
 * the whole two-figure arrangement exists to preserve.
 */
export const sub = (n, dp = 0) => {
  const text = homeAmount(n, dp);
  if (!text) return '';
  return `<span class="money-sub"${home.live ? '' : ' data-stale="1"'} title="${title()}">≈ ${text}</span>`;
};

/**
 * The companion under a figure that was written with `signedMoney`, carrying the
 * same + / − glyphs. A translation that renders a loss with a plain hyphen under a
 * dollar figure using a proper minus reads as a different quantity for a beat.
 */
export const subSigned = (n, dp = 0) => {
  const text = homeAmount(Math.abs(n), dp);
  if (!text) return '';
  return `<span class="money-sub"${home.live ? '' : ' data-stale="1"'} title="${title()}">≈ ${n >= 0 ? '+' : '−'}${text}</span>`;
};

/** The same, inline in a sentence rather than on its own line. */
export const subInline = (n, dp = 0) => {
  const text = homeAmount(n, dp);
  return text ? ` <span class="money-sub is-inline">≈ ${text}</span>` : '';
};

/**
 * Kept as an explicit name for the places that want to say "this one is dollars
 * and that is the point" — an order value, a realised profit, a commission.
 * Identical to `money` now, and deliberately so: if the two ever diverge again,
 * the bug is back.
 */
export const usd = (n, dp = 2) => money(n, dp);

/* ------------------------------------------------------- instrument currency */

/**
 * What each symbol is quoted in, learned from the server rather than assumed.
 *
 * Filled from `/api/markets` and from the positions on every poll. The fallback
 * below covers the window before the first response arrives and any symbol the
 * server has not mentioned, and it mirrors `Universe.venue(of:)` on the Swift
 * side exactly: a `.ST` suffix or the `^OMX` index is Stockholm, everything else
 * is dollars. Unknown means dollars, which is the same safe default the engine
 * uses — the failure it produces is a familiar sign on a familiar number, not a
 * kronor figure wearing a currency it never had.
 */
const QUOTE_CURRENCY = new Map();

export function noteCurrencies(rows) {
  for (const r of rows ?? []) {
    if (r?.symbol && r?.currency) QUOTE_CURRENCY.set(r.symbol, r.currency);
  }
}

export const currencyOf = (symbol) => {
  if (!symbol) return 'USD';
  const known = QUOTE_CURRENCY.get(symbol);
  if (known) return known;
  return symbol.endsWith('.ST') || symbol === '^OMX' ? 'SEK' : 'USD';
};

/** True when a symbol's prices are not dollars, so a label has to say which. */
export const isForeign = (symbol) => currencyOf(symbol) !== 'USD';

/**
 * A price, in the currency its exchange quotes it in.
 *
 * `symbol` is not optional in spirit — every call site has one — but omitting it
 * falls back to dollars rather than throwing, because a missing sign on a US
 * instrument is invisible and a crash on the desk is not.
 *
 * Decimals follow the magnitude: an instrument trading at 0.089 needs four of
 * them and one at 3,400 needs none.
 */
export const price = (n, symbol) => {
  if (n == null || !isFinite(n)) return '—';
  const spec = CURRENCIES[currencyOf(symbol)] ?? USD;
  const a = Math.abs(n);
  const dp = a >= 1000 ? 0 : a >= 10 ? 2 : a >= 1 ? 3 : 4;
  const body = n.toLocaleString(spec.locale, { minimumFractionDigits: dp, maximumFractionDigits: dp });
  return spec.trails ? `${body}\u00a0${spec.symbol}` : `${spec.symbol}${body}`;
};

/**
 * A price difference — a stop distance, a spread — in the instrument's currency.
 * Separate from `price` only so a call site reads as what it is.
 */
export const priceGap = (n, symbol) => price(n, symbol);

export const signed = (n, dp = 2) =>
  n == null || !isFinite(n) ? '—' : (n >= 0 ? '+' : '') + n.toFixed(dp);

export const pct = (n, dp = 2) =>
  n == null || !isFinite(n) ? '—' : (n >= 0 ? '+' : '') + n.toFixed(dp) + '%';

export const plainPct = (n, dp = 1) =>
  n == null || !isFinite(n) ? '—' : n.toFixed(dp) + '%';

/** An R multiple with its sign, using the same minus as `signedMoney`. */
export const signedR = (n, dp = 2) =>
  n == null || !isFinite(n) ? '—' : (n >= 0 ? '+' : '−') + Math.abs(n).toFixed(dp) + 'R';

export const signedMoney = (n) => {
  if (n == null || !isFinite(n)) return '—';
  return (n >= 0 ? '+' : '−') + money(Math.abs(n));
};

export const compact = (n) => {
  if (n == null || !isFinite(n)) return '—';
  const a = Math.abs(n);
  if (a >= 1e12) return (n / 1e12).toFixed(2) + 'T';
  if (a >= 1e9) return (n / 1e9).toFixed(2) + 'B';
  if (a >= 1e6) return (n / 1e6).toFixed(1) + 'M';
  if (a >= 1e3) return (n / 1e3).toFixed(1) + 'K';
  return n.toFixed(0);
};

export const shares = (n) =>
  n == null ? '—' : n >= 100 ? n.toFixed(2) : n >= 1 ? n.toFixed(4) : n.toFixed(6);

/** Direction class for colouring. Zero is deliberately neutral, not green. */
export const dir = (n) => (n == null || !isFinite(n) || n === 0 ? 'flat' : n > 0 ? 'up' : 'down');

export const when = (ts) => {
  if (!ts) return '—';
  const d = new Date(ts);
  const mins = (Date.now() - ts) / 60000;
  if (mins < 1) return 'just now';
  if (mins < 60) return `${Math.floor(mins)}m ago`;
  if (mins < 60 * 24) return `${Math.floor(mins / 60)}h ago`;
  if (mins < 60 * 24 * 7) return `${Math.floor(mins / 1440)}d ago`;
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
};

export const dateTime = (ts) =>
  !ts ? '—' : new Date(ts).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

export const REGIME_LABEL = {
  'strong-uptrend': 'Strong uptrend',
  'uptrend': 'Uptrend',
  'range': 'Range',
  'downtrend': 'Downtrend',
  'strong-downtrend': 'Strong downtrend',
};

export const regimeClass = (r) =>
  r === 'strong-uptrend' || r === 'uptrend' ? 'up'
  : r === 'range' ? 'warn'
  : 'down';

/** Score colour ramp — red through amber to green, matching the meters. */
export const scoreColor = (v) =>
  v >= 66 ? 'var(--up)' : v >= 45 ? 'var(--warn)' : 'var(--down)';

/** Escapes anything that came from the network before it reaches innerHTML. */
export const esc = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
