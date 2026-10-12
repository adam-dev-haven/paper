# Getting started

This guide takes you from a clean Mac to a first simulated trade, then covers the optional analyst key and common problems.

## 1. Install the tools

You need an Apple silicon Mac on macOS 14 or later and the Xcode Command Line Tools. Check whether they are installed:

```bash
swift --version
```

If that prints version 5.9 or higher, continue. Otherwise install the tools and check again:

```bash
xcode-select --install
```

Paper does not support Intel Macs. `build.sh` builds for `arm64` only.

## 2. Build the app

```bash
git clone https://github.com/adam-dev-haven/paper.git
cd paper
./build.sh
open Paper.app
```

Paper has no package dependencies, so the build downloads nothing. The script compiles the sources, runs the self-test, draws the app icon, assembles `Paper.app` and signs it ad hoc. If the self-test fails, no bundle is produced and the script prints how to run the test directly.

Because you built the app yourself, macOS does not quarantine it and Gatekeeper does not prompt. To keep it, drag `Paper.app` to Applications.

Set your own bundle identifier with `PAPER_BUNDLE_ID=com.yourname.paper ./build.sh`. The identifier also names the Keychain entry that holds an analyst key, so builds with different identifiers keep separate entries.

## 3. First launch

Paper opens a window and starts a short onboarding titled "What brings you here?". It asks about your goal, horizon, finances and appetite for loss, and uses the answers to configure a profile. You can skip it and change everything later in **Settings**.

Paper creates five preset profiles, each with its own simulated starting capital and an empty ledger. Switch between them from the account menu at the top left. Each keeps a separate history, so you can try a day trader and a long-term grower side by side without mixing the results.

The header shows the age of the newest price. Green and ticking means live. It turns amber after about ninety seconds without an update and red after ten minutes. The refresh button, or ⌘R, forces an update. Prices come from public services, so Paper needs an internet connection.

## 4. A first trade

1. Open **Markets**. Every instrument is listed with its trend, volatility and the engine's read. The right-hand column says whether the active profile can currently fund a setup in it.
2. Click an instrument. The drawer shows the chart with the proposed entry, stop and target drawn on it, the metrics behind them, recent headlines and a manual order ticket.
3. Or open **Analyst** and press **Run the analyst**. Pick a horizon first: intraday, swing, position or long-term. It ranks the board, refuses most of it and returns a few plans with sizes.
4. Enter a trade from the ticket. Write a thesis. The thesis is stored with the trade and is shown back to you in the review.
5. Open **Desk** to see equity, open positions and total risk on. A stop or target fires whenever market data refreshes, whether or not the window is in front.

Every fill crosses a spread and pays commission, and stops can gap, so results will be a little worse than the chart suggests. That is deliberate.

## 5. Reviewing

- **Journal** lists every entry and exit with the reasoning at the time, the quoted price beside the price actually filled, and what each fill cost.
- **Analyst → Review** writes a post-mortem for each closed trade, including what the instrument did after you sold it.
- **Calibration** grades the engine's own picks against what price did next, including the ones you ignored. It proposes changes to how the next analysis behaves. Nothing changes until you apply one, and a change can be reverted.
- **Diagnostics** shows what the app has been logging, and any ledger that has gone read-only.

## 6. Session and Predict

**Session** starts a timed day-trading run on five-minute bars with a fixed stake and duration. Its rules cannot be edited while the clock runs.

**Predict** watches Polymarket's rolling five-minute Bitcoin market and places simulated bets from an invented bankroll, using public data. It is the one part of Paper that acts without being asked. It cannot place real orders: there is no wallet, key or signing code in the app.

## 7. The analyst key (optional)

Everything above works without a key. A key adds a written news reading, a cross-instrument view and a brief on each pick.

1. Create an API key in the Anthropic Console.
2. In Paper, open **Settings → Analyst** and paste it. Paper sends one one-token request to check it before saving.
3. The key is stored in the login Keychain. The `ANTHROPIC_API_KEY` environment variable is used if nothing is saved.

Read [SECURITY.md](../SECURITY.md) before you do this. With a key set, the analyst sends the profile's circumstances, including the income and expense figures you entered, to Anthropic. Settings → Analyst also lets you choose the model and set the token budget for a run.

To remove the key, use the same screen. The Keychain entry is deleted and the written analysis switches off.

## Where things are

| What | Where |
|---|---|
| Ledgers | `~/Library/Application Support/Paper/ledgers/` |
| Backups | `ledgers/backups/`, one copy per launch, the last 20 kept |
| Logs | `~/Library/Application Support/Paper/logs/`, two weeks kept |

To roll back a ledger, quit Paper and copy a file from one of the backup folders over the one in `ledgers/`.

To erase everything, use **Settings → Reset**. It asks you to type `reset`, and the action cannot be undone. It can also remove a saved analyst key.

## Running it against scratch data

To try a build without touching your own accounts, point it at an empty folder:

```bash
PAPER_DATA_DIR="$(mktemp -d)" Paper.app/Contents/MacOS/Paper
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `swift: command not found` | Install the Command Line Tools with `xcode-select --install`. |
| Build fails with an architecture error | The build is Apple silicon only. |
| The self-test fails during `build.sh` | Run it directly to see every failure: `PAPER_DATA_DIR="$(mktemp -d)" .build/release/Paper --selftest`. Please open an issue with the output. |
| "Paper could not open its desk" | The local server could not start. Quit and relaunch. If it persists, check Diagnostics or the log file. |
| The interface says "Missing or wrong session token" | The page was loaded before the app restarted. Reload the window, or quit and reopen Paper. |
| The price badge is amber or red | The data service is slow or unreachable. Paper keeps showing the last good value and labels its age. Press ⌘R to retry. |
| "Written analysis is off" | No key is saved and none is set in `ANTHROPIC_API_KEY`. That is the normal state, and everything numeric still works. |
| A key is rejected | A real Anthropic API key starts with `sk-ant-`. Check that the whole key was copied and that it is an API key. |
| An account shows a banner about read-only mode | Its ledger could not be read. Paper left the file untouched and copied it aside as `<profile>.unreadable-<timestamp>.json`. Restore from a backup folder. |
| Stockholm prices look stale outside trading hours | The exchange is closed. Hours and holiday calendars are modelled per venue, and the badge shows the age of the newest quote. |
