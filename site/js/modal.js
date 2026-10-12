/**
 * A small promise-based modal, so the app never falls back to native
 * confirm()/prompt() — those cannot show a trade ticket, and a dialog that
 * cannot show what you are about to commit to is the wrong dialog.
 */

import { esc } from './format.js';

/**
 * @param {object} opts
 * @param {string} opts.title
 * @param {string} [opts.body]        trusted HTML built by the caller
 * @param {Array}  [opts.fields]      [{ name, label, value, step, hint }]
 * @param {string} [opts.confirmText]
 * @param {string|null} [opts.cancelText]  null removes the cancel button entirely,
 *   for a dialog that states something rather than asking it — there is nothing to
 *   decline, and offering a decline implies the thing can be undone.
 * @param {string} [opts.tone]        'default' | 'danger'
 * A dialog resolves three ways: `null` when cancelled, the collected fields on
 * confirm, and `{ action }` for any other button carrying `data-act`. That third
 * exit exists because a dialog sometimes offers a way *out* of the decision it is
 * asking about — "use the guided setup instead" is not a cancel and not a confirm,
 * and without somewhere for it to resolve, such a button silently does nothing.
 *
 * @returns {Promise<null|Record<string,string>|{action:string}>} null when cancelled
 */
export function modal({ title, body = '', fields = [], confirmText = 'Confirm',
                       cancelText = 'Cancel', tone = 'default' }) {
  return new Promise((resolve) => {
    const scrim = document.createElement('div');
    scrim.className = 'modal-scrim';
    scrim.innerHTML = `
      <div class="modal" role="dialog" aria-modal="true" aria-label="${esc(title)}">
        <div class="modal-head">${esc(title)}</div>
        <div class="modal-body">
          ${body}
          ${fields.length ? `<div class="modal-fields">${fields.map((f) => `
            <div class="field">
              <label for="mf-${esc(f.name)}">${esc(f.label)}</label>
              <input id="mf-${esc(f.name)}" name="${esc(f.name)}" type="number"
                     step="${esc(f.step ?? 'any')}" value="${f.value ?? ''}"
                     placeholder="${esc(f.placeholder ?? '')}">
              ${f.hint ? `<span class="faint" style="font-size:11.5px">${esc(f.hint)}</span>` : ''}
            </div>`).join('')}</div>` : ''}
        </div>
        <div class="modal-foot">
          ${cancelText === null ? '' : `<button class="btn" data-act="cancel">${esc(cancelText)}</button>`}
          <button class="btn ${tone === 'danger' ? 'danger' : 'primary'}" data-act="ok">${esc(confirmText)}</button>
        </div>
      </div>`;

    // Focus goes back where it came from on close, so a keyboard user is not
    // dropped at the top of the page after every dialog.
    const opener = document.activeElement;
    document.body.append(scrim);
    // An input takes focus when there is one. Otherwise Cancel does, never the
    // confirm button: Return on a focused confirm places the order, and a dialog
    // that exists to make you stop and read should not be passed with one key.
    const first = scrim.querySelector('input');
    (first ?? scrim.querySelector('[data-act="cancel"]') ?? scrim.querySelector('[data-act="ok"]')).focus();
    if (first) first.select?.();

    const done = (value) => {
      scrim.classList.add('is-closing');
      setTimeout(() => scrim.remove(), 200);
      document.removeEventListener('keydown', onKey, true);
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus();
      resolve(value);
    };

    const collect = () => Object.fromEntries(
      [...scrim.querySelectorAll('input')].map((i) => [i.name, i.value.trim()]),
    );

    function onKey(e) {
      // Escape closes this dialog and nothing else. Heard first (capture) and
      // stopped, or the app's own Escape would take the drawer underneath with it.
      if (e.key === 'Escape') { e.stopPropagation(); return done(null); }
      if (e.key === 'Enter' && e.target.tagName === 'INPUT') done(collect());
      // Tab stays inside the dialog: aria-modal says the page behind is inert,
      // and focus wandering onto it would make that a lie.
      if (e.key === 'Tab') {
        const stops = [...scrim.querySelectorAll('input, button, a[href], [tabindex]:not([tabindex="-1"])')];
        if (!stops.length) return;
        const at = stops.indexOf(document.activeElement);
        const next = e.shiftKey ? (at <= 0 ? stops.length - 1 : at - 1) : (at === stops.length - 1 ? 0 : at + 1);
        e.preventDefault();
        stops[next].focus();
      }
    }
    document.addEventListener('keydown', onKey, true);

    scrim.addEventListener('click', (e) => {
      if (e.target === scrim) return done(null);
      const act = e.target.closest('[data-act]')?.dataset.act;
      if (!act) return;
      if (act === 'cancel') return done(null);
      if (act === 'ok') return done(collect());
      done({ action: act });
    });
  });
}
