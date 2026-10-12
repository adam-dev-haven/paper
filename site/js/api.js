/** Thin fetch wrapper. Every endpoint is same-origin and local. */

// The server hands out a fresh token with the page on every launch and refuses any
// /api request that does not carry it. A page on another origin cannot read this one.
const TOKEN = document.querySelector('meta[name="paper-token"]')?.content ?? '';

async function req(path, opts = {}) {
  const res = await fetch(path, {
    ...opts,
    cache: 'no-store', // quotes must never come from the browser's cache
    headers: { 'X-Paper-Token': TOKEN, ...(opts.body ? { 'Content-Type': 'application/json' } : {}) },
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
  return data;
}

const post = (path, body = {}) => req(path, { method: 'POST', body: JSON.stringify(body) });

export const getState = (force) => req(`/api/state${force ? '?force=1' : ''}`);
export const getMarkets = () => req('/api/markets');
export const getInstrument = (sym, range = '6mo') => req(`/api/instrument/${encodeURIComponent(sym)}?range=${range}`);

export const getAnalysis = () => req('/api/analysis');
/**
 * The engine's own shortlist for a horizon. Free and instant: no model is called
 * and nothing is billed, because it is arithmetic over bars the board already
 * holds. This is what makes the four horizons comparable without paying to find
 * out whether they differ.
 */
export const getShortlist = (style) =>
  req(`/api/shortlist${style ? `?style=${encodeURIComponent(style)}` : ''}`);

/** `style` picks the horizon for one run; omitted, the profile's own is used. */
export const runAnalysis = (style) =>
  post(`/api/analyse${style ? `?style=${encodeURIComponent(style)}` : ''}`);
export const getReview = () => req('/api/review');
export const runReview = () => post('/api/review');
export const explain = (sym) => post(`/api/explain/${encodeURIComponent(sym)}`);

export const trade = (payload) => post('/api/trade', payload);
export const setBracket = (payload) => post('/api/bracket', payload);
export const reset = () => post('/api/reset');

/* What the desk has learned. Applying and reverting are the same call, because
 * the calibration is recomposed from the whole lesson set either way. */
export const getMemory = () => req('/api/memory');
export const setLessonStatus = (id, status) => post('/api/memory/lesson', { id, status });
export const resetMemory = (keepHistory = true) => post('/api/memory/reset', { keepHistory });

/* The guided setup. `assess` creates nothing — it exists so the consequences of
 * an answer can be shown while it is still being chosen. */
export const assessOnboarding = (answers) => post('/api/onboarding/assess', answers);
export const applyOnboarding = (profile) => post('/api/onboarding/apply', { profile });
export const setSettings = (patch) => post('/api/settings', patch);

/* The full reset. `preview` counts what would go, so the confirmation can name it
 * rather than asking "are you sure" about an unspecified amount of work. */
export const getResetPreview = () => req('/api/reset/preview');
export const resetEverything = (removeKey) =>
  post('/api/reset/everything', { confirm: 'reset', removeKey });
export const getFx = () => req('/api/fx');

/* The analyst's own settings: the key, what a run may spend, and what the last
 * one actually cost. The key is never returned — only a fingerprint of it. */
export const getAnalystPanel = () => req('/api/analyst');
export const saveAnalystKey = (key) => post('/api/analyst/key', { key });
export const testAnalystKey = () => post('/api/analyst/test');
export const removeAnalystKey = () => req('/api/analyst/key', { method: 'DELETE' });
export const saveAnalystLimits = (limits) => post('/api/analyst/limits', limits);
export const saveAnalystModel = (model, fastModel) =>
  post('/api/analyst/model', { model, fastModel });
/** Free and local. It has to work when the API is the thing that is broken. */
export const runSelfCheck = () => req('/api/analyst/check');
export const stopAnalysis = () => post('/api/analyse/stop');

/* The timed day-trading session. */
export const getSession = () => req('/api/session');
export const startSession = (config) => post('/api/session/start', config);
export const takeSessionTrade = (symbol) => post('/api/session/take', { symbol });
export const endSession = () => post('/api/session/end');
export const clearSession = () => post('/api/session/clear');

/* The prediction desk — Polymarket's five-minute Bitcoin market. The run watches
 * and bets server-side on its own ten-second loop, so reading this is finding out
 * what it did rather than driving it. With no run open it returns a free live
 * preview of the current window instead. */
export const getPredict = () => req('/api/predict');
export const startPredict = (config) => post('/api/predict/start', config);
export const endPredict = () => post('/api/predict/end');
export const clearPredict = () => post('/api/predict/clear');
/* The record, read from disk rather than from the running desk — the whole point
 * of it is to answer what survives closing the app. */
export const getPredictJournal = () => req('/api/predict/journal');
/* A bet placed by hand. Skips the edge bar and nothing else — see `PredictDesk.bet`. */
export const placePredictBet = (side, stake) => post('/api/predict/bet', { side, stake });

/* Whether the prediction desk is actually learning. Five checks over the shadow
 * book, the fitted parameters and the real bets, plus the candidate contest. */
export const getPredictAudit = () => req('/api/predict/audit');
/* Re-scores every candidate reading now rather than on its hourly clock. */
export const runPredictContest = () => post('/api/predict/contest');

/* What the account did while the app was shut. Read once on launch and then
 * acknowledged, because it describes one catch-up rather than a standing state. */
export const getReconciliation = () => req('/api/reconciliation');
export const ackReconciliation = () => post('/api/reconciliation/ack');

/* The app's own log. Free, local, and the one screen that has to work when the
 * thing being diagnosed is everything else. */
export const getLogs = ({ level = 'debug', subsystem = '', limit = 400 } = {}) =>
  req(`/api/logs?level=${encodeURIComponent(level)}&subsystem=${encodeURIComponent(subsystem)}&limit=${limit}`);
export const setLogLevel = (level) => post('/api/logs/level', { level });

/* Profiles. Each one owns its own ledger, so switching is switching accounts. */
export const getProfiles = () => req('/api/profiles');
export const activateProfile = (id) => post('/api/profile/activate', { id });
export const saveProfile = (profile) => post('/api/profile/save', profile);
export const newProfile = (preset) => post('/api/profile/new', { preset });
export const deleteProfile = (id) => post('/api/profile/delete', { id });
