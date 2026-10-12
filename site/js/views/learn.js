/**
 * Learn — the method, written out.
 *
 * The per-trade briefs explain one idea. This explains the machine that produced
 * it, so a user can disagree with it for the right reasons.
 */

import { store } from '../app.js';
import { money, plainPct, esc } from '../format.js';

export async function renderLearn(host) {
  const s = store.state;
  // Risk lives on the profile now, and the *effective* figure is the one the
  // engine actually sizes with — which is not always the one that was asked for.
  const risk = { riskPctPerTrade: s.suitability.effectiveRiskPct, maxPositionPct: s.profile.maxPositionPct };
  const budget = s.portfolio.equity * (risk.riskPctPerTrade / 100);

  host.innerHTML = `
    <section class="view">
      <div class="section-head">
        <h2>How Paper decides</h2>
        <span class="hint">The method, in the order it runs.</span>
      </div>

      ${steps(risk, budget, s)}

      <div class="section-head" style="margin-top:30px"><h2>The ideas underneath</h2></div>
      <div class="panel panel-pad" style="display:flex;flex-direction:column;gap:20px">
        ${concepts().map((c) => `
          <div class="explain-block">
            <div class="explain-label">${esc(c.term)}</div>
            <p class="prose">${c.body}</p>
          </div>`).join('')}
      </div>

      <div class="section-head" style="margin-top:30px">
        <h2>How the engine changes</h2>
        <span class="hint">The part of the engine that is adjusted by your own record.</span>
      </div>
      <div class="panel panel-pad" style="display:flex;flex-direction:column;gap:18px">
        <p class="prose">Every recommendation is filed when it is made, with the levels it set and the
        settings it ran under. Days later the market has answered — price reached the target, or the stop,
        or neither — and that answer is arithmetic over bars already held. It costs nothing to compute, so
        it is computed for <strong>every</strong> pick, including the ones you never traded.</p>

        <p class="prose">Grading the untraded picks is what separates a badly calibrated engine from a
        well-calibrated one being traded badly. A trade log covers only the ideas you acted on. If stops
        keep getting hit on ideas nobody took, and price keeps recovering afterwards, the stops are too
        tight.</p>

        ${learningPoints().map((c) => `
          <div class="explain-block">
            <div class="explain-label">${esc(c.term)}</div>
            <p class="prose">${c.body}</p>
          </div>`).join('')}

        <div class="note accent"><span class="note-icon">›</span><span>
          Nothing changes on its own. Each finding arrives as a proposal carrying its evidence and sample
          size, and affects the next analysis only once you apply it. Proposals live on the
          ${'Learning'} tab, and anything applied can be rolled back with the settings recomputed from
          what is left.</span></div>
      </div>

      <div class="section-head" style="margin-top:30px"><h2>Limits of the simulation</h2></div>
      <div class="panel panel-pad">
        <p class="prose" style="margin-bottom:12px">A paper account differs from a real one in ways that
        matter, and every difference makes paper results look better than they would be. Three of them are
        modelled below; the rest are stated as they are.</p>
        <div class="scores" style="gap:14px">
          ${limits().map((l) => `<div class="explain-block">
            <div class="explain-label" style="color:var(--warn)">${esc(l.t)}</div>
            <p class="prose" style="font-size:13px">${esc(l.b)}</p></div>`).join('')}
        </div>
      </div>

      <div class="note warn" style="margin-top:22px">
        <span class="note-icon">!</span>
        <span>Paper is a teaching tool, not an advisory service. Nothing in it is a recommendation to buy
        or sell a real security, and nothing here knows your finances, your timeline or your tolerance for
        loss. Position sizes taken to a real account should be smaller, not larger.</span>
      </div>
    </section>`;
}

