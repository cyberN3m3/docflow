// DocFlow dashboard. Without JavaScript the plain forms still work; this adds:
// toasts, drop-anywhere, the merge order list, filters, hold-to-delete,
// local times and live status updates (no page reloads).
(() => {
  'use strict';
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
  const reduceMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const plural = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;

  // ---------- times in the viewer's own time zone ----------
  const pad = (n) => String(n).padStart(2, '0'); // clock digits (17:05); taste-skill-ignore
  const sameDay = (a, b) => a.toDateString() === b.toDateString();
  $$('time[datetime]').forEach((el) => {
    const d = new Date(el.getAttribute('datetime'));
    if (Number.isNaN(d.getTime())) return;
    const now = new Date();
    const yesterday = new Date(now); yesterday.setDate(now.getDate() - 1);
    const hm = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
    let day;
    if (sameDay(d, now)) day = 'Today';
    else if (sameDay(d, yesterday)) day = 'Yesterday';
    else day = d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: d.getFullYear() === now.getFullYear() ? undefined : 'numeric' });
    el.textContent = `${day} ${hm}`;
    el.title = d.toLocaleString();
  });

  // ---------- toasts: enter and leave by the same edge; timers pause ----------
  const toaster = $('#toaster');
  const dismiss = (t) => {
    if (t.classList.contains('leaving')) return;
    t.classList.add('leaving');
    setTimeout(() => t.remove(), 220);
  };
  const arm = (t) => {
    let left = t.classList.contains('toast-error') ? 8000 : 4000;
    let started = Date.now();
    let timer = setTimeout(() => dismiss(t), left);
    const pause = () => { clearTimeout(timer); left -= Date.now() - started; };
    const resume = () => { started = Date.now(); clearTimeout(timer); timer = setTimeout(() => dismiss(t), Math.max(left, 1000)); };
    t.addEventListener('pointerenter', pause);
    t.addEventListener('pointerleave', resume);
    document.addEventListener('visibilitychange', () => (document.hidden ? pause() : resume()));
    $('.toast-close', t)?.addEventListener('click', () => dismiss(t));
  };
  const toast = (message, kind = 'info') => {
    if (!toaster) return;
    const li = document.createElement('li');
    li.className = `toast toast-${kind}`;
    li.setAttribute('role', kind === 'error' ? 'alert' : 'status');
    const text = document.createElement('span');
    text.className = 'toast-text'; text.textContent = message;
    const close = document.createElement('button');
    close.type = 'button'; close.className = 'toast-close'; close.setAttribute('aria-label', 'Dismiss');
    close.innerHTML = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6 6 18"/></svg>';
    li.append(text, close);
    toaster.append(li);
    while (toaster.children.length > 3) toaster.firstElementChild.remove();
    arm(li);
  };
  $$('.toast').forEach(arm);

  // ---------- tabs, search and counts ----------
  const rows = () => $$('tr[data-job]');
  const shown = $('#shown');
  const noMatch = $('tr.no-match');
  const tabs = $$('.tab[data-filter]');
  const indicator = $('.tab-indicator');
  let filter = 'all';

  const moveIndicator = (tab) => {
    if (!indicator || !tab) return;
    indicator.style.setProperty('--x', `${tab.offsetLeft}px`);
    indicator.style.setProperty('--w', `${tab.offsetWidth / 100}`);
  };
  const applyFilter = () => {
    const q = ($('#search')?.value || '').trim().toLowerCase();
    const all = rows();
    let n = 0;
    all.forEach((r) => {
      const ok = (filter === 'all' || r.dataset.group === filter) && (!q || r.dataset.search.includes(q));
      r.hidden = !ok;
      if (ok) n += 1;
    });
    if (noMatch) noMatch.hidden = n !== 0;
    if (shown) shown.textContent = n === all.length ? plural(all.length, 'file') : `${n} of ${plural(all.length, 'file')}`;
  };
  const recount = () => {
    const all = rows();
    const c = { all: all.length, ready: 0, progress: 0, failed: 0 };
    all.forEach((r) => { c[r.dataset.group] += 1; });
    Object.entries(c).forEach(([k, v]) => $$(`[data-count="${k}"]`).forEach((el) => { el.textContent = v; }));
    applyFilter();
    moveIndicator(tabs.find((t) => t.getAttribute('aria-selected') === 'true'));
  };
  tabs.forEach((tab) => tab.addEventListener('click', () => {
    filter = tab.dataset.filter;
    tabs.forEach((t) => t.setAttribute('aria-selected', String(t === tab)));
    moveIndicator(tab);
    applyFilter();
  }));
  if (indicator) {
    moveIndicator(tabs[0]);
    // Place it first, then let it move: no slide on page load.
    document.fonts?.ready.then(() => { moveIndicator(tabs.find((t) => t.getAttribute('aria-selected') === 'true')); requestAnimationFrame(() => indicator.classList.add('ready')); });
    window.addEventListener('resize', () => moveIndicator(tabs.find((t) => t.getAttribute('aria-selected') === 'true')));
  }
  $('#search')?.addEventListener('input', applyFilter);

  // ---------- hold to delete ----------
  const HOLD_MS = 1200;
  $$('.hold-delete').forEach((btn) => {
    let timer = null;
    let done = false;
    const start = (e) => {
      if (e.type === 'keydown') {
        if (e.repeat || (e.key !== 'Enter' && e.key !== ' ')) return;
        e.preventDefault();
      }
      if (timer) return;
      btn.classList.add('holding');
      timer = setTimeout(() => { done = true; btn.closest('form').submit(); }, reduceMotion() ? 600 : HOLD_MS);
    };
    const cancel = () => {
      if (!timer || done) return;
      clearTimeout(timer); timer = null;
      btn.classList.remove('holding');
    };
    btn.addEventListener('pointerdown', (e) => { if (e.button === 0) start(e); });
    btn.addEventListener('keydown', start);
    ['pointerup', 'pointerleave', 'pointercancel', 'keyup', 'blur'].forEach((ev) => btn.addEventListener(ev, cancel));
    btn.addEventListener('click', (e) => {
      e.preventDefault();
      if (!done && !timer) toast('Press and hold to delete.', 'info');
    });
    btn.addEventListener('contextmenu', (e) => e.preventDefault());
  });

  // ---------- live status: update the row in place ----------
  const tpl = $('#status-tpl');
  const statusEl = (look, label) => {
    const el = tpl.content.querySelector(`[data-look="${look}"]`).cloneNode(true);
    $('.status-label', el).textContent = label;
    return el;
  };
  const update = (row, data) => {
    const cell = $('.status-cell', row);
    let el;
    if (data.status === 'done') {
      row.dataset.group = 'ready';
      el = statusEl('ready', 'Ready');
      const a = document.createElement('a');
      a.className = 'btn btn-secondary btn-sm'; a.href = `/jobs/${row.dataset.job}/download`; a.textContent = 'Download';
      $('.row-actions', row).prepend(a);
    } else if (data.status === 'failed') {
      row.dataset.group = 'failed';
      el = statusEl('failed', 'Failed');
      if (data.error) {
        // Errors can carry the conversion service's raw HTML: keep the words only.
        const words = new DOMParser().parseFromString(data.error, 'text/html').body.textContent.replace(/\s+/g, ' ').trim();
        const err = document.createElement('span');
        err.className = 'file-error'; err.title = words;
        err.textContent = `Couldn't make this PDF: ${words}`;
        $('.file', row).append(err);
      }
    } else if (data.status === 'processing') {
      el = statusEl('progress', row.dataset.kind === 'merge' ? 'Merging' : 'Converting');
    } else {
      return;
    }
    row.dataset.status = data.status;
    if (!reduceMotion()) el.classList.add('swapped');
    cell.replaceChildren(el);
    recount();
  };
  const pollable = () => rows().filter((r) => ['queued', 'processing'].includes(r.dataset.status));
  if (tpl && pollable().length) {
    const tick = async () => {
      const pending = pollable();
      if (!pending.length) return;
      await Promise.all(pending.map(async (row) => {
        try {
          const res = await fetch(`/jobs/${row.dataset.job}/status`, { headers: { Accept: 'application/json' } });
          if (!res.ok) return;
          const data = await res.json();
          if (data.status !== row.dataset.status) update(row, data);
        } catch (e) { /* offline for a moment; try again next tick */ }
      }));
      setTimeout(tick, document.hidden ? 6000 : 2000);
    };
    setTimeout(tick, 2000);
  }

  // ---------- making PDFs ----------
  const convertForm = $('#convert-form');
  const convertInput = $('#convert-file');
  const mergeForm = $('#merge-form');
  const mergeInput = $('#merge-files');
  const panel = $('#merge-panel');
  const list = $('#merge-list');
  if (!convertForm || !panel) return;
  const accepted = new Set(convertInput.accept.split(',').map((s) => s.trim().replace(/^\./, '').toLowerCase()));
  const maxMb = Number($('.page')?.dataset.maxMb || 0);
  const typesText = ($('#types')?.textContent || '').replace(/\s+/g, ' ').trim();
  let mergeFiles = [];
  let nextKey = 1;

  const ext = (f) => (f.name.includes('.') ? f.name.split('.').pop().toLowerCase() : '');
  const isPdf = (f) => ext(f) === 'pdf';
  const size = (b) => (b >= 1048576 ? `${(b / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(b / 1024))} KB`);
  const tooBig = (f) => maxMb && f.size > maxMb * 1048576;
  const toList = (files) => { const dt = new DataTransfer(); files.forEach((f) => dt.items.add(f)); return dt.files; };

  const busy = (button, text) => {
    $$('button').forEach((b) => { b.disabled = true; });
    const label = button && $('.btn-label', button);
    if (!label) return;
    label.classList.add('swapping');
    setTimeout(() => {
      label.innerHTML = '<svg class="spinner" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="8" opacity=".3"/><path d="M20 12a8 8 0 0 0-8-8"/></svg>';
      label.append(text);
      label.classList.remove('swapping');
    }, 120);
  };

  const convert = (file) => {
    if (!accepted.has(ext(file))) return toast(`DocFlow can't convert .${ext(file) || '?'} files. ${typesText.replace(/^Drop[^.]*\.\s*/, '')}`, 'error');
    if (tooBig(file)) return toast(`${file.name} is larger than ${maxMb} MB.`, 'error');
    convertInput.files = toList([file]);
    busy($('[data-pick="convert"]'), 'Uploading…');
    convertForm.submit();
  };

  // Merge list. Reordering slides items to their new place (FLIP), and focus stays on the moved file.
  const renderMerge = (focus) => {
    const before = new Map($$('.merge-item', list).map((li) => [li.dataset.key, li.getBoundingClientRect().top]));
    list.replaceChildren(...mergeFiles.map(({ key, file }, i) => {
      const li = document.createElement('li');
      li.className = 'merge-item'; li.dataset.key = key;
      const pos = document.createElement('span'); pos.className = 'merge-pos num'; pos.textContent = `${i + 1}`;
      const name = document.createElement('span'); name.className = 'merge-name'; name.textContent = file.name; name.title = file.name;
      const sz = document.createElement('span'); sz.className = 'merge-size num'; sz.textContent = size(file.size);
      li.append(pos, name, sz);
      [['up', 'Move up', 'm6 15 6-6 6 6', i === 0], ['down', 'Move down', 'm6 9 6 6 6-6', i === mergeFiles.length - 1],
        ['remove', 'Remove', 'M6 6l12 12M18 6 6 18', false]].forEach(([act, label, d, off]) => {
        const b = document.createElement('button');
        b.type = 'button'; b.className = 'icon-btn'; b.disabled = off; b.dataset.act = act;
        b.setAttribute('aria-label', `${label}: ${file.name}`);
        b.innerHTML = `<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="${d}"/></svg>`;
        b.addEventListener('click', () => {
          const idx = mergeFiles.findIndex((m) => m.key === key);
          if (act === 'remove') {
            mergeFiles.splice(idx, 1);
            return renderMerge({ key: mergeFiles[Math.min(idx, mergeFiles.length - 1)]?.key, act: 'remove' });
          }
          const j = act === 'up' ? idx - 1 : idx + 1;
          [mergeFiles[idx], mergeFiles[j]] = [mergeFiles[j], mergeFiles[idx]];
          renderMerge({ key, act });
        });
        li.append(b);
      });
      return li;
    }));
    if (!reduceMotion()) {
      $$('.merge-item', list).forEach((li) => {
        const was = before.get(li.dataset.key);
        if (was === undefined) return;
        const dy = was - li.getBoundingClientRect().top;
        if (dy) li.animate([{ transform: `translateY(${dy}px)` }, { transform: 'translateY(0)' }], { duration: 200, easing: 'cubic-bezier(0.77, 0, 0.175, 1)' });
      });
    }
    if (focus?.key) {
      const li = $(`.merge-item[data-key="${focus.key}"]`, list);
      const target = li && ($(`[data-act="${focus.act}"]:not(:disabled)`, li) || $('[data-act]:not(:disabled)', li));
      target?.focus();
    }
    const n = mergeFiles.length;
    $('#merge-heading').textContent = n >= 2 ? `Merge ${n} PDFs` : 'Merge PDFs';
    const submit = $('[data-merge-submit] .btn-label');
    submit.textContent = n >= 2 ? `Merge ${n} PDFs` : 'Add at least 2 PDFs';
    $('[data-merge-submit]').disabled = n < 2;
  };

  const addToMerge = (files) => {
    const big = files.find(tooBig);
    if (big) return toast(`${big.name} is larger than ${maxMb} MB.`, 'error');
    const wasHidden = panel.hidden;
    mergeFiles = mergeFiles.concat(files.map((file) => ({ key: String(nextKey++), file })));
    if (mergeFiles.length > 20) { mergeFiles = mergeFiles.slice(0, 20); toast('You can merge up to 20 PDFs at once. The rest were left out.', 'error'); }
    panel.hidden = false;
    renderMerge();
    if (wasHidden) $('#merge-heading').focus({ preventScroll: false });
  };

  const route = (fileList) => {
    const files = [...fileList];
    if (!files.length) return;
    if (files.every(isPdf)) {
      if (!panel.hidden || files.length > 1) return addToMerge(files);
      return toast(`${files[0].name} is already a PDF. Add a second PDF to merge them.`, 'info');
    }
    if (files.length === 1) return convert(files[0]);
    return toast('Convert one document at a time, or drop only PDFs to merge them.', 'error');
  };

  // Clicking the card (not its buttons) opens a picker that takes documents and PDFs alike.
  const anyFiles = $('#any-files');
  $('#upload-card')?.addEventListener('click', (e) => { if (!e.target.closest('button')) anyFiles.click(); });
  anyFiles?.addEventListener('change', () => { route(anyFiles.files); anyFiles.value = ''; });
  $$('[data-pick="convert"]').forEach((b) => b.addEventListener('click', () => convertInput.click()));
  $$('[data-pick="merge"]').forEach((b) => b.addEventListener('click', () => mergeInput.click()));
  $('[data-merge-add]').addEventListener('click', () => mergeInput.click());
  convertInput.addEventListener('change', () => { if (convertInput.files[0]) convert(convertInput.files[0]); });
  mergeInput.addEventListener('change', () => {
    const files = [...mergeInput.files];
    mergeInput.value = '';
    const notPdf = files.find((f) => !isPdf(f));
    if (notPdf) return toast(`${notPdf.name} is not a PDF.`, 'error');
    if (files.length) addToMerge(files);
  });
  $('[data-merge-cancel]').addEventListener('click', () => {
    mergeFiles = []; panel.hidden = true;
    ($('[data-pick="merge"]') || $('h1')).focus();
  });
  $('[data-merge-submit]').addEventListener('click', () => {
    if (mergeFiles.length < 2) return;
    mergeInput.files = toList(mergeFiles.map((m) => m.file));
    busy($('[data-merge-submit]'), 'Uploading…');
    mergeForm.submit();
  });

  // Drop anywhere on the page; the upload card lights up while files are over it.
  let depth = 0;
  const hasFiles = (e) => [...(e.dataTransfer?.types || [])].includes('Files');
  window.addEventListener('dragenter', (e) => { if (hasFiles(e)) { depth += 1; document.body.classList.add('dragging'); } });
  window.addEventListener('dragleave', (e) => { if (hasFiles(e)) { depth = Math.max(0, depth - 1); if (!depth) document.body.classList.remove('dragging'); } });
  window.addEventListener('dragover', (e) => { if (hasFiles(e)) e.preventDefault(); });
  window.addEventListener('drop', (e) => {
    if (!e.dataTransfer?.files.length) return;
    e.preventDefault();
    depth = 0; document.body.classList.remove('dragging');
    route(e.dataTransfer.files);
  });
})();
