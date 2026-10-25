// DocFlow dashboard: drop routing, merge order, filters, local times, delete
// confirmation and status polling. Without JavaScript the plain forms work.
(() => {
  'use strict';
  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

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

  // ---------- delete asks once more ----------
  document.addEventListener('click', (e) => {
    const btn = e.target.closest('[data-confirm]');
    if (!btn || btn.classList.contains('confirming')) return;
    e.preventDefault();
    const label = btn.getAttribute('aria-label');
    btn.classList.add('confirming');
    btn.setAttribute('aria-label', `Click again to confirm: ${label}`);
    setTimeout(() => {
      btn.classList.remove('confirming');
      btn.setAttribute('aria-label', label);
    }, 4000);
  });

  // ---------- tabs and search ----------
  const rows = $$('tr[data-job]');
  const shown = $('#shown');
  const noMatch = $('tr.no-match');
  let filter = 'all';
  const applyFilter = () => {
    const q = ($('#search')?.value || '').trim().toLowerCase();
    let n = 0;
    rows.forEach((r) => {
      const ok = (filter === 'all' || r.dataset.group === filter) && (!q || r.dataset.search.includes(q));
      r.hidden = !ok;
      if (ok) n += 1;
    });
    if (noMatch) noMatch.hidden = n !== 0;
    if (shown) shown.textContent = n === rows.length ? `${rows.length} files` : `${n} of ${rows.length} files`;
  };
  $$('.tab[data-filter]').forEach((tab) => tab.addEventListener('click', () => {
    filter = tab.dataset.filter;
    $$('.tab[data-filter]').forEach((t) => t.setAttribute('aria-selected', String(t === tab)));
    applyFilter();
  }));
  $('#search')?.addEventListener('input', applyFilter);

  // ---------- making PDFs ----------
  const drop = $('#dropzone');
  if (!drop) return;
  const anyFiles = $('#any-files');
  const convertForm = $('#convert-form');
  const convertInput = $('#convert-file');
  const mergeForm = $('#merge-form');
  const mergeInput = $('#merge-files');
  const panel = $('#merge-panel');
  const list = $('#merge-list');
  const errorBox = $('#drop-error');
  const accepted = new Set(convertInput.accept.split(',').map((s) => s.trim().replace(/^\./, '').toLowerCase()));
  const maxMb = Number(drop.closest('.page')?.dataset.maxMb || 0);
  let mergeFiles = [];

  const ext = (f) => (f.name.includes('.') ? f.name.split('.').pop().toLowerCase() : '');
  const isPdf = (f) => ext(f) === 'pdf';
  const size = (b) => (b >= 1048576 ? `${(b / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(b / 1024))} KB`);
  const showError = (msg) => { errorBox.textContent = msg; errorBox.hidden = !msg; };
  const tooBig = (f) => maxMb && f.size > maxMb * 1048576;
  const toList = (files) => { const dt = new DataTransfer(); files.forEach((f) => dt.items.add(f)); return dt.files; };

  const busy = (text) => {
    drop.classList.add('busy');
    $('#drop-title').textContent = text;
    $$('button').forEach((b) => { b.disabled = true; });
  };

  const convert = (file) => {
    if (!accepted.has(ext(file))) return showError(`DocFlow can't convert .${ext(file) || '?'} files. ${$('#types').textContent}`);
    if (tooBig(file)) return showError(`${file.name} is larger than ${maxMb} MB.`);
    convertInput.files = toList([file]);
    busy(`Uploading ${file.name}…`);
    convertForm.submit();
  };

  const renderMerge = () => {
    list.replaceChildren(...mergeFiles.map((f, i) => {
      const li = document.createElement('li');
      li.className = 'merge-item';
      const pos = document.createElement('span'); pos.className = 'merge-pos num'; pos.textContent = `${i + 1}.`;
      const name = document.createElement('span'); name.className = 'merge-name'; name.textContent = f.name;
      const sz = document.createElement('span'); sz.className = 'merge-size num'; sz.textContent = size(f.size);
      li.append(pos, name, sz);
      [['up', 'Move up', 'm6 15 6-6 6 6', i === 0], ['down', 'Move down', 'm6 9 6 6 6-6', i === mergeFiles.length - 1],
        ['remove', 'Remove', 'M6 6l12 12M18 6 6 18', false]].forEach(([act, label, d, off]) => {
        const b = document.createElement('button');
        b.type = 'button'; b.className = 'btn-icon'; b.disabled = off;
        b.setAttribute('aria-label', `${label}: ${f.name}`);
        b.innerHTML = `<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="${d}"/></svg>`;
        b.addEventListener('click', () => {
          if (act === 'remove') mergeFiles.splice(i, 1);
          else { const j = act === 'up' ? i - 1 : i + 1; [mergeFiles[i], mergeFiles[j]] = [mergeFiles[j], mergeFiles[i]]; }
          renderMerge();
        });
        li.append(b);
      });
      return li;
    }));
    $('[data-merge-count]').textContent = mergeFiles.length;
    $('[data-merge-submit]').disabled = mergeFiles.length < 2;
    $('[data-merge-submit]').textContent = mergeFiles.length < 2 ? 'Add at least 2 PDFs' : `Merge ${mergeFiles.length} PDFs`;
  };

  const addToMerge = (files) => {
    const big = files.find(tooBig);
    if (big) return showError(`${big.name} is larger than ${maxMb} MB.`);
    mergeFiles = mergeFiles.concat(files);
    if (mergeFiles.length > 20) { mergeFiles = mergeFiles.slice(0, 20); showError('You can merge up to 20 PDFs at once; the rest were left out.'); }
    panel.hidden = false;
    renderMerge();
    $('#merge-heading').focus?.();
  };

  const route = (fileList) => {
    const files = [...fileList];
    if (!files.length) return;
    showError('');
    const pdfs = files.filter(isPdf);
    if (pdfs.length === files.length) {
      if (!panel.hidden || files.length > 1) return addToMerge(files);
      return showError(`${files[0].name} is already a PDF. Choose two or more PDFs to merge them.`);
    }
    if (files.length === 1) return convert(files[0]);
    return showError('Convert one document at a time, or choose only PDFs to merge them.');
  };

  drop.addEventListener('click', () => anyFiles.click());
  anyFiles.addEventListener('change', () => { route(anyFiles.files); anyFiles.value = ''; });
  $('[data-pick="convert"]').addEventListener('click', () => convertInput.click());
  $('[data-pick="merge"]').addEventListener('click', () => mergeInput.click());
  $('[data-merge-add]').addEventListener('click', () => mergeInput.click());
  convertInput.addEventListener('change', () => { if (convertInput.files[0]) convert(convertInput.files[0]); });
  mergeInput.addEventListener('change', () => {
    const files = [...mergeInput.files];
    mergeInput.value = '';
    const notPdf = files.find((f) => !isPdf(f));
    if (notPdf) return showError(`${notPdf.name} is not a PDF.`);
    showError('');
    addToMerge(files);
  });
  $('[data-merge-cancel]').addEventListener('click', () => { mergeFiles = []; panel.hidden = true; showError(''); });
  $('[data-merge-submit]').addEventListener('click', () => {
    if (mergeFiles.length < 2) return;
    mergeInput.files = toList(mergeFiles);
    busy(`Uploading ${mergeFiles.length} PDFs…`);
    mergeForm.submit();
  });

  // Drop anywhere on the page.
  let depth = 0;
  window.addEventListener('dragenter', (e) => { if (e.dataTransfer?.types.includes('Files')) { depth += 1; document.body.classList.add('dragging'); } });
  window.addEventListener('dragleave', () => { depth = Math.max(0, depth - 1); if (!depth) document.body.classList.remove('dragging'); });
  window.addEventListener('dragover', (e) => { if (e.dataTransfer?.types.includes('Files')) e.preventDefault(); });
  window.addEventListener('drop', (e) => {
    if (!e.dataTransfer?.files.length) return;
    e.preventDefault();
    depth = 0; document.body.classList.remove('dragging');
    route(e.dataTransfer.files);
  });
})();

// ---------- refresh when an unfinished job changes state ----------
(() => {
  const pending = [...document.querySelectorAll('tr[data-job]')]
    .filter((r) => ['queued', 'processing'].includes(r.dataset.status));
  if (!pending.length) return;
  const timer = setInterval(async () => {
    for (const row of pending) {
      try {
        const res = await fetch(`/jobs/${row.dataset.job}/status`);
        if (!res.ok) continue;
        const { status } = await res.json();
        if (status !== row.dataset.status) { clearInterval(timer); location.reload(); return; }
      } catch (e) { /* network blip; try again next tick */ }
    }
  }, 2000);
})();
