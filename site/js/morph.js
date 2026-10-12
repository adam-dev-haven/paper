/**
 * morph.js — repainting a screen without rebuilding it.
 *
 * Every view in Paper renders itself as one long template string, which is the
 * reason the code reads the way it does: a screen is a function of the state, and
 * there is one place to look for what any figure on it means. The problem is what
 * that costs on a poll. `host.innerHTML = html` does not update a screen, it
 * throws it away and builds another one — so a price arriving every ten seconds
 * blinks the whole tab, loses the scroll position of any table mid-read, closes
 * whatever menu was open, and resets every input on the page to the default
 * written into the markup. The bankroll and the sliders on the prediction desk
 * went back to their defaults twice a minute for exactly this reason.
 *
 * So the string stays and the assignment goes. `morph` parses the new markup and
 * walks it against the DOM that is already there, changing only what actually
 * differs: a text node whose number moved, a class that flipped from `up` to
 * `down`, a row that was added. Everything else — including every node the user
 * is currently touching — is left where it is. Nothing about how a view is
 * written has to change.
 *
 * Three things are deliberately protected from a repaint:
 *
 *   - `[data-keep]` — its attributes are still updated, its children are never
 *     touched. This is for a region the server has no opinion about, the setup
 *     form on a tab that polls being the case it was written for. Two details make
 *     it work: a node only counts as kept if it was kept *before* this patch, so a
 *     region appearing for the first time is filled in once and protected after
 *     that; and a kept region is never paired with an ordinary one, so the
 *     attribute cannot spread to a node that was never meant to have it.
 *   - the focused element — a slider being dragged is not overwritten mid-drag.
 *   - anything typed into — first edit stamps `data-dirty` on the field, and from
 *     then on a poll never writes over what someone put there.
 *
 * And one thing is protected the other way round: `tooltip.js` moves a `title` to
 * `data-tip` the first time it shows one, so re-adding an identical `title` here
 * would hand the operating system back its own competing bubble. Identical titles
 * are left alone; changed ones are written and the adopted copy dropped, which is
 * what makes the tooltip pick the new text up on the next hover.
 */

/* What was last written to each host, so a poll that produced identical markup —
 * the common case, since most of a screen does not change in ten seconds — costs
 * one string comparison and no DOM work at all. */
const painted = new WeakMap();

const FIELDS = new Set(['INPUT', 'TEXTAREA', 'SELECT']);

/** Repaint `host` to `html`, touching only what differs. */
export function morph(host, html) {
  watchEdits();
  if (painted.get(host) === html) return;
  painted.set(host, html);
  const next = document.createElement('template');
  next.innerHTML = html;
  reconcile(host, next.content);
}

/**
 * Forget what was last painted into `host`.
 *
 * Needed wherever something other than `morph` writes to the same host — a view
 * switch, or a spinner dropped in before a fetch. Without it the next identical
 * repaint would be skipped as a no-op and the spinner would stay on screen.
 */
export function clearMorph(host) {
  painted.delete(host);
}

/* ------------------------------------------------------------------ walking */

function reconcile(parent, next) {
  const have = parent.childNodes;
  const want = next.childNodes;

  for (let i = 0; i < want.length; i++) {
    const wanted = want[i];
    const held = have[i];
    if (!held) { parent.appendChild(document.importNode(wanted, true)); continue; }
    if (!alike(held, wanted)) { parent.replaceChild(document.importNode(wanted, true), held); continue; }
    patch(held, wanted);
  }

  while (have.length > want.length) parent.removeChild(have[have.length - 1]);
}

/* Two nodes are the same node in a different state if they are the same kind of
 * thing. `data-key` is the escape hatch for a list whose rows are reordered
 * rather than rewritten: keyed rows only ever match their own key. */
