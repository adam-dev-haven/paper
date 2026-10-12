/**
 * glossary.js — the words, explained where they are used.
 *
 * A trading interface is unreadable to a beginner not because the ideas are hard
 * but because roughly forty words are used as though everyone already knows them.
 * Sending someone to a glossary page breaks their attention at exactly the moment
 * they were about to understand something, so the definitions live inline: any
 * term wrapped by `term()` carries a dotted underline and gives its plain-language
 * meaning on hover or tap.
 *
 * In plain-language mode the underline is visible. With it off, the markup is
 * identical and the underline is not drawn — so an experienced user gets a clean
 * screen and the same tooltips are still there if they want one.
 */

import { esc } from './format.js';

export const TERMS = {
  equity: ['Equity', 'Everything the account is worth right now: the cash plus what the open positions would fetch if you sold them at the current price.'],
  cash: ['Cash', 'Money in the account that is not in a position. It is what you have left to buy anything with.'],
  position: ['Position', 'Something you currently own. You open a position by buying and close it by selling.'],
  entry: ['Entry', 'The price you buy at. Everything else in the plan is measured from it.'],
  stop: ['Stop', 'A standing instruction to sell if the price falls to a set level. It marks where the reason for the trade has stopped being true, rather than where the loss becomes uncomfortable.'],
  target: ['Target', 'The price at which you take the gain. Set before you buy, rather than while the position is moving.'],
  bracket: ['Bracket', 'A target and a stop attached to a position at once. Whichever is touched first closes it, whether or not you are looking.'],
  risk: ['Risk', 'The money you lose if the stop fills, not the money you put in. You choose the risk, and the amount invested follows from it.'],
  rr: ['Reward to risk', 'How much you stand to make against how much you stand to lose. 3:1 means the target is three times as far away as the stop, so you can be wrong most of the time and still come out ahead.'],
  r: ['R', 'One unit of risk. A trade that made twice what it could have lost made +2R. It lets a $50 loss and a $5,000 loss be compared on the same scale.'],
  expectancy: ['Expectancy', 'What one trade is worth on average, in units of risk, once the winners and losers are netted. Positive means the method pays over enough trades; negative means repeating it costs money.'],
  winRate: ['Win rate', 'How often trades finish in profit. On its own it says little: a 30% win rate at 5:1 beats a 70% win rate at 1:2.'],
  breakeven: ['Break-even win rate', 'How often you would have to be right, at this reward-to-risk, just to end up flat. Anything above it is the edge.'],
  atr: ['Average daily range', 'How far this instrument usually travels in a day, gaps included. Every distance in the plan is measured in multiples of it, which is what makes a stop on Walmart and a stop on Solana comparable.'],
  volatility: ['Volatility', 'How much the price moves about. High volatility is not the same as risk: the stop sits further away, so the position is smaller.'],
  drawdown: ['Drawdown', 'The fall from the account’s highest point to its lowest afterwards. It is what a position or an account has to be held through.'],
  slippage: ['Spread', 'The gap between the price to buy and the price to sell. You cross it in both directions, so a round trip at an unchanged price still loses money.'],
  commission: ['Commission', 'What the broker charges to execute an order. Paid on the way in and again on the way out.'],
  heat: ['Total open risk', 'Everything at stake across every open position at once. Five positions each risking 1% is a 5% bet.'],
  capacity: ['Risk capacity', 'What your circumstances can survive losing — computed from income, savings and how long the money has. Distinct from how much risk you would like to take, and it takes precedence.'],
  appetite: ['Risk appetite', 'How much risk you say you want. The engine sizes on the smaller of this and your capacity, and tells you when it has.'],
  horizon: ['Horizon', 'How long a trade is meant to last. It sets how wide the stop is, how far the target is, and how long the plan may take before the setup is refused as the wrong trade for you.'],
  regime: ['Market regime', 'What the market as a whole is doing — trending up, trending down, or going nowhere. The same setup is worth different amounts in each.'],
  sma: ['Moving average', 'The average closing price over the last N days, redrawn each day. When the short averages sit above the long ones in order, that is what a trend looks like from the inside.'],
  rsi: ['RSI', 'A 0–100 measure of how one-sided recent moves have been. Above 70 usually means stretched, below 30 washed out. It describes recent movement rather than signalling a trade.'],
  support: ['Support', 'A price the market has already turned upward at. A stop placed just under one is only reached if that level fails.'],
  resistance: ['Resistance', 'A price where rallies have stalled before, usually because people who bought there and watched it fall are waiting to get out at break-even.'],
  mae: ['Heat taken', 'How far a position went against you before it worked. A winner that spent a week underwater does not show up in the profit figure.'],
  mfe: ['Best available', 'The most a position was worth while you held it. The gap between that and the exit price is what the exit cost.'],
  capture: ['Capture rate', 'How much of the available move you took. Low capture with a decent win rate points at the exits rather than the picks.'],
  pdt: ['Pattern day trader rule', 'A US rule freezing a margin account under $25,000 after three same-session round trips in five business days. Enforced here.'],
  benchmark: ['Benchmark', 'What you would have made doing nothing but owning the index. It is the figure this activity is measured against.'],
  gapped: ['Gapped through', 'When a market opens past your stop, the sale happens at the open, not at the stop. A stop is an instruction, not a guarantee.'],
  lot: ['Tax lot', 'One parcel of shares, with the date and price it was bought at. Selling matches the oldest parcels first, which decides the tax rate.'],
  calibration: ['Calibration', 'Adjustments made to the engine from your own record: wider stops, a higher bar, and so on. Each one is listed with its evidence and can be turned off.'],
  conviction: ['Conviction score', 'The engine’s own 0–100 read on a setup, from trend, momentum, entry quality, risk, daily range and durability — weighted for the horizon you asked about, so the same instrument scores differently for a day trade and a five-year hold. It orders the board; it never sets a price.'],
};

let plain = true;
export const setPlainLanguage = (on) => { plain = !!on; document.body.dataset.plain = on ? '1' : '0'; };
export const isPlain = () => plain;

/**
 * A term with its definition attached. `label` overrides the display text where
 * the sentence needs a different form of the word.
 */
export function term(key, label) {
  const entry = TERMS[key];
  const text = label ?? entry?.[0] ?? key;
  if (!entry) return esc(text);
  return `<span class="gloss" tabindex="0" data-gloss="${esc(key)}" title="${esc(entry[1])}">${esc(text)}</span>`;
}

/** The whole definition, for the places that teach rather than label. */
export function define(key) {
  const entry = TERMS[key];
  return entry ? `<strong>${esc(entry[0])}</strong> — ${esc(entry[1])}` : '';
}

/**
 * A one-line plain-language gloss under a heading, shown only in plain mode. This
 * is the main way the app gets easier to read without getting longer for someone
 * who does not need it.
 */
export function aside(text) {
  return plain ? `<p class="plain-aside">${esc(text)}</p>` : '';
}