function steps(risk, budget, s) {
  const items = [
    {
      n: 1, t: 'Pull the data',
      b: `Two years of daily bars for every instrument in the universe — US listings, Stockholm listings and crypto pairs —
      plus recent headlines. Two years rather than one, because a 1-year window is a session or two short of the
      252-session lookback and the extra history steadies the 200-day average. Crypto uses a 365-day year because it
      never closes; equities use 252 sessions. A wrong year length corrupts every volatility number downstream.`,
    },
    {
      n: 2, t: 'Read the trend',
      b: `Price against its 20-, 50- and 200-day averages, and the slope of the 50-day. Averages stacked in order and
      rising define a trend, where pullbacks tend to be bought. Tangled averages define a range, where the same
      buy-the-dip behaviour loses money. The regime label sets how much room every later step allows the trade.`,
    },
    {
      n: 3, t: 'Measure how much it moves',
      b: `Average True Range — the typical daily travel, gaps included. Every distance below is measured in multiples
      of it, which is what makes a stop on Walmart and a stop on Solana comparable. A 3% stop is generous on a quiet
      instrument and inside one ordinary day on a volatile one.`,
    },
    {
      n: 4, t: 'Find the levels that matter',
      b: `Swing pivots — bars that were the high or low point within five sessions on either side. These are prices
      the market has reacted to before, unlike round numbers. The stop goes just under the nearest one below; the
      first target goes just under the nearest meaningful one above.`,
    },
    {
      n: 5, t: 'Place the stop first',
      b: `Before any question of size, the stop is set where the reason for the trade would have stopped being true.
      Wider in a strong trend, tighter in a range. The stop is never widened to allow a larger position.`,
    },
    {
      n: 6, t: 'Let size fall out of the risk',
      b: `You are currently risking ${plainPct(risk.riskPctPerTrade)} of equity per trade, or ${money(budget, 0)}.
      Divide that by the distance from entry to stop and you get the position size. This is the reverse of deciding
      how much to invest and then placing a stop where it feels tolerable. In this order, ten losses in a row cost
      about ${plainPct(risk.riskPctPerTrade * 10, 0)} of the account.`,
    },
    {
      n: 7, t: 'Refuse most of them',
      b: `If the reward does not cover the risk at least 1.5 to 1, the trade is refused. If pulling the stop closer
      would fix the ratio only by putting it inside the instrument's daily noise, it is refused. If price is below a
      falling moving-average stack, it is refused. Most candidates fail.`,
    },
    {
      n: 8, t: 'Score it for the trade you are actually making',
      b: `Six axes — trend, momentum, entry quality, risk, daily range and durability — weighted differently
      depending on the horizon. A day trade needs an instrument that moves far enough in a session to cover the
      spread; a five-year hold needs one that survives being held, and barely cares what this week did. The
      momentum window moves too: days for a fast trade, a year for a slow one. The same board produces genuinely
      different shortlists, which is the point.`,
    },
    {
      n: 9, t: 'Rank what survives, as a basket',
      b: `Sector and correlation caps apply before any money does, because six semiconductor names are one bet
      across six tickers, and every market you trade is held a place so a hot tape in one does not bury the other.
      ${s.analyst.available
        ? 'Claude then reads each survivor against its own chart and headlines and ranks them against each other in a second pass.'
        : 'The engine ranks survivors by reward-to-risk and conviction. With an API key, a second pass also weighs the picks against each other for hidden correlation, which single-stock analysis does not cover.'}`,
    },
    {
      n: 10, t: 'Write it down before committing',
      b: `The thesis is stored with the position. When it closes, the record shows what you believed at entry beside
      what happened.`,
    },
    {
      n: 11, t: 'Let the exits fire on their own',
      b: `Once a target and stop are attached, the position closes when either is touched, whether or not you are
      looking. If both were hit inside the same session, the stop is assumed to have filled first, rather than
      assuming the better outcome.`,
    },
  ];

  return `<div class="panel panel-pad" style="display:flex;flex-direction:column;gap:18px">
    ${items.map((i) => `<div class="row" style="align-items:flex-start;gap:14px">
      <div class="pick-rank" style="margin-top:1px">${i.n}</div>
      <div style="flex:1">
        <div style="font-weight:600;font-size:13.5px;margin-bottom:3px">${esc(i.t)}</div>
        <p class="prose" style="font-size:13px">${i.b}</p>
      </div>
    </div>`).join('')}
  </div>`;
}

function concepts() {
  return [
    { term: 'R — the unit that compares trades',
      body: `R is one unit of the money you risked. Risk $1,000 and make $2,500 and that is +2.5R, whether the
      instrument was Walmart or Solana. It puts a slow trade and a violent one on the same scale, so the
      journal reports expectancy in R rather than dollars. Positive expectancy makes money over enough trades even
      while losing most of them.` },
    { term: 'Why win rate says little on its own',
      body: `At 2:1 reward-to-risk you break even winning 33% of the time. At 1:1 you need 50%. At 0.5:1 you need
      67%. The engine refuses thin ratios for this reason: the ratio sets the win rate you need, and a reading of
      the setup moves the odds by a few percent at most.` },
    { term: 'How the regime is measured',
      body: `The regime read is mechanical: where the benchmark sits against its 200-day average, and how many names
      in the group hold their own 50-day. That second number is breadth, and it usually turns before the index does.
      New highs on narrowing breadth mean fewer names are carrying the index.` },
    { term: 'Crypto moves as one trade',
      body: `Bitcoin dominance shows where money sits inside crypto. Dominance rising in a falling market means
      capital is moving into Bitcoin rather than leaving. Dominance falling in a rising market is the altcoin phase;
      later in it, the high-beta names behave as a leveraged version of the same move and unwind together.` },
    { term: 'Volatility sets position size',
      body: `A volatile instrument requires a wider stop, which means a smaller position for the same risk. Taking
      the same position size in both is what creates the danger. Position size here is an output, never an input.` },
    { term: 'Overhead supply',
      body: `When price approaches a level where many people bought and then watched it fall, some of them sell at
      break-even. That is why rallies stall at old highs, and why the first target sits just under one rather than
      beyond it. Near all-time highs there is no overhead supply, which is when a breakout can run.` },
  ];
}