function alike(a, b) {
  if (a.nodeType !== b.nodeType) return false;
  if (a.nodeType !== Node.ELEMENT_NODE) return true;
  if (a.tagName !== b.tagName) return false;
  /* A kept region and an ordinary one are not the same node, whatever their tags.
     Pairing them means the ordinary one acquires `data-keep` and is then never
     filled in — which is how pressing "Start another" left the finished run on
     screen with no settings under it. */
  if (a.hasAttribute('data-keep') !== b.hasAttribute('data-keep')) return false;
  return (a.getAttribute('data-key') ?? null) === (b.getAttribute('data-key') ?? null);
}

function patch(held, wanted) {
  if (held.nodeType !== Node.ELEMENT_NODE) {
    if (held.nodeValue !== wanted.nodeValue) held.nodeValue = wanted.nodeValue;
    return;
  }

  /* Read *before* the attributes are written, and that ordering is the whole point.
   *
   * This used to ask `held.hasAttribute('data-keep')` after `patchAttributes` had
   * run — by which time a node that was about to become a kept region already was
   * one, and was protected from being filled in the first place. A region is only
   * worth protecting once it holds what it is protecting; a node that has just
   * acquired the attribute holds the previous view's children and has to be
   * reconciled exactly once before the guard applies to it. */
  const wasKept = held.hasAttribute('data-keep');
  patchAttributes(held, wanted, wasKept);
  if (wasKept) return;
  reconcile(held, wanted);
  if (FIELDS.has(held.tagName)) patchValue(held, wanted);
}

function patchAttributes(held, wanted, wasKept = held.hasAttribute('data-keep')) {
  const guard = guarded(held);

  for (const { name, value } of wanted.attributes) {
    // Already adopted by the tooltip, and unchanged. Writing it back would put
    // the OS bubble on top of ours until the next hover reclaimed it.
    if (name === 'title' && held.dataset.tip === value) continue;
    if (guard && (name === 'value' || name === 'checked')) continue;
    if (held.getAttribute(name) !== value) held.setAttribute(name, value);
  }

  // A kept region does its own bookkeeping — the chart on the desk stamps what it
  // has already drawn on the mount itself — so nothing is taken off it that the
  // template merely has no opinion about.
  if (wasKept) return;

  for (const name of held.getAttributeNames()) {
    if (wanted.hasAttribute(name)) continue;
    if (name === 'data-dirty') continue;
    if (name === 'data-tip' && held.dataset.tip === wanted.getAttribute('title')) continue;
    if (guard && (name === 'value' || name === 'checked')) continue;
    held.removeAttribute(name);
  }
}

/**
 * The attribute and the property are different things on a form control: the
 * attribute is what the markup asked for, the property is what is on screen. Only
 * the second one is what anyone sees, so it has to be set explicitly — and only
 * when the field is not the one being used.
 */
function patchValue(held, wanted) {
  if (guarded(held)) return;

  if (held.tagName === 'SELECT') {
    const chosen = wanted.querySelector('option[selected]') ?? wanted.querySelector('option');
    const value = chosen?.getAttribute('value') ?? chosen?.textContent ?? '';
    if (held.value !== value) held.value = value;
    return;
  }

  if (held.type === 'checkbox' || held.type === 'radio') {
    const on = wanted.hasAttribute('checked');
    if (held.checked !== on) held.checked = on;
    return;
  }

  const value = wanted.getAttribute('value');
  if (value != null && held.value !== value) held.value = value;
}

/* ------------------------------------------------------------- what is in use */

function guarded(el) {
  return el === document.activeElement || el.hasAttribute('data-dirty');
}

let watching = false;

/* One capture-phase listener for the whole document rather than a hook in every
 * view: a field that has been edited is marked once and is then permanently out
 * of reach of a poll, whoever rendered it. */
function watchEdits() {
  if (watching) return;
  watching = true;
  const mark = (e) => {
    const el = e.target;
    if (el instanceof HTMLElement && FIELDS.has(el.tagName)) el.setAttribute('data-dirty', '');
  };
  document.addEventListener('input', mark, true);
  document.addEventListener('change', mark, true);
}
