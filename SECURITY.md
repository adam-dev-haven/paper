# Security

Paper is a single-user Mac app. It stores a simulated trading record on your machine, runs a small web server on a loopback port for its own window, and talks to a handful of public data services. This page describes what it stores, what it contacts, what it sends when the optional analyst is on, and where the limits are.

## Reporting a problem

Use GitHub's private vulnerability reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. Please do not open a public issue for a security problem.

## What Paper stores

- One JSON file per profile in `~/Library/Application Support/Paper/ledgers/`, plus backups, profile and settings files, an analysis cache, and daily logs. Everything is plain text and is not encrypted by Paper. Turn on FileVault if the disk may be lost or shared.
- The files describe a simulated account: positions, fills, theses, and the profile's circumstances (capital, contributions, income, expenses, emergency savings) as entered by the user. They contain no brokerage credentials, because Paper has none to hold.
- No API key is ever written to a file, a log or an export. If the user enters an Anthropic key, it goes into the login Keychain as a device-only item that is readable only while the Mac is unlocked. The app and its API refer to a key only by a fingerprint of its first seven and last four characters.
- This repository contains no keys, tokens or credentials. The only key-shaped string is a fabricated test value, assembled in code so that secret scanners do not mistake it for a real one.

## What Paper contacts

Every network call goes to one of these hosts. There is no telemetry, no analytics and no update check.

| Host | Used for | Method |
|---|---|---|
| `query1.finance.yahoo.com` | Quotes, daily and intraday bars, headlines | GET |
| `api.coingecko.com` | Crypto market-wide figures | GET |
| `gamma-api.polymarket.com`, `clob.polymarket.com` | Public market catalogue and order book for the prediction desk | GET |
| `api.anthropic.com` | The optional analyst, and verifying a key when it is saved | POST, only when a key is set |

Paper cannot place an order anywhere. The Polymarket code reads a public catalogue and order book. It has no wallet, no private key, no signing code and no call to an order endpoint, and every fill is simulated against the book it reads. All requests to market data hosts are GETs, and the only POSTs in the app are the two Anthropic calls above.

Requests to Yahoo Finance carry a generic browser User-Agent. See [docs/DATA-SOURCES.md](docs/DATA-SOURCES.md).

The interface in `site/` loads no scripts, fonts or images from any external host.

## What the optional analyst sends

With no key, nothing is sent to Anthropic. With a key, each analysis run sends:

- the active profile's description: its name and note, objective, horizon, target return, simulated capital, monthly contribution, monthly expenses, income stability, months of emergency savings, risk limits, universe and cost model
- indicator values, price levels and headlines for the instruments being read
- for the review pass, each closed trade being reviewed: symbol, prices, size, profit and loss, costs, tax due, how far it moved for and against the position, what it did after the exit, and the thesis text attached to the trade
- what the app has previously noted about its own picks, as summarised text

Some profile fields describe the user's real circumstances, because Paper uses them to size trades sensibly. Enter approximate values if that matters to you, or do not set a key. Anthropic's handling of API data is governed by Anthropic's own terms. Each run is bounded by a token budget and a wall-clock ceiling, and a run that repeats the same failure stops rather than retrying.

## The local server

The window shows a web view that loads the interface from a server bound to `127.0.0.1` on a random port chosen at launch. Loopback is not the same as private, because any web page open in a browser on the same Mac can send requests to it, and a page that rebinds its own domain name to `127.0.0.1` can read the answers. The server therefore refuses a request unless all of these hold:

- the `Host` header is exactly `127.0.0.1:<port>`, which defeats DNS rebinding
- any `Origin` header is the server's own origin, and any `Sec-Fetch-Site` header is `same-origin` or `none`
- for every `/api/` route, the request carries the `X-Paper-Token` header with a 256-bit random value generated at launch

The token is delivered only inside the served `index.html`. A page on another origin can send a request but cannot read that page, so it cannot learn the token. Without these checks, a hostile page could have posted `{"confirm":"reset"}` to the reset route, since a typed confirmation in a request body protects nothing against a script.

The parser also caps the header block at 32 KB and the body at 2 MB, rejects a negative or conflicting `Content-Length` and chunked bodies, and abandons a connection that has not produced a full request within 30 seconds. Profile identifiers received from the page become part of a file name, so only letters, digits and dashes are accepted, both when the page saves a profile and when the profiles file is read. News links open in the default browser only if they are `http` or `https`. The web inspector is off unless the app is started with `PAPER_INSPECT=1`.

Static files are served only from inside the bundled `site/` folder, and the resolved path is checked against it.

## Known limits

- **A process running as you can use the API.** Any program that runs as your macOS user can read the token from the page and call the local API. That is the same trust boundary as the ledger files, which the same program could read or edit directly.
- **No encryption at rest** beyond the Keychain entry for the key and whatever FileVault provides.
- **The interface escapes text it renders.** News headlines and model-written text pass through an escaping helper before they reach the page. That review was a targeted sweep and not a proof, so treat rendering of untrusted text as the first place to look.
- **Data from a third party is trusted for display.** Prices and headlines come from public endpoints that Paper does not control, and a wrong or stale value is shown, with the age of the newest quote visible in the header.

## Supported versions

Only the latest commit on `main` receives fixes.