function learningPoints() {
  return [
    { term: 'Two things are graded separately',
      body: `The engine is graded on its picks; you are graded on your execution. "Stops are being placed inside
      the ordinary noise" is a setting, and a change to it is offered. "You close winners after two days" is a
      habit, and no setting fixes it, so none is offered.` },
    { term: 'Every change is small and needs a sample',
      body: `A whipsaw problem widens the stops by 15%, not by half. Two runs of agreeing evidence move it twice;
      one run cannot move it far. Below the sample size a finding is marked <em>gathering evidence</em> and shown
      but not offered. Three trades is not a sample.` },
    { term: 'Calibration can only reduce risk',
      body: `Risk per trade is the one dial that may only be turned down. Everything else moves in both directions,
      and every change is bounded: a stop can end up between 0.7 and 1.6 times its textbook width and nowhere
      outside that, whether the proposal came from the arithmetic or from the analyst.` },
    { term: 'Findings expire without evidence',
      body: `The market has phases, and a bias learned in one of them would otherwise stay in the engine. An applied
      finding that stops appearing in the record for two consecutive analyses retires, and the settings are
      recomputed without it. The record of what was recommended is kept, so the finding can be re-derived if the
      evidence returns.` },
    { term: 'The analyst proposes within a fixed vocabulary',
      body: `With a key, a sixth pass reads the same track record and proposes what the arithmetic rules missed. It
      picks a dial from a fixed list, a direction, and one of three step sizes; the engine computes and clamps the
      number. A model naming a figure directly would be setting a risk parameter, which it is not permitted to do.` },
  ];
}

function limits() {
  return [
    { t: 'Spread and commission',
      b: 'The spread is charged on every fill, in and out, scaled to the instrument’s own daily range, plus whatever commission the profile’s venue takes. Trade the same instrument in and straight back out at an unchanged price and the account is down money, as it would be in a real account. This is the modelled cost that most alters which strategies look good.' },
    { t: 'Gapped stops',
      b: 'A stop is an instruction, not a guarantee. When a session opens below your level, the fill is the open, and a planned −1R becomes −3R. Every bracket is checked against the session open as well as its range, and those exits are marked as gapped with the difference from the plan. An intraday flash crash cannot be modelled from daily bars.' },
    { t: 'Tax',
      b: 'Gains realised inside the long-term threshold are taxed at the higher rate, netted across the year so losses offset gains, and withheld from the balance at the sale rather than left to compound. This is the cost that falls hardest on frequent trading. It is a simplified model of one tax regime, not advice about yours.' },
    { t: 'No real money at stake',
      b: 'This one is not modelled and cannot be. The hardest part of trading is holding a plan while real money moves against you, and a simulator removes it. Paper results stay consistently better than live ones for the same person running the same system.' },
    { t: 'Survivorship bias in the universe',
      b: 'These instruments are here because they are liquid and currently interesting. Real screening includes the names that went to zero, and a system tested only on survivors looks better than it is.' },
    { t: 'Intraday sessions',
      b: 'The Session tab reads five-minute bars, so its stops and targets are intraday numbers rather than daily ones relabelled. It cannot show the inside of a five-minute bar, where a wick can take a position out, and it cannot reproduce six hours of unbroken attention. The costs it charges are real, and on a five-minute timeframe they are usually most of the result.' },
    { t: 'Currency risk is not modelled',
      b: 'Every instrument in this universe is quoted in dollars. Choosing euros or kronor converts what is shown and what you type at the live rate, and leaves the ledger settled in dollars. A real account in another currency would also hold an FX position whose swings land in the profit; the desk states the size of that exposure rather than simulating it.' },
    { t: 'Daily bars',
      b: 'Outside the Session tab the engine reads one bar per session. That is enough for swing and position work and not enough for day trading. An intraday horizon buys the tightest stops and fastest setups the data supports, not a real intraday method. The day-trader rule and the short-term tax rate are still enforced — the first on US equities only, since that is the only thing it reaches.' },
  ];
}
