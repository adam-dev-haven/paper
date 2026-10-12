# Data sources

Paper uses public data and needs no account or key to read it. Read this page before relying on it for anything beyond personal and educational use.

## Where the data comes from

| Data | Source | Notes |
|---|---|---|
| Quotes, daily and intraday bars, headlines, exchange rates | Yahoo Finance, `query1.finance.yahoo.com` | Unofficial, undocumented endpoints |
| Crypto market capitalisation and dominance | CoinGecko, `api.coingecko.com` | Public API, no key |
| Prediction market catalogue and order book | Polymarket, `gamma-api.polymarket.com` and `clob.polymarket.com` | Public read-only endpoints. No orders are placed. |

All of these are fetched with GET requests. The app has no other data dependency, and the interface loads no external scripts, fonts or images.

## Terms and reliability

- **Yahoo Finance endpoints are unofficial.** They are not a documented API, can change or disappear without notice, and may be rate-limited. Yahoo's terms of service govern their use, and they are generally written for personal use. Paper is intended as a personal, educational tool. Check the current terms before using it in any other way, and do not use its output as a commercial data feed.
- **Requests identify as a browser.** Yahoo's endpoints reject unidentified clients, so Paper sends a generic browser User-Agent string. That is a pragmatic choice and a gray area, and it is stated here so nobody has to discover it.
- **Prices are not guaranteed to be real time or accurate.** Quotes can be delayed, and a missing or stale value is shown with its age and not hidden. The header marks the newest quote green, amber past about ninety seconds, and red past ten minutes.
- **Nothing here is investment data you should act on.** Paper is a simulator.

## Caching and request volume

Prices go out as one batched request every 15 seconds while the app is open. Daily bars are cached for 15 minutes, headlines for 20 minutes, and crypto aggregates for 10 minutes. Yahoo's CDN was observed to cache identical price URLs and return progressively staler answers, so each price request carries a unique query parameter. The batch endpoint rejects more than about twenty symbols, so the universe is sent in chunks of fifteen.

## Assets

The interface uses system fonts and an emoji for its favicon, and the app icon is drawn in code. No third-party images, fonts, scripts or datasets are bundled, so there is nothing else to attribute.
