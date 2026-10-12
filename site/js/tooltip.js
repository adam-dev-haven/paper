/**
 * tooltip.js — the explanations the interface keeps promising.
 *
 * Six kinds of element in this app carry `cursor: help`, and roughly forty more
 * carry a `title`. Every one of them was relying on the operating system's own
 * tooltip: a bubble that takes about a second to appear, never appears at all for
 * a keyboard, and cannot be summoned deliberately by someone who has just noticed
 * the cursor change and wants to know why. So the interface was advertising an
 * explanation on hover and, for most people most of the time, not giving one.
 *
 * This replaces that with a tooltip the app owns. It reads the `title` an element
 * already has — no call site has to change — and moves it to `data-tip` the first
 * time it is needed, so the OS bubble never competes with ours. It opens on hover
 * after a short delay, immediately on keyboard focus, and on click, which is the
 * only one of the three a trackpad tap can actually perform.
 */

const DELAY = 110;
const GAP = 8;
const EDGE = 10;

let tip = null;
let anchor = null;
let timer = 0;
let pinned = false;

function surface() {
  if (tip) return tip;
  tip = document.createElement('div');
  tip.className = 'tip';
  tip.id = 'tip';
  tip.setAttribute('role', 'tooltip');
  tip.hidden = true;
  document.body.append(tip);
  return tip;
}

/**
 * The text an element wants to explain itself with. Taking it off `title`
 * permanently is the point: it is the only way to stop the OS drawing its own
 * bubble over ours two seconds later.
 */
function textFor(el) {
  if (el.dataset.tip) return el.dataset.tip;
  const t = el.getAttribute('title');
  if (t && t.trim()) {
    el.dataset.tip = t.trim();
    el.removeAttribute('title');
    return el.dataset.tip;
  }
  // An empty title is a deliberate "nothing to say here" in several views.
  if (t !== null) el.removeAttribute('title');
  return '';
}

function helpFor(node) {
  const el = node && node.closest ? node.closest('[data-tip], [title]') : null;
  return el && textFor(el) ? el : null;
}

function place(el) {
  const r = el.getBoundingClientRect();
  tip.style.maxWidth = `${Math.min(340, window.innerWidth - EDGE * 2)}px`;
  const t = tip.getBoundingClientRect();

  let left = r.left + r.width / 2 - t.width / 2;
  left = Math.max(EDGE, Math.min(left, window.innerWidth - t.width - EDGE));

  let top = r.bottom + GAP;
  let above = false;
  if (top + t.height > window.innerHeight - EDGE && r.top - t.height - GAP > EDGE) {
    top = r.top - t.height - GAP;
    above = true;
  }

  tip.style.left = `${Math.round(left)}px`;
  tip.style.top = `${Math.round(top)}px`;
  tip.dataset.above = above ? '1' : '0';
}

function show(el) {
  const text = textFor(el);
  if (!text) return;
  surface();
  if (anchor && anchor !== el) anchor.removeAttribute('aria-describedby');
  anchor = el;
  tip.textContent = text;
  tip.hidden = false;
  // Measured only once it is in flow, so placement runs after it has a size.
  place(el);
  requestAnimationFrame(() => tip.classList.add('is-in'));
  el.setAttribute('aria-describedby', 'tip');
}

function hide() {
  clearTimeout(timer);
  pinned = false;
  if (!tip || tip.hidden) return;
  tip.classList.remove('is-in');
  tip.hidden = true;
  if (anchor) anchor.removeAttribute('aria-describedby');
  anchor = null;
}

export function initTooltips() {
  surface();

  document.addEventListener('pointerover', (e) => {
    if (pinned) return;
    const el = helpFor(e.target);
    if (!el) { if (anchor) hide(); return; }
    if (el === anchor) return;
    clearTimeout(timer);
    timer = setTimeout(() => show(el), DELAY);
  });

  document.addEventListener('pointerout', (e) => {
    if (pinned) return;
    if (helpFor(e.target) === anchor) { clearTimeout(timer); hide(); }
  });

  /* A tap has no hover, and someone who has just seen the cursor turn into a
   * question mark is entitled to click it and be answered. */
  document.addEventListener('click', (e) => {
    const el = helpFor(e.target);
    if (!el) { hide(); return; }
    // Buttons and links keep their own job; the tooltip rides along on hover only.
    if (el.closest('button, a, [data-goto]')) return;
    e.preventDefault();
    if (pinned && el === anchor) { hide(); return; }
    clearTimeout(timer);
    show(el);
    pinned = true;
  });

  document.addEventListener('focusin', (e) => {
    const el = helpFor(e.target);
    if (el) { clearTimeout(timer); show(el); } else hide();
  });
  document.addEventListener('focusout', hide);

  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') hide(); });
  window.addEventListener('resize', hide);
  window.addEventListener('scroll', hide, true);
}
