# Architecture

Paper is one Swift package with a single executable target and no third-party dependencies. The app is a native window around a web view. Inside the process, a small HTTP server on a loopback port serves the interface and answers its API calls, and the interface in `site/` is plain ES modules with no build step.

```
┌──────────────────────────── Paper.app (one process) ───────────────────────────┐
│                                                                                │
│  SwiftUI window ── WKWebView ── fetch ──▶ HTTPServer (127.0.0.1, random port)  │
│                                              │                                 │
│                                       RequestGate (Host, Origin, token)        │
│                                              │                                 │
│                          ┌───────────────────┴──────────────┐                  │
│                          ▼                                  ▼                  │
│                   SiteFiles (site/)                  Desk.handle (/api/*)      │
│                                                             │                  │
│            ┌──────────────┬─────────────┬──────────────┬────┴──────────┐       │
│            ▼              ▼             ▼              ▼               ▼       │
│        Analysis      Portfolio      Profile       Market / FX     Analyst      │
│        Universe      (ledger)       Frictions     (public data)   (optional)   │
│        Review        Reconcile      Onboarding                                 │
│        Learning      Session        Predict*                                   │
└────────────────────────────────────────────────────────────────────────────────┘
```

## Why a local server

A custom `WKURLSchemeHandler` would avoid the socket, but WebKit drops the body of a POST made through one, and about half of Paper's API is POSTs carrying JSON. A real socket keeps the request intact. It also means the interface can be developed and inspected like any web page.

The cost is that a loopback server is reachable by any web page open on the same machine. `RequestGate` exists for that reason and is described in [SECURITY.md](../SECURITY.md). Every request is checked for the exact `Host`, a same-origin `Origin`, and, for `/api/` routes, a per-launch token that is injected into `index.html` as it is served. `api.js` is the only place the interface calls `fetch`, so the token is attached in one place.

## The engine

The engine is pure arithmetic over price bars, kept apart from the interface and from the network.

- `Analysis` computes indicators, market regime, support and resistance, and a trade plan with entry, stop, target and size. It never asks a model to invent a price level.
- `Universe` defines the 89 instruments, their venues, currencies and sectors.
- `Profile` and `Onboarding` turn the user's circumstances into limits. Risk capacity is derived from circumstances and caps the stated appetite, and the profile scales stop width, target distance, minimum reward-to-risk and trade duration. The same chart gives different plans to different profiles.
- `Frictions` models spread, commission, tax by holding period, gaps through stops and the pattern day trader rule. `MarketCalendar` supplies exchange hours and holidays per venue.
- `Review`, `Learning` and `LearningRules` grade closed trades and the engine's own recommendations against what price did afterwards, and turn the difference into proposals that the user accepts or rejects.
- `Session` and the `Predict*` files implement the timed day-trading run and the simulated prediction desk.

## The ledger

`Portfolio` is the account: cash, positions, tax lots, fills, equity curve and contributions. One file per profile, written atomically as JSON. Three rules govern persistence, and they are enforced by tests and not only by convention.

- **Old files always read.** Persisted types decode field by field with an explicit default for anything that is not identifying. Swift's synthesised decoder throws on a missing key even when the property has a default, so a field added to a struct could otherwise make every existing file unreadable.
- **A read failure never writes.** A file that cannot be parsed is left exactly as it is, copied aside as `<profile>.unreadable-<timestamp>.json`, and the account runs read-only for the session with a visible banner.
- **Every launch backs up first.** Before any ledger is opened, each one is copied byte for byte into `ledgers/backups/<timestamp>/`, and the last 20 launches are kept.

`SchemaGate` is the test that holds the first rule in place. It encodes every persisted type, removes each key in turn, and fails if a key that is not declared identifying turns out to be load-bearing. `build.sh` runs the self-test and will not produce a bundle that fails it.

## Market data

`Market` fetches quotes, bars and headlines from Yahoo Finance and crypto aggregates from CoinGecko. Prices refresh on a short clock (about 15 seconds, batched into one request) and daily bars on a long one (15 minutes), because a daily series barely moves inside a session. Results are cached with a time-to-live per kind, and a stale value is served in preference to an error, with its age shown in the header. The details of what is fetched and from where are in [DATA-SOURCES.md](DATA-SOURCES.md).

`Currency` keeps account money in US dollars and prices in their native currency. Conversion happens when a position is opened and when it is marked.

## The analyst

`Analyst` is optional. It speaks the Anthropic Messages API directly over `URLSession`, because there is no Swift SDK: streamed server-sent events, structured outputs against a JSON schema, and a cacheable system prefix. A run is a chain of passes. The first batch of the screening pass runs alone so that the cached prefix is written before the rest read it.

The model reads, weighs and explains. It is never asked to produce a price level, and its output is clamped by the engine before it affects anything. Cost and failure are bounded by `Budget`:

- a token ceiling and a wall-clock ceiling per run
- a stop after the same failure repeats, because a deterministic failure is not worth a third attempt
- a stop after consecutive calls that return nothing usable

`Credentials` owns the key. It resolves the Keychain entry first and then the `ANTHROPIC_API_KEY` environment variable, verifies a key with a one-token request before saving it, and hands out only a fingerprint. With no key, `Analyst.status()` reports itself unavailable and every numeric part of the app carries on.

## The interface

`site/` is ES modules loaded straight from the bundle. `app.js` owns the tab shell, `api.js` the fetch wrapper, and `views/` one module per tab. Text from the network or from a model passes through `esc()` before it is placed in a template, and news links through `safeUrl()`. The interface loads nothing from an external host.

## Tests

`SelfTest.swift` runs inside the app binary with `--selftest`, so it needs no test target. Each assertion goes through `ok(name, condition)`, and the process exits with status 1 if any fail. Beyond the engine and ledger tests, one group starts the real server on a loopback port and sends it requests over a raw socket, including a forged `Host`, a foreign `Origin`, a missing token, a negative `Content-Length` and a chunked body.

Two other flags exist for development. `--predictaudit` reads the prediction desk's book from disk and prints an audit without writing anything, and `--iconset <dir>` writes the app icon. `PAPER_DATA_DIR` moves every file the app writes to another folder.
