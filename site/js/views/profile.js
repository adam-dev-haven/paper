/**
 * profile.js — the Settings tab.
 *
 * All the actual controls live in settings.js, because the same surface opens as
 * a sheet from the gear or ⌘, anywhere in the app. This file is the tab-shaped
 * mount for it, plus the one thing that only belongs on a full page: the way back
 * into the guided setup.
 */

import { store } from '../app.js';
import { renderSettings } from '../settings.js';
import { esc } from '../format.js';

export async function renderProfile(host) {
  const s = store.state;
  host.innerHTML = `
    <section class="view">
      <div class="section-head">
        <h2>Settings</h2>
        <span class="hint">Every limit here is enforced by the engine.</span>
        <span class="spacer"></span>
        <button class="btn sm" data-start-setup>Run the guided setup again</button>
      </div>
      ${s.profile?.onboarding ? '' : firstTimeNote()}
      <div id="settingsPage"></div>
    </section>`;

  renderSettings(host.querySelector('#settingsPage'), { mode: 'page' });
}

/**
 * Shown on any account that was not built by the guided setup — the presets and
 * anything carried over from an older version. It is the one place in the app
 * where "you probably want the other thing" is worth saying out loud.
 */
function firstTimeNote() {
  return `<div class="note accent" style="margin-bottom:18px">
    <span class="note-icon">›</span>
    <span><strong>These settings came from a preset.</strong> They were not derived from your
    circumstances. The guided setup asks a dozen questions — how much, the job situation, what you would do
    in a 30% fall — and derives every setting below from the answers, flagging any two that contradict each
    other. It takes about two minutes, and everything stays editable.
    <button class="btn sm" data-start-setup style="margin-left:8px">Start it</button></span>
  </div>`;
}
