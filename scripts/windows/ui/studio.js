/* Image Studio -- the page logic. Vanilla JS, no dependencies, no inline handlers (strict CSP).
   Talks only to images-router.py: /studio/* (models, gallery, remote adds), /sdcpp/v1/* (async jobs). */
(() => {
  'use strict';

  // ---------- basics ----------
  const $ = id => document.getElementById(id);
  const qsa = (sel, root) => [...(root || document).querySelectorAll(sel)];
  const store = {
    get(k, d) { try { const v = localStorage.getItem('studio.' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem('studio.' + k, JSON.stringify(v)); } catch (e) { /* private mode */ } },
  };
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const fmtTime = s => s < 60 ? `${Math.round(s)} s` : `${Math.floor(s / 60)} min ${String(Math.round(s % 60)).padStart(2, '0')} s`;
  const gbs = n => `${(n / 1e9).toFixed(n >= 1e10 ? 0 : 1)} GB`;
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const snap = v => clamp(Math.round(v / 32) * 32, 256, 2048);
  const num = (id, def) => { const v = $(id).value; return v === '' || isNaN(Number(v)) ? def : Number(v); };
  const JSONH = { 'Content-Type': 'application/json' };
  function toast(m) { const t = $('toast'); t.textContent = m; t.classList.add('show'); clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.remove('show'), 3200); }
  async function api(path, opt) {
    const r = await fetch(path, Object.assign({ cache: 'no-store' }, opt || {}));
    const txt = await r.text(); let j = null; try { j = JSON.parse(txt); } catch (e) { /* not JSON */ }
    if (!r.ok) throw new Error((j && j.error && j.error.message) || txt.slice(0, 200) || `HTTP ${r.status}`);
    return j;
  }
  const post = (path, body) => api(path, { method: 'POST', headers: JSONH, body: JSON.stringify(body || {}) });
  const loadImg = url => new Promise((ok, no) => { const im = new Image(); im.onload = () => ok(im); im.onerror = no; im.src = url; });

  // ---------- state ----------
  const S = {
    st: null, models: [], model: null, caps: {}, mode: 'gen', refs: [], init: null, end: null,
    ratio: '1:1', tier: 'M', custom: false, def: {}, jobs: [], focus: null, current: null, batch: [],
    lastSeed: null, maskDirty: false, inp: { fill: 'fill', area: 'whole' },
  };
  const M = () => S.models.find(m => m.id === S.model) || null;
  const U = () => (M() && M().ui) || {};
  const isVideo = () => !!(M() && M().kind === 'video');
  const fam = id => (S.st && S.st.families && S.st.families[id]) || null;
  const famLabel = id => (fam(id) || {}).label || id || '';

  // ---------- theme ----------
  const root = document.documentElement;
  const theme = store.get('theme', null); if (theme) root.dataset.theme = theme;
  $('theme').onclick = () => {
    const dark = root.dataset.theme ? root.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
    root.dataset.theme = dark ? 'light' : 'dark'; store.set('theme', root.dataset.theme);
  };

  // ---------- models ----------
  async function refreshModels() {
    clearTimeout(refreshModels.t);
    let st;
    try { st = await api('/studio/models'); }
    catch (e) { setDot('bad'); $('m-meta').textContent = 'router offline — retrying'; refreshModels.t = setTimeout(refreshModels, 4000); return; }
    S.st = st; S.models = st.models;
    if (!S.model || !S.models.some(m => m.id === S.model)) {
      const saved = store.get('model', null);
      const ok = id => S.models.some(m => m.id === id && !(m.missing && m.missing.length));
      S.model = ok(saved) ? saved : (st.current || st.default);
      applyModelDefaults(); setupTabs();
    }
    renderModelButton(); renderBudget();
    if (!$('model-pop').hidden) renderModelList();
    const m = M();
    if (m && m.state === 'ready' && !S.caps[m.id]) await loadCaps(m.id);
    updateGo();
    $('dl-pill').hidden = !st.downloads;
    if (st.downloads && !AM.poll) pollJobs();
    refreshModels.t = setTimeout(refreshModels, st.models.some(x => x.state === 'loading') ? 2000 : 10000);
  }
  function setDot(cls) { $('m-dot').className = 'dot ' + (cls || ''); }
  const stateLabel = m => m.missing && m.missing.length ? 'files missing' : ({ ready: 'loaded', loading: 'loading…', failed: 'failed', stopped: 'not loaded' })[m.state] || m.state;
  function renderModelButton() {
    const m = M(); if (!m) return;
    $('m-name').textContent = m.label;
    const fl = famLabel(m.family);
    $('m-meta').textContent = [m.kind === 'video' ? 'video' : null, fl && !m.label.includes(fl) ? fl : null, stateLabel(m)].filter(Boolean).join(' · ');
    setDot(m.state === 'ready' ? 'ok' : m.state === 'loading' ? 'busy' : m.state === 'failed' ? 'bad' : '');
    const notes = [];
    if (m.state === 'failed') notes.push(`⚠ ${m.error || 'failed to load'} — pick it again to retry.`);
    if (m.licence) notes.push(`Licence: ${m.licence}.`);
    $('model-note').hidden = !notes.length; $('model-note').textContent = notes.join(' ');
    $('model-note').className = 'hint' + (m.state === 'failed' ? ' bad' : '');
  }
  function renderBudget() {
    const st = S.st || {}; const pct = st.budget_gb ? clamp(st.used_gb / st.budget_gb * 100, 0, 100) : 0;
    $('budget-bar').style.width = `${pct}%`; $('budget-txt').textContent = `${st.used_gb || 0} / ${st.budget_gb || 0} GB`;
  }
  async function loadCaps(id) {
    try { S.caps[id] = await api(`/sdcpp/v1/capabilities?model=${encodeURIComponent(id)}`); if (id === S.model) applyCaps(); } catch (e) { /* not ready yet */ }
  }

  // model picker
  let mpFilter = 'all';
  function openPicker() { $('model-pop').hidden = false; $('model-btn').setAttribute('aria-expanded', 'true'); renderModelList(); $('model-search').focus(); }
  function closePicker() { $('model-pop').hidden = true; $('model-btn').setAttribute('aria-expanded', 'false'); }
  $('model-btn').onclick = () => $('model-pop').hidden ? openPicker() : closePicker();
  $('model-search').oninput = renderModelList;
  qsa('#model-filter .chip').forEach(b => b.onclick = () => { mpFilter = b.dataset.f; qsa('#model-filter .chip').forEach(x => x.setAttribute('aria-pressed', String(x === b))); renderModelList(); });
  document.addEventListener('pointerdown', e => { if (!$('model-pop').hidden && !e.target.closest('#model-pop') && !e.target.closest('#model-btn')) closePicker(); });
  function renderModelList() {
    const q = $('model-search').value.trim().toLowerCase(), box = $('m-list'); box.innerHTML = '';
    const pass = m => (!q || `${m.label} ${m.description} ${famLabel(m.family)}`.toLowerCase().includes(q)) &&
      (mpFilter === 'all' || (mpFilter === 'loaded' ? m.state === 'ready' || m.state === 'loading' : (m.kind || 'image') === mpFilter));
    const groups = [['Image models', S.models.filter(m => m.kind !== 'video' && !m.user)], ['Video models', S.models.filter(m => m.kind === 'video' && !m.user)],
      ['Added from remotes', S.models.filter(m => m.user)]];
    for (const [title, list] of groups) {
      const shown = list.filter(pass); if (!shown.length) continue;
      const h = document.createElement('div'); h.className = 'm-group'; h.textContent = title; box.appendChild(h);
      for (const m of shown) {
        const card = document.createElement('div'); card.className = 'm-card' + (m.id === S.model ? ' sel' : '');
        card.setAttribute('role', 'option'); card.setAttribute('aria-selected', String(m.id === S.model)); card.tabIndex = 0;
        const miss = m.missing && m.missing.length;
        card.innerHTML = `<span class="dotcell"><span class="dot ${m.state === 'ready' ? 'ok' : m.state === 'loading' ? 'busy' : m.state === 'failed' ? 'bad' : ''}"></span></span>
          <span class="t">${esc(m.label)}${m.kind === 'video' ? ' <span class="badge video">video</span>' : ''}${m.nsfw ? ' <span class="badge nsfw">NSFW</span>' : ''}${m.ui && m.ui.edit ? ' <span class="badge">edit</span>' : ''}</span>
          <span class="side"><span>${esc(stateLabel(m))}</span><span>${esc(m.vram_gb)} GB</span><button type="button" class="pin" aria-pressed="${m.pinned ? 'true' : 'false'}" title="Keep loaded (never evicted)">${m.pinned ? '📌 pinned' : 'pin'}</button></span>
          <span class="d">${esc(famLabel(m.family))}${m.description ? ' — ' + esc(m.description) : ''}${miss ? ' · <b>files missing</b>' : ''}<br><small>${esc(m.licence || '')}</small></span>`;
        const choose = () => { if (miss) { toast('This model\'s files are not on disk'); return; } selectModel(m.id); closePicker(); };
        card.onclick = e => { if (e.target.closest('.pin')) return; choose(); };
        card.onkeydown = e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); choose(); } };
        card.querySelector('.pin').onclick = async () => {
          try { await post('/studio/models/pin', { model: m.id, pin: !m.pinned }); toast(m.pinned ? `${m.label} unpinned` : `${m.label} pinned: it stays loaded`); refreshModels(); }
          catch (e) { toast(e.message); }
        };
        box.appendChild(card);
      }
    }
    if (!box.children.length) box.innerHTML = '<p class="hint">No model matches.</p>';
  }
  async function selectModel(id) {
    S.model = id; store.set('model', id);
    applyModelDefaults(); applyCaps(); setupTabs(); renderModelButton(); updateGo(); loadGallery(true, true);
    const m = M();
    if (m && m.state !== 'ready' && m.state !== 'loading') {
      try { await post('/studio/models/load', { model: id }); toast(`Loading ${m.label}…`); } catch (e) { toast(`Could not load: ${e.message}`); }
    }
    refreshModels();
  }

  function applyCaps() {
    const c = S.caps[S.model] || {}, u = U();
    const fill = (sel, items, cur) => { const s = $(sel), prev = s.value; s.innerHTML = ''; for (const it of items) { const o = document.createElement('option'); o.value = o.textContent = it; s.appendChild(o); } s.value = items.includes(cur) ? cur : items.includes(prev) ? prev : items[0]; };
    fill('sampler', c.samplers || [u.sampler || 'euler'], u.sampler || 'euler');
    fill('scheduler', c.schedulers || ['default'], 'default');
    fill('hires-up', (c.upscalers || [{ name: 'Latent' }]).map(x => x.name), 'Latent');
    const loras = c.loras || [];
    $('d-lora').hidden = !loras.length; $('lora-hint').textContent = loras.length ? `${loras.length} available` : '';
    if (c.preview_modes) for (const o of $('preview').options) o.disabled = !c.preview_modes.includes(o.value);
    if ($('preview').selectedOptions[0] && $('preview').selectedOptions[0].disabled) $('preview').value = 'proj';
  }
  function applyModelDefaults() {
    const u = U(), v = isVideo();
    S.def = { steps: u.fixed_steps || u.steps || 20, cfg: u.cfg != null ? u.cfg : 1, frames: u.frames || 49 };
    setSlider('steps', S.def.steps); setSlider('cfg', S.def.cfg);
    $('steps').disabled = $('steps-r').disabled = !!u.fixed_steps;
    $('steps-note').textContent = u.fixed_steps ? 'fixed by this model' : '';
    $('imgcfg').value = ''; $('shift').value = ''; $('eta').value = ''; $('clipskip').value = u.clip_skip != null ? u.clip_skip : '';
    if (u.sampler && [...$('sampler').options].some(o => o.value === u.sampler)) $('sampler').value = u.sampler;
    $('alpha-box').hidden = !u.alpha || v; if (!u.alpha) $('alpha').checked = false;
    // size: the model's own shape at the medium tier
    const w = u.width || 1024, h = u.height || 1024, ar = w / h;
    S.ratio = RATIOS.reduce((best, r) => Math.abs(r[1] / r[2] - ar) < Math.abs(best[1] / best[2] - ar) ? r : best, RATIOS[0])[0];
    S.tier = 'M'; S.custom = false; $('cw').value = ''; $('ch').value = '';
    if (v) {
      const fr = $('frames'), max = u.max_frames || 121;
      fr.max = $('frames-r').max = max; setSlider('frames', clamp(S.def.frames, 9, max));
      $('fps').value = String(u.fps || 24); if (!$('fps').value) $('fps').value = '24';
    }
    $('d-hires').hidden = v;
    renderTiers(); renderSizes(); updateNotes();
  }

  // ---------- tabs / modes ----------
  const MODES = {
    gen: { tab: 'Generate', go: 'Generate', doing: 'Generating', label: '', note: '', ph: 'Describe the image you want…' },
    edit: { tab: 'Edit', go: 'Apply edit', doing: 'Editing', label: 'Images to edit', note: 'Describe the change. Several references: call them image 1, image 2…', ph: 'Describe the change — e.g. "make it night, keep everything else"' },
    inpaint: { tab: 'Inpaint', go: 'Inpaint', doing: 'Inpainting', label: 'Image to inpaint', note: 'Paint over the area to repaint (right), then describe what goes there.', ph: 'Describe what should appear in the painted area' },
    img2img: { tab: 'Image→Image', go: 'Transform', doing: 'Transforming', label: 'Starting image', note: 'The image is the starting point; strength sets how far it moves.', ph: 'Describe the target look' },
    t2v: { tab: 'Text → Video', go: 'Generate video', doing: 'Generating video', label: '', note: '', ph: 'Describe the scene and the motion…' },
    i2v: { tab: 'Image → Video', go: 'Animate', doing: 'Animating', label: 'First frame', note: 'The video starts from this image. Describe the motion.', ph: 'Describe what moves and how — e.g. "the fox turns its head, snow falls"' },
  };
  function allowed(mode) {
    const u = U();
    if (isVideo()) return mode === 't2v' ? u.t2v !== false : mode === 'i2v' ? !!u.i2v : false;
    return mode === 'edit' ? !!u.edit : ['gen', 'inpaint', 'img2img'].includes(mode);
  }
  function setupTabs() {
    const list = isVideo() ? ['t2v', 'i2v'] : ['gen', 'edit', 'inpaint', 'img2img'];
    const box = $('tabs'); box.innerHTML = '';
    for (const k of list) {
      const b = document.createElement('button'); b.type = 'button'; b.setAttribute('role', 'tab'); b.dataset.mode = k; b.textContent = MODES[k].tab;
      b.disabled = !allowed(k); if (b.disabled) b.title = k === 'edit' ? 'This model does not do instruction edits — use Inpaint or Image→Image' : 'Not supported by this model';
      b.onclick = () => { if (b.disabled) return; setMode(k); if (needsSource(k) && !sources().length) $('file').click(); };
      b.onkeydown = e => {
        if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
        const tabs = qsa('[role="tab"]:not(:disabled)', box), i = tabs.indexOf(b), n = tabs[(i + (e.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length];
        n.focus(); n.click();
      };
      box.appendChild(b);
    }
    if (!list.includes(S.mode) || !allowed(S.mode)) S.mode = list.find(allowed) || list[0];
    setMode(S.mode);
  }
  const needsSource = m => ['edit', 'inpaint', 'img2img', 'i2v'].includes(m);
  function setMode(m) {
    S.mode = m; const D = MODES[m], v = isVideo();
    qsa('#tabs [role="tab"]').forEach(b => { const on = b.dataset.mode === m; b.setAttribute('aria-selected', String(on)); b.tabIndex = on ? 0 : -1; });
    $('src-box').hidden = !needsSource(m);
    $('end-box').hidden = !(m === 'i2v' && U().end_image);
    $('src-label').textContent = D.label; $('tabnote').textContent = D.note; $('tabnote').hidden = !D.note;
    $('go-label').textContent = D.go; $('prompt').placeholder = D.ph;
    $('strength-box').hidden = !(m === 'img2img' || m === 'inpaint');
    $('inpaint-box').hidden = m !== 'inpaint';
    $('video-box').hidden = !v;
    $('alpha-box').hidden = !U().alpha || v || m !== 'gen';
    if (m === 'inpaint') $('strength').value = FILL[S.inp.fill].s; else if (m === 'img2img' && Number($('strength').value) === 1) $('strength').value = 0.65;
    $('strength-val').textContent = Number($('strength').value).toFixed(2);
    if (needsSource(m) && sources().length && !v) S.ratio = 'src';
    if (!needsSource(m) && S.ratio === 'src') S.ratio = '1:1';
    renderRefs(); renderSizes(); renderInpaintOpts(); renderPaint(); updateNotes(); updateGo();
  }

  // ---------- sources ----------
  const MAXPX = 2048 * 2048;     // sources above this are scaled down on load: the models work at ~1 MP anyway
  const sources = () => S.mode === 'edit' ? S.refs : (S.init ? [S.init] : []);
  function renderRefs() {
    const fillBox = (box, list, remove) => {
      box.innerHTML = '';
      list.forEach((r, i) => {
        const d = document.createElement('div'); d.className = 'ref';
        d.innerHTML = `<img alt="Source ${i + 1}"><button type="button" aria-label="Remove">×</button>${list.length > 1 ? `<span>image ${i + 1}</span>` : ''}`;
        d.querySelector('img').src = r.url; d.querySelector('button').onclick = () => remove(i); box.appendChild(d);
      });
    };
    const list = sources();
    fillBox($('refs'), list, i => { if (S.mode === 'edit') S.refs.splice(i, 1); else S.init = null; renderRefs(); renderSizes(); renderPaint(); });
    fillBox($('refs-end'), S.end ? [S.end] : [], () => { S.end = null; renderRefs(); });
    const max = U().max_refs || 3;
    $('src-note').textContent = list.length ? `${list[0].w}×${list[0].h}${S.mode === 'edit' ? ` · ${list.length}/${max}` : ''}` : 'required';
  }
  function addImage(url, target) {
    return loadImg(url).then(im => {
      const r = { url, w: im.naturalWidth, h: im.naturalHeight, img: im };
      if (r.w * r.h > MAXPX) {
        const k = Math.sqrt(MAXPX / (r.w * r.h)), c = document.createElement('canvas');
        c.width = Math.round(r.w * k); c.height = Math.round(r.h * k); c.getContext('2d').drawImage(im, 0, 0, c.width, c.height);
        Object.assign(r, { url: c.toDataURL('image/png'), w: c.width, h: c.height, img: c });
        toast(`Large image scaled to ${r.w}×${r.h} for editing`);
      }
      if (target === 'end') { S.end = r; renderRefs(); return; }
      if (!needsSource(S.mode)) setMode(isVideo() ? 'i2v' : U().edit ? 'edit' : 'img2img');
      if (S.mode === 'edit') { const max = U().max_refs || 3; if (S.refs.length >= max) { toast(`Up to ${max} reference images`); return; } S.refs.push(r); }
      else { S.init = r; S.maskDirty = false; }
      if (!isVideo()) S.ratio = 'src';
      renderRefs(); renderSizes(); renderPaint();
    }).catch(() => toast('That file is not an image I can read'));
  }
  const readFile = f => new Promise(ok => { const rd = new FileReader(); rd.onload = () => ok(rd.result); rd.readAsDataURL(f); });
  async function addFiles(files, target) { for (const f of files) if (f.type.startsWith('image/')) await addImage(await readFile(f), target); }
  function wireDrop(btn, input, target) {
    btn.onclick = () => input.click();
    input.onchange = e => { addFiles(e.target.files, target); e.target.value = ''; };
    ['dragenter', 'dragover'].forEach(ev => btn.addEventListener(ev, e => { e.preventDefault(); e.stopPropagation(); btn.classList.add('over'); }));
    ['dragleave', 'drop'].forEach(ev => btn.addEventListener(ev, e => { e.preventDefault(); btn.classList.remove('over'); }));
    btn.addEventListener('drop', e => { e.stopPropagation(); addFiles(e.dataTransfer.files, target); });
  }
  wireDrop($('drop'), $('file'), 'src'); wireDrop($('drop-end'), $('file-end'), 'end');
  document.addEventListener('paste', e => {
    if (/^(INPUT|TEXTAREA)$/.test(document.activeElement && document.activeElement.tagName) && !(e.clipboardData && e.clipboardData.files.length)) return;
    const fs = [...((e.clipboardData && e.clipboardData.files) || [])]; if (fs.length) { addFiles(fs, 'src'); toast('Image pasted'); }
  });

  // ---------- size ----------
  const RATIOS = [['1:1', 1, 1], ['4:3', 4, 3], ['3:4', 3, 4], ['3:2', 3, 2], ['2:3', 2, 3], ['16:9', 16, 9], ['9:16', 9, 16], ['21:9', 21, 9]];
  const TIERS_IMG = [['S', 0.5, 'Small · fast drafts'], ['M', 1, 'Medium · the model\'s size'], ['L', 1.6, 'Large · slower']];
  const TIERS_VID = [['M', 1, 'Native size'], ['S', 0.5, 'Half the pixels · faster']];
  function renderTiers() {
    const sel = $('tier'), list = isVideo() ? TIERS_VID : TIERS_IMG; sel.innerHTML = '';
    for (const [k, , l] of list) { const o = document.createElement('option'); o.value = k; o.textContent = l; sel.appendChild(o); }
    sel.value = list.some(t => t[0] === S.tier) ? S.tier : 'M';
  }
  function renderSizes() {
    const box = $('ratios'); box.innerHTML = '';
    const src = needsSource(S.mode) && sources()[0] && !isVideo();
    const list = (src ? [['src', 0, 0]] : []).concat(RATIOS);
    if (S.ratio === 'src' && !src) S.ratio = '1:1';
    for (const [k, a, b] of list) {
      const bt = document.createElement('button'); bt.type = 'button'; bt.className = 'ratio'; bt.setAttribute('role', 'radio');
      bt.setAttribute('aria-checked', String(!S.custom && S.ratio === k));
      const i = document.createElement('i'); const r = k === 'src' ? sources()[0].w / sources()[0].h : a / b;
      i.style.width = `${Math.round(r >= 1 ? 22 : 22 * r)}px`; i.style.height = `${Math.round(r >= 1 ? 22 / r : 22)}px`;
      bt.appendChild(i); bt.append(k === 'src' ? 'Source' : k);
      bt.onclick = () => { S.ratio = k; S.custom = false; $('cw').value = ''; $('ch').value = ''; renderSizes(); };
      box.appendChild(bt);
    }
    const [w, h] = dims(); $('size-note').textContent = `${w}×${h}${S.custom ? ' (custom)' : ''}`;
    updateNotes();
  }
  $('tier').onchange = () => { S.tier = $('tier').value; S.custom = false; renderSizes(); };
  $('cw').oninput = $('ch').oninput = () => { S.custom = !!($('cw').value && $('ch').value); renderSizes(); };
  function dims() {
    if (S.custom) return [snap(num('cw', 1024)), snap(num('ch', 1024))];
    const u = U(), base = (u.width || 1024) * (u.height || 1024);
    const t = (isVideo() ? TIERS_VID : TIERS_IMG).find(x => x[0] === S.tier) || ['M', 1];
    let ar;
    if (S.ratio === 'src' && sources()[0]) ar = sources()[0].w / sources()[0].h;
    else { const r = RATIOS.find(x => x[0] === S.ratio) || RATIOS[0]; ar = r[1] / r[2]; }
    const area = base * t[1], w = Math.sqrt(area * ar);
    return [snap(w), snap(w / ar)];
  }

  // ---------- sliders with model defaults ----------
  function setSlider(id, v) { $(id).value = v; $(id + '-r').value = v; markSlider(id); }
  function markSlider(id) {
    const v = Number($(id).value), d = S.def[id];
    $(id + '-sl').classList.toggle('mod', d != null && v !== Number(d));
  }
  for (const id of ['steps', 'cfg', 'frames']) {
    $(id + '-r').addEventListener('input', () => { $(id).value = $(id + '-r').value; markSlider(id); updateNotes(); });
    $(id).addEventListener('input', () => { $(id + '-r').value = $(id).value; markSlider(id); updateNotes(); });
    $(id + '-sl').querySelector('.reset').onclick = () => { setSlider(id, S.def[id]); updateNotes(); };
  }
  $('frames').addEventListener('change', () => { const v = Math.round((num('frames', 49) - 1) / 4) * 4 + 1; setSlider('frames', clamp(v, 9, Number($('frames').max))); updateNotes(); });

  function updateNotes() {
    const u = U(), cfg = num('cfg', u.cfg || 1), neg = $('neg').value.trim(), v = isVideo();
    $('neg-note').textContent = cfg <= 1 ? 'inactive at CFG 1' : `active (CFG ${cfg})`;
    let n = u.note || '';
    if (neg && cfg <= 1) n = 'Your negative prompt is IGNORED at CFG 1 — raise CFG (e.g. 2–3) for it to work; that roughly doubles the time. ' + n;
    $('cfg-note').textContent = cfg <= 1 && neg ? 'negative prompt off' : '';
    $('go-hint').textContent = n; $('go-hint').className = 'hint' + (neg && cfg <= 1 ? ' warn' : '');
    $('adv-hint').textContent = `${$('sampler').value || u.sampler || ''}${$('clipskip').value ? ' · clip skip ' + $('clipskip').value : ''}`;
    $('hires-hint').textContent = $('hires').checked ? `×${$('hires-scale').value}` : 'off';
    if (v) {
      const fr = num('frames', 49), fps = Number($('fps').value) || 24;
      $('len-note').textContent = `${fr} frames = ${(fr / fps).toFixed(1)} s at ${fps} fps`;
    }
    const [w, h] = dims(), batch = Number($('batch').value) || 1, hs = $('hires').checked && !v ? num('hires-scale', 1.5) : 1;
    const mp = w * h * hs * hs / 1e6, load = v ? w * h * num('frames', 49) / (1280 * 704 * 121) : mp * batch / 6.3;
    $('pixel-warn').hidden = load <= 1;
    $('pixel-warn').textContent = v ? 'A long, large video: this can take many minutes and a lot of GPU memory.'
      : `Big request (${(mp * batch).toFixed(1)} MP in total): it may run out of GPU memory — fewer images or a smaller size is safer.`;
  }
  ['neg', 'clipskip', 'hires', 'hires-scale', 'batch', 'fps', 'sampler'].forEach(id => $(id).addEventListener('input', updateNotes));
  ['hires', 'fps', 'batch', 'sampler'].forEach(id => $(id).addEventListener('change', updateNotes));
  $('seed-rnd').onclick = () => { $('seed').value = ''; $('lock').checked = false; toast('Seed will be random'); };
  $('strength').addEventListener('input', () => { $('strength-val').textContent = Number($('strength').value).toFixed(2); renderInpaintOpts(); });

  // ---------- LoRA ----------
  const loraMeta = path => ((S.st && S.st.loras) || []).find(x => x.file === path);
  $('lora-add').onclick = () => {
    const list = (S.caps[S.model] || {}).loras || []; if (!list.length) return;
    const g = (fam((M() || {}).family) || {}).group;
    const opts = list.map(l => {
      const mt = loraMeta(l.path || l.name), ok = !g || !mt || !mt.group || mt.group === g;
      return { v: l.path || l.name, ok, text: `${mt ? mt.name : l.name}${mt && mt.family ? ` — ${famLabel(mt.family)}` : ''}${ok ? '' : ' (other family: will not work here)'}` };
    }).sort((a, b) => b.ok - a.ok);
    const row = document.createElement('div'); row.className = 'lora-row';
    row.innerHTML = `<select aria-label="LoRA">${opts.map(o => `<option value="${esc(o.v)}">${esc(o.text)}</option>`).join('')}</select><input type="number" value="1" step="0.05" aria-label="LoRA strength"><button class="icon" type="button" aria-label="Remove LoRA">×</button><div class="lora-meta" hidden></div>`;
    const sel = row.querySelector('select'), meta = row.querySelector('.lora-meta');
    const showMeta = () => {
      const mt = loraMeta(sel.value), words = (mt && mt.trained_words) || []; meta.innerHTML = ''; meta.hidden = !words.length;
      if (!words.length) return; meta.append('Trigger words:');
      for (const w of words.slice(0, 12)) {
        const b = document.createElement('button'); b.type = 'button'; b.className = 'chip'; b.textContent = w; b.title = 'Add to the prompt';
        b.onclick = () => { const p = $('prompt'); p.value = p.value.trim() ? `${p.value.replace(/[\s,]+$/, '')}, ${w}` : w; }; meta.appendChild(b);
      }
    };
    sel.onchange = showMeta; showMeta();
    row.querySelector('button.icon').onclick = () => row.remove(); $('loras').appendChild(row);
  };
  const loraList = () => [...$('loras').children].map(r => ({ path: r.querySelector('select').value, multiplier: Number(r.querySelector('input').value) || 1 }));

  // ---------- zoom (viewer + mask painter) ----------
  function Zoom(el, onChange) {
    const z = { s: 1, x: 0, y: 0, max: 32 };
    z.apply = () => { if (z.s <= 1) { z.s = 1; z.x = z.y = 0; } el.style.transform = z.s === 1 ? '' : `translate(${z.x}px, ${z.y}px) scale(${z.s})`; if (onChange) onChange(z); };
    z.reset = () => { z.s = 1; z.apply(); };
    z.at = (cx, cy, s2) => { s2 = clamp(s2, 1, z.max); const r = el.getBoundingClientRect(), k = 1 - s2 / z.s; z.x += (cx - (r.left + r.width / 2)) * k; z.y += (cy - (r.top + r.height / 2)) * k; z.s = s2; z.apply(); };
    z.center = s2 => { const r = el.parentElement.getBoundingClientRect(); z.at(r.left + r.width / 2, r.top + r.height / 2, s2); };
    z.pan = (dx, dy) => { if (z.s > 1) { z.x += dx; z.y += dy; z.apply(); } };
    z.ratio = img => z.s * (img.offsetWidth || 1) / (img.naturalWidth || img.width || img.offsetWidth || 1);
    return z;
  }
  function Pinch(z) {
    const pts = new Map(); let prev = null;
    const mid = () => { const [a, b] = [...pts.values()]; return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2, d: Math.hypot(a.x - b.x, a.y - b.y) }; };
    return {
      down(e) { pts.set(e.pointerId, { x: e.clientX, y: e.clientY }); prev = pts.size === 2 ? mid() : null; return pts.size; },
      move(e) { if (!pts.has(e.pointerId)) return false; pts.set(e.pointerId, { x: e.clientX, y: e.clientY }); if (pts.size !== 2) return false; const m = mid(); if (prev && prev.d > 0) { z.pan(m.x - prev.x, m.y - prev.y); z.at(m.x, m.y, z.s * m.d / prev.d); } prev = m; return true; },
      up(e) { pts.delete(e.pointerId); prev = pts.size === 2 ? mid() : null; return pts.size; },
    };
  }
  const wheelFactor = e => Math.exp(-e.deltaY * (e.deltaMode === 1 ? 0.05 : 0.002));

  // ---------- mask painter ----------
  const mc = $('mask'), mctx = mc.getContext('2d', { willReadFrequently: true });
  let erasing = false, drawing = false, last = null, hand = false, spaceDown = false, panning = null; const undo = [];
  const pz = Zoom($('paint'), z => { $('pz-val').textContent = z.s === 1 ? 'fit' : `${Math.round(z.ratio($('paint-img')) * 100)}%`; });
  const pinch = Pinch(pz);
  function renderPaint() {
    const on = S.mode === 'inpaint' && !!S.init && !focusJob();
    $('paint').hidden = !on; $('paintbar').hidden = !on;
    if (on) {
      $('view').hidden = true; $('vview').hidden = true; $('empty').hidden = true; $('ov').hidden = true;
      const pi = $('paint-img');
      if (pi.dataset.src !== S.init.url) {
        pi.dataset.src = S.init.url; pi.src = S.init.url;
        mc.width = S.init.w; mc.height = S.init.h; mctx.clearRect(0, 0, mc.width, mc.height); S.maskDirty = false; undo.length = 0; pz.reset();
      }
    } else if (S.current && !focusJob()) showItem(S.current);
    else if (!focusJob()) { $('view').hidden = true; $('vview').hidden = true; $('empty').hidden = false; }
  }
  const pos = e => { const r = mc.getBoundingClientRect(); return [(e.clientX - r.left) * mc.width / r.width, (e.clientY - r.top) * mc.height / r.height]; };
  function stroke(a, b) {
    const scale = mc.width / Math.max(1, mc.getBoundingClientRect().width);
    mctx.globalCompositeOperation = erasing ? 'destination-out' : 'source-over';
    mctx.strokeStyle = 'rgba(249,115,22,.55)'; mctx.lineCap = mctx.lineJoin = 'round'; mctx.lineWidth = Number($('brush').value) * scale;
    mctx.beginPath(); mctx.moveTo(a[0], a[1]); mctx.lineTo(b[0] + 0.01, b[1]); mctx.stroke(); S.maskDirty = true;
  }
  const snapshot = () => { undo.push(mctx.getImageData(0, 0, mc.width, mc.height)); if (undo.length > 30) undo.shift(); };
  const maskHasPixels = () => { const d = mctx.getImageData(0, 0, mc.width, mc.height).data; for (let i = 3; i < d.length; i += 4) if (d[i] > 10) return true; return false; };
  function undoMask() { const u = undo.pop(); if (!u) { toast('Nothing to undo'); return; } mctx.putImageData(u, 0, 0); S.maskDirty = maskHasPixels(); }
  function brushCursor(e) {
    const c = $('brush-cur');
    if (e.pointerType !== 'mouse' || hand || spaceDown || panning) { c.hidden = true; return; }
    const d = Number($('brush').value); c.hidden = false; c.style.width = c.style.height = `${d}px`; c.style.left = `${e.clientX}px`; c.style.top = `${e.clientY}px`;
  }
  mc.addEventListener('mousedown', e => { if (e.button === 1) e.preventDefault(); });
  mc.addEventListener('pointerdown', e => {
    try { mc.setPointerCapture(e.pointerId); } catch (er) { /* synthetic pointer */ }
    if (pinch.down(e) === 2) { if (drawing) { drawing = false; const u = undo.pop(); if (u) { mctx.putImageData(u, 0, 0); S.maskDirty = maskHasPixels(); } } panning = null; return; }
    if (hand || spaceDown || e.button === 1) { panning = { x: e.clientX, y: e.clientY }; $('paint').classList.add('panning'); $('brush-cur').hidden = true; return; }
    if (e.button !== 0) return;
    snapshot(); drawing = true; last = pos(e); stroke(last, last);
  });
  mc.addEventListener('pointermove', e => {
    brushCursor(e);
    if (pinch.move(e)) return;
    if (panning) { pz.pan(e.clientX - panning.x, e.clientY - panning.y); panning = { x: e.clientX, y: e.clientY }; return; }
    if (!drawing) return; const p = pos(e); stroke(last, p); last = p;
  });
  ['pointerup', 'pointercancel'].forEach(ev => mc.addEventListener(ev, e => { pinch.up(e); drawing = false; panning = null; $('paint').classList.remove('panning'); }));
  mc.addEventListener('pointerleave', () => { $('brush-cur').hidden = true; });
  $('canvas').addEventListener('wheel', e => { if ($('paint').hidden || !e.target.closest('#paint')) return; e.preventDefault(); pz.at(e.clientX, e.clientY, pz.s * wheelFactor(e)); }, { passive: false });
  $('pz-in').onclick = () => pz.center(pz.s * 1.5); $('pz-out').onclick = () => pz.center(pz.s / 1.5); $('pz-fit').onclick = () => pz.reset();
  const setHand = on => { hand = on; $('m-hand').setAttribute('aria-pressed', String(on)); $('paint').classList.toggle('hand', on); };
  $('m-hand').onclick = () => setHand(!hand);
  const setTool = er => { erasing = er; setHand(false); $('m-paint').setAttribute('aria-pressed', String(!er)); $('m-erase').setAttribute('aria-pressed', String(er)); };
  $('m-paint').onclick = () => setTool(false); $('m-erase').onclick = () => setTool(true); $('m-undo').onclick = undoMask;
  $('m-clear').onclick = () => { snapshot(); mctx.clearRect(0, 0, mc.width, mc.height); S.maskDirty = false; };
  $('m-invert').onclick = () => {
    snapshot(); const d = mctx.getImageData(0, 0, mc.width, mc.height);
    for (let i = 3; i < d.data.length; i += 4) { const on = d.data[i] > 10; d.data[i - 3] = 249; d.data[i - 2] = 115; d.data[i - 1] = 22; d.data[i] = on ? 0 : 140; }
    mctx.putImageData(d, 0, 0); S.maskDirty = true;
  };

  // ---------- inpaint: what the model is sent ----------
  // sd.cpp mask semantics: white = repaint, black = keep. Built here at the source's resolution.
  const FILL = {
    original: { s: 0.85, note: 'The model starts from what is there now. For changing something while keeping its place, shape and light — strength 0.6–0.9.' },
    fill: { s: 0.9, note: 'The area is first filled in from the surrounding colours, so the old content is gone. For removing something — strength 0.8–1.' },
    noise: { s: 1, note: 'Random noise: the model invents the area freely. Can leave a visible edge on big masks — Surroundings blends better.' },
    blank: { s: 0.95, note: 'Flat grey: a neutral start with nothing of the old content.' },
  };
  function renderInpaintOpts() {
    const I = S.inp, masked = I.area === 'masked';
    qsa('#fillmode .chip').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.v === I.fill)));
    qsa('#areamode .chip').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.v === I.area)));
    $('fill-note').textContent = FILL[I.fill].note + (Number($('strength').value) >= 1 && I.fill !== 'noise' ? ' At strength 1.0 the starting content is ignored — lower it for this choice to matter.' : '');
    $('area-note').textContent = masked ? 'Only the region around the mask (plus padding) is rendered, at ~1 MP, and pasted back — small areas get far more detail. The output keeps the source size.'
      : 'The whole image is re-rendered at the size above; the mask decides what may change.';
    $('mpad-box').hidden = !masked;
    $('mblur-v').textContent = `${$('mblur').value} px`; $('mpad-v').textContent = `${$('mpad').value} px`;
    $('keep').disabled = masked; if (masked) $('keep').checked = true;
    $('size-box').hidden = S.mode === 'inpaint' && masked;
  }
  qsa('#fillmode .chip').forEach(b => b.onclick = () => { S.inp.fill = b.dataset.v; $('strength').value = FILL[S.inp.fill].s; $('strength-val').textContent = Number($('strength').value).toFixed(2); renderInpaintOpts(); });
  qsa('#areamode .chip').forEach(b => b.onclick = () => { S.inp.area = b.dataset.v; renderInpaintOpts(); });
  ['mblur', 'mpad'].forEach(id => $(id).addEventListener('input', renderInpaintOpts));
  function boxBlur(a, w, h, r) {
    if (r < 1) return a;
    const t = new Float32Array(a.length), n = 2 * r + 1, cx = x => x < 0 ? 0 : x >= w ? w - 1 : x, cy = y => y < 0 ? 0 : y >= h ? h - 1 : y;
    for (let y = 0; y < h; y++) { const o = y * w; let s = 0; for (let x = -r; x <= r; x++) s += a[o + cx(x)]; for (let x = 0; x < w; x++) { t[o + x] = s / n; s += a[o + cx(x + r + 1)] - a[o + cx(x - r)]; } }
    for (let x = 0; x < w; x++) { let s = 0; for (let y = -r; y <= r; y++) s += t[cy(y) * w + x]; for (let y = 0; y < h; y++) { a[y * w + x] = s / n; s += t[cy(y + r + 1) * w + x] - t[cy(y - r) * w + x]; } }
    return a;
  }
  function maskAlpha() { const d = mctx.getImageData(0, 0, mc.width, mc.height).data, a = new Float32Array(mc.width * mc.height); for (let i = 0; i < a.length; i++) a[i] = d[i * 4 + 3] > 10 ? 1 : 0; return a; }
  function dilate(a, w, h, r) { if (r < 1) return a; const b = boxBlur(Float32Array.from(a), w, h, r); for (let i = 0; i < b.length; i++) b[i] = b[i] > 1e-4 ? 1 : 0; return b; }
  function feather(a, w, h, r) { if (r < 1) return a; const b = Float32Array.from(a), q = Math.max(1, Math.round(r / 2)); boxBlur(b, w, h, q); return boxBlur(b, w, h, q); }
  function pushPull(d, hole, w, h) {
    // fill holes from the surrounding colours: average known pixels down a pyramid, fill each level from the
    // coarser one (bilinear, or the fill shows 2^n blocks), then blur so the fill is smooth
    const lv = []; let W = w, H = h, c = new Float32Array(w * h * 3), k = new Float32Array(w * h);
    for (let i = 0; i < w * h; i++) { const m = hole[i] ? 0 : 1; k[i] = m; for (let j = 0; j < 3; j++) c[i * 3 + j] = d[i * 4 + j] * m; }
    lv.push({ W, H, c, k });
    while (W > 1 || H > 1) {
      const W2 = (W + 1) >> 1, H2 = (H + 1) >> 1, c2 = new Float32Array(W2 * H2 * 3), k2 = new Float32Array(W2 * H2);
      for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) { const i = y * W + x, q = (y >> 1) * W2 + (x >> 1); k2[q] += k[i]; for (let j = 0; j < 3; j++) c2[q * 3 + j] += c[i * 3 + j]; }
      for (let q = 0; q < W2 * H2; q++) if (k2[q] > 1) { for (let j = 0; j < 3; j++) c2[q * 3 + j] /= k2[q]; k2[q] = 1; }
      W = W2; H = H2; c = c2; k = k2; lv.push({ W, H, c, k });
    }
    const top = lv[lv.length - 1];
    for (let j = 0; j < 3; j++) top.c[j] = top.k[0] > 0 ? top.c[j] / top.k[0] : 128; top.k[0] = 1;
    for (let l = lv.length - 2; l >= 0; l--) {
      const f = lv[l], g = lv[l + 1];
      for (let y = 0; y < f.H; y++) {
        const gy = clamp((y + 0.5) / 2 - 0.5, 0, g.H - 1), y0 = Math.floor(gy), y1 = Math.min(g.H - 1, y0 + 1), fy = gy - y0;
        for (let x = 0; x < f.W; x++) {
          const i = y * f.W + x, r = 1 - f.k[i]; if (r <= 0) continue;
          const gx = clamp((x + 0.5) / 2 - 0.5, 0, g.W - 1), x0 = Math.floor(gx), x1 = Math.min(g.W - 1, x0 + 1), fx = gx - x0;
          const a = (y0 * g.W + x0) * 3, b = (y0 * g.W + x1) * 3, c2 = (y1 * g.W + x0) * 3, e = (y1 * g.W + x1) * 3;
          for (let j = 0; j < 3; j++) f.c[i * 3 + j] += r * ((g.c[a + j] * (1 - fx) + g.c[b + j] * fx) * (1 - fy) + (g.c[c2 + j] * (1 - fx) + g.c[e + j] * fx) * fy);
          f.k[i] = 1;
        }
      }
    }
    const base = lv[0].c;
    for (let j = 0; j < 3; j++) {
      const ch = new Float32Array(w * h); for (let i = 0; i < w * h; i++) ch[i] = base[i * 3 + j];
      boxBlur(ch, w, h, 3); boxBlur(ch, w, h, 3);
      for (let i = 0; i < w * h; i++) if (hole[i]) d[i * 4 + j] = ch[i];
    }
    for (let i = 0; i < w * h; i++) if (hole[i]) d[i * 4 + 3] = 255;
  }
  function prepSource(src, hole, w, h, mode) {
    const c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d'); g.drawImage(src, 0, 0, w, h);
    if (mode === 'original') return c;
    const id = g.getImageData(0, 0, w, h), d = id.data;
    if (mode === 'fill') pushPull(d, hole, w, h);
    else for (let i = 0; i < hole.length; i++) if (hole[i]) { const o = i * 4; if (mode === 'noise') { d[o] = Math.random() * 256; d[o + 1] = Math.random() * 256; d[o + 2] = Math.random() * 256; } else d[o] = d[o + 1] = d[o + 2] = 128; d[o + 3] = 255; }
    g.putImageData(id, 0, 0); return c;
  }
  function alphaCanvas(a, w, h, asMask) {
    const c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d'), id = g.createImageData(w, h), d = id.data;
    for (let i = 0; i < a.length; i++) { const o = i * 4; if (asMask) { d[o] = d[o + 1] = d[o + 2] = a[i] > 0.5 ? 255 : 0; d[o + 3] = 255; } else { d[o] = d[o + 1] = d[o + 2] = 255; d[o + 3] = Math.round(a[i] * 255); } }
    g.putImageData(id, 0, 0); return c;
  }
  function prepInpaint() {
    const src = S.init, w = src.w, h = src.h, blur = Number($('mblur').value), I = S.inp;
    const D = dilate(maskAlpha(), w, h, blur), prepared = prepSource(src.img, D, w, h, I.fill);
    let crop = { x: 0, y: 0, w, h }, W, H;
    if (I.area === 'masked') {
      let x0 = w, y0 = h, x1 = -1, y1 = -1;
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (D[y * w + x]) { if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y; }
      if (x1 < 0) return null;
      const pad = Number($('mpad').value); x0 -= pad; y0 -= pad; x1 += pad + 1; y1 += pad + 1;
      const grow = (a, b, lim, min) => { const need = min - (b - a); if (need > 0) { a -= need / 2; b += need / 2; } if (a < 0) { b -= a; a = 0; } if (b > lim) { a -= b - lim; b = lim; } return [Math.max(0, Math.floor(a)), Math.min(lim, Math.ceil(b))]; };
      [x0, x1] = grow(x0, x1, w, 128); [y0, y1] = grow(y0, y1, h, 128);
      crop = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
      const ar = crop.w / crop.h; W = snap(Math.sqrt(1024 * 1024 * ar)); H = snap(W / ar);
    } else [W, H] = dims();
    const init = document.createElement('canvas'); init.width = W; init.height = H;
    init.getContext('2d').drawImage(prepared, crop.x, crop.y, crop.w, crop.h, 0, 0, W, H);
    const mask = document.createElement('canvas'); mask.width = W; mask.height = H; const mg = mask.getContext('2d');
    mg.imageSmoothingEnabled = false; mg.drawImage(alphaCanvas(D, w, h, true), crop.x, crop.y, crop.w, crop.h, 0, 0, W, H);
    const sameShape = Math.abs((W / H) / (w / h) - 1) < 0.02, blend = I.area === 'masked' || ($('keep').checked && sameShape);
    return { init, mask, W, H, crop, w, h, src: src.img, blend, alpha: blend ? alphaCanvas(feather(D, w, h, blur), w, h, false) : null, skipped: $('keep').checked && !blend };
  }
  async function blendBack(url, P, mime, q) {
    const res = await loadImg(url);
    const out = document.createElement('canvas'); out.width = P.w; out.height = P.h; const g = out.getContext('2d');
    const lay = document.createElement('canvas'); lay.width = P.w; lay.height = P.h; const lg = lay.getContext('2d');
    lg.drawImage(res, P.crop.x, P.crop.y, P.crop.w, P.crop.h); lg.globalCompositeOperation = 'destination-in'; lg.drawImage(P.alpha, 0, 0);
    g.drawImage(P.src, 0, 0, P.w, P.h); g.drawImage(lay, 0, 0);
    return out.toDataURL(mime, q);
  }
  $('show-sent').onclick = () => {
    if (!S.init) { toast('Add an image first'); return; }
    if (!maskHasPixels()) { toast('Paint the area to change first'); return; }
    const P = prepInpaint(), gap = Math.round(P.W / 40), c = document.createElement('canvas'); c.width = P.W * 2 + gap; c.height = P.H;
    const g = c.getContext('2d'); g.fillStyle = '#3a3733'; g.fillRect(0, 0, c.width, c.height); g.drawImage(P.init, 0, 0); g.drawImage(P.mask, P.W + gap, 0);
    openViewer([{ url: c.toDataURL('image/png'), kind: 'image', w: c.width, h: c.height }], 0,
      `Sent to the model: starting image (left) + mask (right, white = repaint) at ${P.W}×${P.H}, strength ${Number($('strength').value).toFixed(2)}` +
      (S.inp.area === 'masked' ? ` — a ${P.crop.w}×${P.crop.h} region of the ${P.w}×${P.h} source, pasted back after` : '') + (P.blend ? '; blended back over the original' : ''));
  };

  // ---------- run + queue ----------
  function uiSnapshot() {
    const hires = { on: $('hires').checked, up: $('hires-up').value, scale: $('hires-scale').value, steps: $('hires-steps').value, den: $('hires-den').value };
    return { mode: S.mode, prompt: $('prompt').value, neg: $('neg').value, ratio: S.ratio, tier: S.tier, custom: S.custom, cw: $('cw').value, ch: $('ch').value,
      steps: $('steps').value, cfg: $('cfg').value, imgcfg: $('imgcfg').value, shift: $('shift').value, eta: $('eta').value, clipskip: $('clipskip').value,
      sampler: $('sampler').value, scheduler: $('scheduler').value, batch: $('batch').value, alpha: $('alpha').checked, cache: $('cache').value,
      preview: $('preview').value, vaetile: $('vaetile').checked, fmt: $('fmt').value, quality: $('quality').value, meta: $('meta').checked, hires,
      loras: loraList(), strength: $('strength').value, inp: Object.assign({ blur: $('mblur').value, pad: $('mpad').value, keep: $('keep').checked }, S.inp),
      frames: $('frames').value, fps: $('fps').value, vfmt: $('vfmt').value };
  }
  function collect(P) {
    const u = U(), v = isVideo(), [w, h] = P ? [P.W, P.H] : dims();
    let prompt = $('prompt').value.trim();
    if (!v && $('alpha').checked && S.mode === 'gen') prompt = `This is an RGBA image with transparency. ${prompt}. The image has alpha channel and the background is transparent.`;
    let seed;
    if ($('seed').value !== '') seed = parseInt($('seed').value, 10);
    else if ($('lock').checked && S.lastSeed != null) seed = S.lastSeed;
    else seed = Math.floor(Math.random() * 2147483647);
    const guidance = { txt_cfg: num('cfg', u.cfg || 1) };
    if ($('imgcfg').value !== '') guidance.img_cfg = num('imgcfg');
    const sp = { sample_method: $('sampler').value || u.sampler || 'euler', scheduler: $('scheduler').value || 'default', guidance };
    if (!u.fixed_steps && $('steps').value !== '') sp.sample_steps = num('steps');
    if ($('shift').value !== '') sp.flow_shift = num('shift');
    if ($('eta').value !== '') sp.eta = num('eta');
    const body = { model: S.model, prompt, negative_prompt: $('neg').value.trim(), width: w, height: h, seed, sample_params: sp,
      preview: $('preview').value, preview_interval: 1, studio: { ui: uiSnapshot(), mode: S.mode } };
    if ($('clipskip').value !== '') body.clip_skip = num('clipskip');
    const loras = loraList(); if (loras.length) body.lora = loras;
    if (v) {
      Object.assign(body, { video_frames: num('frames', 49), fps: Number($('fps').value) || 24, output_format: $('vfmt').value,
        vae_tiling_params: { enabled: true, temporal_tiling: true } });
      if (S.mode === 'i2v') { body.init_image = S.init.url; if (S.end) body.end_image = S.end.url; }
      return body;
    }
    Object.assign(body, { batch_count: Number($('batch').value), output_format: $('fmt').value, output_compression: num('quality', 95),
      embed_image_metadata: $('meta').checked, cache_mode: $('cache').value, vae_tiling_params: { enabled: $('vaetile').checked } });
    if ($('hires').checked) body.hires = { enabled: true, upscaler: $('hires-up').value || 'Latent', scale: num('hires-scale', 1.5), steps: num('hires-steps', 0), denoising_strength: num('hires-den', 0.5) };
    if (S.mode === 'edit') body.ref_images = S.refs.map(r => r.url);
    if (S.mode === 'img2img') { body.init_image = S.init.url; body.strength = Number($('strength').value); }
    if (S.mode === 'inpaint') { body.init_image = P.init.toDataURL('image/png'); body.mask_image = P.mask.toDataURL('image/png'); body.strength = Number($('strength').value); }
    return body;
  }
  function updateGo() {
    const m = M(), ready = m && (m.state === 'ready' || m.state === 'loading' || m.state === 'stopped');
    $('go').disabled = !ready || (m && m.missing && m.missing.length);
    const q = S.jobs.filter(j => j.status === 'queued' || j.status === 'generating').length;
    $('go-label').textContent = (MODES[S.mode] || MODES.gen).go + (q ? ` (queue ${q})` : '');
  }
  async function run() {
    const m = M();
    if (!m) { toast('Pick a model first'); openPicker(); return; }
    if (m.missing && m.missing.length) { toast('This model\'s files are not on disk'); return; }
    if (!$('prompt').value.trim()) { $('prompt').focus(); toast('Write a prompt first'); return; }
    if (needsSource(S.mode) && !sources().length) { toast(S.mode === 'i2v' ? 'Add the first frame' : 'Add an image first'); $('file').click(); return; }
    if (S.mode === 'inpaint' && !(S.maskDirty && maskHasPixels())) { toast('Paint the area to change first'); return; }
    const P = S.mode === 'inpaint' ? prepInpaint() : null;
    if (P && P.skipped) toast('Not blended back: the size you chose has a different shape from the source');
    const body = collect(P), path = isVideo() ? '/sdcpp/v1/vid_gen' : '/sdcpp/v1/img_gen';
    $('go').disabled = true;
    let j;
    try { j = await post(path, body); }
    catch (e) { setStatus(`Could not start: ${e.message}`, true); updateGo(); return; }
    finally { setTimeout(updateGo, 300); }
    const settings = Object.assign({}, body); ['init_image', 'end_image', 'ref_images', 'mask_image', 'studio'].forEach(k => delete settings[k]);
    const job = { id: j.id, model: S.model, kind: isVideo() ? 'video' : 'image', mode: S.mode, settings, studio: body.studio, seed: body.seed,
      w: body.width, h: body.height, started: Date.now(), status: 'queued', P: P && P.blend ? P : null, source: needsSource(S.mode) && sources()[0] ? sources()[0].url : null,
      prompt: $('prompt').value.trim(), steps: [] };
    S.lastSeed = body.seed; S.jobs.push(job); S.focus = job.id; persistJobs(); renderQueue(); renderPaint(); poll();
  }
  $('go').onclick = run;
  $('prompt').addEventListener('keydown', e => { if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); run(); } });
  const live = j => j.status === 'queued' || j.status === 'generating';
  const focusJob = () => S.jobs.find(j => j.id === S.focus && live(j)) || null;
  function persistJobs() {
    store.set('jobs', S.jobs.filter(live).map(j => ({ id: j.id, model: j.model, kind: j.kind, mode: j.mode, settings: j.settings, studio: j.studio,
      seed: j.seed, w: j.w, h: j.h, started: j.started, prompt: j.prompt })));
  }
  async function poll() {
    clearTimeout(poll.t);
    const act = S.jobs.filter(live);
    for (const job of act) {
      let s;
      try { s = await api(`/sdcpp/v1/jobs/${encodeURIComponent(job.id)}`); }
      catch (e) {
        if (/unknown or expired|belonged to|410/.test(e.message)) { job.status = 'failed'; job.error = e.message; finishJob(job, null); }
        continue;
      }
      job.status = s.status === 'completed' || s.status === 'failed' || s.status === 'cancelled' ? job.status : s.status;
      job.queuePos = s.queue_position;
      if (s.preview) {
        if (s.preview.b64_json) job.preview = `data:image/png;base64,${s.preview.b64_json}`;
        if (s.preview.step !== job.step) { job.step = s.preview.step; job.steps.push([Date.now(), s.preview.step]); }
        job.total = s.preview.total_steps; job.pass = s.preview.pass;
      }
      if (s.status === 'completed' || s.status === 'failed' || s.status === 'cancelled') { job.status = s.status; job.error = s.error && s.error.message; await finishJob(job, s); }
    }
    renderProgress(); renderQueue(); updateGo();
    if (S.jobs.some(live)) poll.t = setTimeout(poll, 1000);
  }
  async function finishJob(job, s) {
    persistJobs();
    if (job.status !== 'completed' || !s || !s.result) {
      setStatus(job.status === 'cancelled' ? 'Cancelled.' : `Failed: ${job.error || 'unknown error'}`, job.status !== 'cancelled');
      if (job.status !== 'cancelled') toast(`Failed: ${job.error || 'unknown error'}`);
      S.jobs = S.jobs.filter(j => j !== job); renderPaint(); return;
    }
    const el = (Date.now() - job.started) / 1000, res = s.result;
    let items;
    if (job.kind === 'video') {
      items = [{ url: `data:${res.mime_type || 'video/webm'};base64,${res.b64_json}`, kind: 'video', model: job.model, mode: job.mode, prompt: job.prompt,
        seed: job.seed, w: job.w, h: job.h, fmt: res.output_format, secs: el, frames: res.frame_count, fps: res.fps, studio: job.studio, settings: job.settings, source: job.source }];
    } else {
      const mime = { png: 'image/png', jpeg: 'image/jpeg', webp: 'image/webp' }[res.output_format] || 'image/png';
      let urls = (res.images || []).map(im => `data:${mime};base64,${im.b64_json}`), w = job.w, h = job.h;
      if (job.P) {
        setStatus('Blending into the original…');
        try { urls = await Promise.all(urls.map(u => blendBack(u, job.P, mime, num('quality', 95) / 100))); w = job.P.w; h = job.P.h; }
        catch (e) { toast('Could not blend into the original — showing the raw result'); }
      }
      items = urls.map((url, i) => ({ url, kind: 'image', model: job.model, mode: job.mode, prompt: job.prompt, seed: job.seed + i, w, h, fmt: res.output_format,
        secs: el, studio: job.studio, settings: job.settings, source: job.source }));
    }
    S.jobs = S.jobs.filter(j => j !== job);
    if (!S.focus || S.focus === job.id || !focusJob()) { S.focus = null; S.batch = items; renderBatch(); selectItem(items[0]); }
    setStatus(`<b>Done</b> in ${fmtTime(el)}`, false, true);
    renderPaint(); clearTimeout(loadGallery.t); loadGallery.t = setTimeout(() => loadGallery(true), 800);
  }
  function eta(job) {
    if (!job.total || job.steps.length < 2) return '';
    const [t0, s0] = job.steps[0], [t1, s1] = job.steps[job.steps.length - 1];
    if (s1 <= s0) return '';
    const per = (t1 - t0) / (s1 - s0), left = (job.total - s1) * per / 1000;
    return left > 1 ? ` · ~${fmtTime(left)} left` : '';
  }
  function renderProgress() {
    const j = focusJob() || S.jobs.find(live);
    if (!j) { $('prog').hidden = true; return; }
    $('prog').hidden = false;
    const el = (Date.now() - j.started) / 1000, D = MODES[j.mode] || MODES.gen;
    let txt, pct = 3;
    if (j.status === 'queued') txt = `Queued${j.queuePos ? ` — position ${j.queuePos}` : ''}`;
    else if (j.total) { txt = `${D.doing}${j.pass > 1 ? ` (pass ${j.pass})` : ''} — step ${j.step}/${j.total}${eta(j)}`; pct = clamp(j.step / j.total * 95, 3, 97); }
    else txt = j.kind === 'video' && j.step ? 'Decoding the video frames…' : j.mode === 'gen' || j.mode === 't2v' ? 'Encoding the prompt…' : 'Reading the image…';
    if (j.kind === 'video' && j.total && j.step >= j.total) txt = 'Decoding the video frames… (the longest part)';
    $('prog-txt').textContent = txt; $('prog-bar').style.width = `${pct}%`; $('prog-time').textContent = fmtTime(el);
    if (j.preview && j.id === (focusJob() || {}).id) {
      const v = $('view'); v.src = j.preview; v.hidden = false; v.classList.add('preview'); $('vview').hidden = true; $('empty').hidden = true; $('ov').hidden = true;
      v.style.width = `min(${j.w}px, 100%)`; v.style.aspectRatio = `${j.w} / ${j.h}`;
    }
    setStatus(txt);
  }
  function renderQueue() {
    const box = $('queue'), list = S.jobs.filter(live);
    box.hidden = list.length < 1; box.innerHTML = '';
    for (const j of list) {
      const caps = (S.caps[j.model] || {}).features || {}, gen = j.status === 'generating';
      const d = document.createElement('div'); d.className = 'qitem';
      const pct = j.total ? clamp(j.step / j.total * 100, 0, 100) : 0, mm = S.models.find(x => x.id === j.model);
      d.innerHTML = `<img class="th${j.id === S.focus ? ' on' : ''}" alt=""><div><b>${esc((MODES[j.mode] || {}).tab || j.mode)}</b> · ${esc(mm ? mm.label : j.model)} · ${esc(gen ? (j.total ? `step ${j.step}/${j.total}` : 'starting') : 'queued')}<div class="qbar"><i></i></div><small>${esc(j.prompt.slice(0, 90))}</small></div>`;
      d.querySelector('.qbar i').style.width = `${pct}%`;
      const th = d.querySelector('.th'); if (j.preview) th.src = j.preview; else th.removeAttribute('src');
      th.onclick = () => { S.focus = j.id; renderProgress(); renderQueue(); };
      const b = document.createElement('button'); b.type = 'button'; b.className = 'btn sm';
      b.textContent = gen && caps.cancel_generating === false ? 'Stop' : 'Cancel';
      b.title = gen && caps.cancel_generating === false ? 'This model cannot interrupt a running job: stopping restarts it (10–30 s)' : '';
      b.onclick = () => cancelJob(j);
      d.appendChild(b); box.appendChild(d);
    }
  }
  async function cancelJob(j) {
    const caps = (S.caps[j.model] || {}).features || {};
    if (j.status === 'generating' && caps.cancel_generating === false) {
      if (!confirm('This model cannot interrupt a running job. Stop it anyway? The model restarts (10–30 s) and any other job queued on it is lost too.')) return;
      try { await post('/studio/models/stop', { model: j.model }); } catch (e) { toast(e.message); return; }
      S.jobs.filter(x => x.model === j.model && live(x)).forEach(x => { x.status = 'cancelled'; });
      S.jobs = S.jobs.filter(live); persistJobs(); renderQueue(); renderProgress(); renderPaint(); setStatus('Stopped.'); refreshModels(); return;
    }
    try { await post(`/sdcpp/v1/jobs/${encodeURIComponent(j.id)}/cancel`); setStatus('Cancelling…'); } catch (e) { toast(e.message); }
    poll();
  }
  function setStatus(html, bad, isHtml) {
    const el = $('st-status');
    if (isHtml) el.innerHTML = html; else if (bad) { el.innerHTML = ''; const s = document.createElement('span'); s.className = 'error'; s.textContent = html; el.appendChild(s); } else el.textContent = html;
  }

  // ---------- stage ----------
  function showItem(it) {
    const isV = it.kind === 'video', v = $('view'), vv = $('vview');
    $('empty').hidden = true; $('paint').hidden = true; $('paintbar').hidden = true;
    v.classList.remove('preview'); v.style.width = ''; v.style.aspectRatio = '';
    if (isV) { v.hidden = true; vv.hidden = false; if (vv.dataset.src !== it.url) { vv.src = it.url; vv.dataset.src = it.url; vv.play().catch(() => {}); } }
    else { vv.hidden = true; vv.pause(); v.hidden = false; v.src = it.url; }
    $('canvas').classList.toggle('alpha', !isV && (it.settings && /RGBA/.test(it.settings.prompt || '')));
    $('ov').hidden = false;
  }
  function selectItem(it) {
    S.current = it; if (!focusJob() && !(S.mode === 'inpaint' && S.init)) showItem(it);
    const mm = S.models.find(x => x.id === it.model), u = mm ? mm.ui || {} : {};
    const parts = [it.seed != null ? `seed <b>${esc(it.seed)}</b>` : '', it.w ? `${it.w}×${it.h}` : '', it.frames ? `${it.frames} frames @ ${it.fps} fps` : '',
      esc((MODES[it.mode] || {}).tab || it.mode || ''), esc(mm ? mm.label : it.model || ''), it.secs ? `${fmtTime(it.secs)}` : ''].filter(Boolean);
    $('st-meta').innerHTML = parts.join(' · ');
    const img = it.kind !== 'video';
    $('a-edit').disabled = !img || !u.edit && !(M() && M().ui && M().ui.edit);
    ['a-inpaint', 'a-i2i'].forEach(id => $(id).disabled = !img);
    $('a-anim').disabled = !img || !S.models.some(x => x.kind === 'video' && x.ui && x.ui.i2v);
    ['a-again', 'a-reuse', 'a-dl'].forEach(id => $(id).disabled = false);
    $('a-cmp').disabled = !it.source; $('a-del').disabled = !it.file;
    qsa('.g-item').forEach(t => t.classList.toggle('on', t.dataset.file && t.dataset.file === it.file));
    qsa('#batchrow img').forEach(t => t.classList.toggle('on', t.dataset.url === it.url));
  }
  function renderBatch() {
    const row = $('batchrow'); row.innerHTML = ''; row.hidden = S.batch.length < 2;
    for (const it of S.batch) { const im = document.createElement('img'); im.src = it.url; im.alt = `Result seed ${it.seed}`; im.dataset.url = it.url; im.onclick = () => selectItem(it); row.appendChild(im); }
  }
  const useAs = async mode => {
    const c = S.current; if (!c) return;
    if (mode === 'i2v' && !isVideo()) {
      const vm = S.models.filter(x => x.kind === 'video' && x.ui && x.ui.i2v).sort((a, b) => (b.state === 'ready') - (a.state === 'ready'))[0];
      if (!vm) { toast('No video model can animate images'); return; }
      await selectModel(vm.id);
    }
    if (mode === 'edit') S.refs = [];
    setMode(mode); await addImage(c.url, 'src'); $('prompt').value = ''; $('prompt').focus();
    toast(mode === 'inpaint' ? 'Paint the area to change, then describe it' : mode === 'i2v' ? 'Describe the motion' : 'Now describe the change');
  };
  $('a-edit').onclick = () => useAs('edit'); $('a-inpaint').onclick = () => useAs('inpaint'); $('a-i2i').onclick = () => useAs('img2img'); $('a-anim').onclick = () => useAs('i2v');
  $('a-again').onclick = () => { if (!S.current) return; reuse(S.current, true); $('seed').value = ''; $('lock').checked = false; run(); };
  $('a-reuse').onclick = () => { if (S.current) { reuse(S.current); toast('Prompt and settings loaded'); } };
  $('a-cmp').onclick = () => { if (S.current && S.current.source) openViewer([S.current], 0, null, true); };
  const download = it => {
    if (!it) return; const a = document.createElement('a'); a.href = it.url;
    const slug = (it.prompt || 'image').toLowerCase().replace(/[^a-z0-9]+/g, '-').slice(0, 40).replace(/^-|-$/g, '') || 'image';
    const ext = it.file ? it.file.split('.').pop() : it.kind === 'video' ? (it.fmt || 'webm') : (it.fmt === 'jpeg' ? 'jpg' : it.fmt || 'png');
    a.download = `${slug}-${it.seed != null ? it.seed : 'x'}.${ext}`; a.click();
  };
  $('a-dl').onclick = () => download(S.current); $('ov-dl').onclick = () => download(S.current);
  $('a-del').onclick = async () => {
    const it = S.current; if (!it || !it.file || !confirm('Delete this result from the gallery (and the disk)?')) return;
    try { await post('/studio/gallery/delete', { file: it.file }); toast('Deleted'); G.items = G.items.filter(x => x.file !== it.file); renderGallery(); S.current = null; $('view').hidden = true; $('vview').hidden = true; $('empty').hidden = false; }
    catch (e) { toast(e.message); }
  };
  function reuse(it, keepSeed) {
    const ui = it.studio && it.studio.ui, st = it.settings || {};
    if (it.model && it.model !== S.model && S.models.some(x => x.id === it.model)) { S.model = it.model; store.set('model', it.model); applyModelDefaults(); applyCaps(); setupTabs(); renderModelButton(); }
    if (ui) {
      $('prompt').value = ui.prompt || ''; $('neg').value = ui.neg || '';
      S.ratio = ui.ratio || S.ratio; S.tier = ui.tier || 'M'; S.custom = !!ui.custom; $('cw').value = ui.cw || ''; $('ch').value = ui.ch || '';
      if (!U().fixed_steps && ui.steps) setSlider('steps', ui.steps); if (ui.cfg) setSlider('cfg', ui.cfg);
      ['imgcfg', 'shift', 'eta', 'clipskip', 'batch', 'cache', 'preview', 'fmt', 'quality', 'fps', 'vfmt'].forEach(k => { if (ui[k] != null && $(k)) $(k).value = ui[k]; });
      if (ui.sampler) $('sampler').value = ui.sampler; if (ui.scheduler) $('scheduler').value = ui.scheduler;
      $('alpha').checked = !!ui.alpha; $('vaetile').checked = ui.vaetile !== false; $('meta').checked = ui.meta !== false;
      if (ui.hires) { $('hires').checked = !!ui.hires.on; $('hires-scale').value = ui.hires.scale; $('hires-steps').value = ui.hires.steps; $('hires-den').value = ui.hires.den; }
      if (ui.frames) setSlider('frames', ui.frames);
      if (ui.strength) $('strength').value = ui.strength;
      if (ui.inp) { S.inp.fill = ui.inp.fill || S.inp.fill; S.inp.area = ui.inp.area || S.inp.area; $('mblur').value = ui.inp.blur; $('mpad').value = ui.inp.pad; $('keep').checked = ui.inp.keep !== false; }
    } else {
      $('prompt').value = it.prompt || st.prompt || ''; $('neg').value = st.negative_prompt || '';
      const sp = st.sample_params || {};
      if (sp.sample_steps != null && !U().fixed_steps) setSlider('steps', sp.sample_steps);
      if (sp.guidance && sp.guidance.txt_cfg != null) setSlider('cfg', sp.guidance.txt_cfg);
      if (sp.sample_method && [...$('sampler').options].some(o => o.value === sp.sample_method)) $('sampler').value = sp.sample_method;
      if (st.clip_skip != null) $('clipskip').value = st.clip_skip;
      if (it.w && it.h) { S.custom = true; $('cw').value = it.w; $('ch').value = it.h; }
    }
    if (!keepSeed && it.seed != null) $('seed').value = it.seed;
    renderTiers(); renderSizes(); renderInpaintOpts(); updateNotes();
  }

  // ---------- gallery (server-side outputs) ----------
  const G = { items: [], total: 0, filter: store.get('gfilter', 'all') };
  async function loadGallery(reset, quiet) {
    const off = reset ? 0 : G.items.length;
    const p = new URLSearchParams({ offset: off, limit: 60 });
    if (G.filter === 'image' || G.filter === 'video') p.set('kind', G.filter);
    if (G.filter === 'model' && S.model) p.set('model', S.model);
    try {
      const r = await api(`/studio/gallery?${p}`);
      G.total = r.total; G.items = reset ? r.items : G.items.concat(r.items); renderGallery();
    } catch (e) { if (!quiet) toast(`Gallery: ${e.message}`); }
  }
  const gItem = m => ({ url: m.url, file: m.file, kind: m.video ? 'video' : 'image', model: m.model, mode: m.mode === 'gen' && m.video_frames ? 't2v' : m.mode,
    prompt: m.prompt, seed: m.seed, w: m.width, h: m.height, frames: m.frame_count, fps: m.fps, studio: m.studio, settings: m });
  function renderGallery() {
    const box = $('g-grid'); box.innerHTML = '';
    $('g-count').textContent = G.total ? `${G.total}` : '';
    $('g-empty').hidden = !!G.items.length; $('g-more').hidden = G.items.length >= G.total;
    qsa('#g-filter .chip').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.f === G.filter)));
    G.items.forEach((m, i) => {
      const it = gItem(m), b = document.createElement('button'); b.type = 'button'; b.className = 'g-item'; b.dataset.file = m.file;
      b.title = `${m.prompt || ''}\n${(S.models.find(x => x.id === m.model) || {}).label || m.model}`;
      b.setAttribute('aria-label', `${it.kind} — ${(m.prompt || '').slice(0, 80)}`);
      if (it.kind === 'video' && /\.(webm|avi)$/.test(m.file)) {
        const v = document.createElement('video'); v.src = m.url; v.muted = true; v.loop = true; v.playsInline = true; v.preload = 'metadata';
        b.onmouseenter = () => v.play().catch(() => {}); b.onmouseleave = () => v.pause(); b.appendChild(v);
      } else { const im = document.createElement('img'); im.loading = 'lazy'; im.decoding = 'async'; im.alt = ''; im.src = m.url; b.appendChild(im); }
      const tag = document.createElement('span'); tag.className = 'tag' + (it.kind === 'video' ? ' v' : ''); tag.textContent = it.kind === 'video' ? 'video' : (m.mode || 'gen'); b.appendChild(tag);
      b.onclick = () => { S.batch = []; renderBatch(); selectItem(it); };
      b.ondblclick = () => openViewer(G.items.map(gItem), i);
      if (S.current && S.current.file === m.file) b.classList.add('on');
      box.appendChild(b);
    });
  }
  qsa('#g-filter .chip').forEach(b => b.onclick = () => { G.filter = b.dataset.f; store.set('gfilter', G.filter); loadGallery(true); });
  $('g-more').onclick = () => loadGallery(false);

  // old per-browser history (IndexedDB, before the server gallery) -> offer to move it to the box
  function openOldDb() { return new Promise(res => { try { const rq = indexedDB.open('image-studio', 1); rq.onupgradeneeded = () => { rq.transaction.abort(); res(null); }; rq.onsuccess = () => res(rq.result); rq.onerror = () => res(null); } catch (e) { res(null); } }); }
  async function checkOldHistory() {
    if (store.get('imported', false)) return;
    const db = await openOldDb(); if (!db || !db.objectStoreNames.contains('items')) return;
    const items = await new Promise(res => { try { const rq = db.transaction('items').objectStore('items').getAll(); rq.onsuccess = () => res(rq.result || []); rq.onerror = () => res([]); } catch (e) { res([]); } });
    if (!items.length) { store.set('imported', true); return; }
    $('import-banner').hidden = false; $('import-txt').textContent = `This browser still holds ${items.length} results from the old local history. Move them into the gallery on the box (visible on every device)?`;
    $('import-no').onclick = () => { $('import-banner').hidden = true; store.set('imported', true); };
    $('import-go').onclick = async () => {
      $('import-go').disabled = true; let n = 0;
      for (const it of items) {
        try { await post('/studio/gallery/import', { image: it.url, meta: { model: it.model, mode: it.mode, prompt: it.prompt, seed: it.seed, width: it.w, height: it.h, settings: it.settings || {} } }); n++; $('import-txt').textContent = `Moving… ${n}/${items.length}`; }
        catch (e) { /* skip one bad item */ }
      }
      try { db.transaction('items', 'readwrite').objectStore('items').clear(); } catch (e) { /* keep */ }
      store.set('imported', true); $('import-banner').hidden = true; toast(`Moved ${n} results to the gallery`); loadGallery(true);
    };
  }

  // ---------- viewer (+ compare) ----------
  const lbImg = $('lb-img'), lbVid = $('lb-vid'), lbStage = $('lb-stage');
  const lbz = Zoom(lbImg, z => { const r = z.ratio(lbImg); $('lb-zoom').textContent = `${Math.round(r * 100)}%`; lbImg.classList.toggle('px', r >= 2); });
  const lbPinch = Pinch(lbz), LB = { list: [], i: 0, info: '', cmp: false }; let lbDrag = null;
  function openViewer(list, i, info, cmp) {
    if (!list.length) return; LB.list = list; LB.i = Math.max(0, i); LB.info = info || ''; LB.cmp = !!cmp;
    $('lb').hidden = false; document.body.style.overflow = 'hidden'; showViewer(); $('lb-close').focus();
  }
  function showViewer() {
    const it = LB.list[LB.i]; if (!it) return;
    const isV = it.kind === 'video', canCmp = !isV && !!it.source;
    if (!canCmp) LB.cmp = false;
    $('lb-cmp').hidden = !canCmp; $('lb-cmp').setAttribute('aria-pressed', String(LB.cmp));
    lbVid.hidden = !isV; lbImg.hidden = isV || LB.cmp; $('cmp').hidden = !LB.cmp;
    ['lb-in', 'lb-out', 'lb-fit', 'lb-1x', 'lb-zoom'].forEach(id => $(id).hidden = isV || LB.cmp);
    if (isV) { lbImg.removeAttribute('src'); lbVid.src = it.url; lbVid.play().catch(() => {}); }
    else if (LB.cmp) { lbVid.pause(); setupCompare(it); }
    else { lbVid.pause(); lbImg.onload = () => lbz.reset(); lbImg.src = it.url; }
    const mm = it.model && S.models.find(x => x.id === it.model);
    $('lb-info').textContent = LB.info || [it.w ? `${it.w}×${it.h}` : '', (MODES[it.mode] || {}).tab || it.mode, mm ? mm.label : it.model, it.seed != null ? `seed ${it.seed}` : '', it.prompt].filter(Boolean).join(' · ');
    $('lb-info').title = $('lb-info').textContent;
    $('lb-prev').hidden = $('lb-next').hidden = LB.list.length < 2;
    $('lb-prev').disabled = LB.i <= 0; $('lb-next').disabled = LB.i >= LB.list.length - 1;
  }
  async function setupCompare(it) {
    const a = $('cmp-a'), b = $('cmp-b');
    a.src = it.source; b.src = it.url;
    try { await loadImg(it.source); } catch (e) { /* shows what it can */ }
    requestAnimationFrame(() => { b.style.width = `${a.offsetWidth}px`; b.style.height = `${a.offsetHeight}px`; setCmp(0.5); });
  }
  function setCmp(f) {
    const a = $('cmp-a'), w = a.offsetWidth; f = clamp(f, 0, 1);
    $('cmp-after').style.width = `${w * f}px`; $('cmp-h').style.left = `${w * f}px`;
    $('cmp-la').style.left = '8px'; $('cmp-lb').style.right = '8px';
  }
  // the AFTER image sits on the left of the handle: "Before" label on the right side
  $('cmp-la').textContent = 'After'; $('cmp-lb').textContent = 'Before';
  let cmpDrag = false;
  $('cmp').addEventListener('pointerdown', e => { cmpDrag = true; try { $('cmp').setPointerCapture(e.pointerId); } catch (er) { /* */ } const r = $('cmp-a').getBoundingClientRect(); setCmp((e.clientX - r.left) / r.width); e.stopPropagation(); });
  $('cmp').addEventListener('pointermove', e => { if (!cmpDrag) return; const r = $('cmp-a').getBoundingClientRect(); setCmp((e.clientX - r.left) / r.width); });
  $('cmp').addEventListener('pointerup', () => { cmpDrag = false; });
  $('lb-cmp').onclick = () => { LB.cmp = !LB.cmp; showViewer(); };
  function closeViewer() { $('lb').hidden = true; document.body.style.overflow = ''; lbImg.removeAttribute('src'); lbVid.pause(); lbVid.removeAttribute('src'); }
  function lbNav(d) { const j = LB.i + d; if (j < 0 || j >= LB.list.length) return; LB.i = j; showViewer(); if (!LB.info && LB.list[j].url) selectItem(LB.list[j]); }
  const oneToOne = () => (lbImg.naturalWidth || 1) / (lbImg.offsetWidth || 1);
  function openCurrent() {
    if (!S.current || $('view').classList.contains('preview')) return;
    const inBatch = S.batch.some(b => b.url === S.current.url) && S.batch.length > 1;
    if (inBatch) { openViewer(S.batch, S.batch.findIndex(b => b.url === S.current.url)); return; }
    const gl = G.items.map(gItem), gi = gl.findIndex(x => S.current.file && x.file === S.current.file);
    if (gi >= 0) openViewer(gl, gi); else openViewer([S.current], 0);
  }
  $('view').onclick = openCurrent; $('ov-zoom').onclick = openCurrent;
  $('lb-close').onclick = closeViewer; $('lb-prev').onclick = () => lbNav(-1); $('lb-next').onclick = () => lbNav(1);
  $('lb-in').onclick = () => lbz.center(lbz.s * 1.5); $('lb-out').onclick = () => lbz.center(lbz.s / 1.5);
  $('lb-fit').onclick = () => lbz.reset(); $('lb-1x').onclick = () => lbz.center(Math.max(1, oneToOne()));
  lbStage.addEventListener('wheel', e => { if (lbImg.hidden) return; e.preventDefault(); lbz.at(e.clientX, e.clientY, lbz.s * wheelFactor(e)); }, { passive: false });
  lbStage.addEventListener('dblclick', e => { if (lbImg.hidden) return; if (lbz.s > 1.01) lbz.reset(); else lbz.at(e.clientX, e.clientY, Math.max(2, oneToOne())); });
  lbStage.addEventListener('pointerdown', e => {
    if (e.target.closest('#cmp') || e.target === lbVid) return;
    try { lbStage.setPointerCapture(e.pointerId); } catch (er) { /* synthetic */ }
    lbDrag = lbPinch.down(e) === 1 ? { x: e.clientX, y: e.clientY, x0: e.clientX, y0: e.clientY, onImg: e.target === lbImg } : null;
    lbStage.classList.add('drag');
  });
  lbStage.addEventListener('pointermove', e => { if (lbPinch.move(e) || !lbDrag) return; lbz.pan(e.clientX - lbDrag.x, e.clientY - lbDrag.y); lbDrag.x = e.clientX; lbDrag.y = e.clientY; });
  ['pointerup', 'pointercancel'].forEach(ev => lbStage.addEventListener(ev, e => {
    const left = lbPinch.up(e); lbStage.classList.remove('drag');
    if (ev === 'pointerup' && lbDrag && !lbDrag.onImg && left === 0 && e.target === lbStage && Math.hypot(e.clientX - lbDrag.x0, e.clientY - lbDrag.y0) < 5) closeViewer();
    lbDrag = null;
  }));

  // ---------- add a model / LoRA (Hugging Face, CivitAI) ----------
  const AM = { info: null, url: '', fam: '', poll: null, seen: null };
  function openAdd() { $('addm').hidden = false; renderTokens(); renderMine(); pollJobs(); setTimeout(() => $('am-url').focus(), 50); }
  function closeAdd() { $('addm').hidden = true; $('add-model').focus(); }
  $('add-model').onclick = openAdd; $('dl-pill').onclick = openAdd; $('am-close').onclick = closeAdd;
  $('addm').addEventListener('click', e => { if (e.target === $('addm')) closeAdd(); });
  function renderTokens() {
    const t = (S.st && S.st.tokens) || {};
    $('am-tokens').innerHTML = `CivitAI key: <b>${t.civitai ? 'set' : 'not set'}</b>` +
      (t.civitai ? '' : ' — many CivitAI files need one: create it at civitai.com → Account settings → API keys, then on the box run <kbd>setx CIVITAI_TOKEN &lt;key&gt;</kbd> in a terminal (no restart needed).') +
      ` · Hugging Face token: <b>${t.hf ? 'set' : 'not set'}</b>${t.hf ? '' : ' (gated repos only: <kbd>setx HF_TOKEN &lt;token&gt;</kbd>)'}`;
  }
  async function lookup(extra) {
    const url = (extra && extra.url) || $('am-url').value.trim(); if (!url) { $('am-url').focus(); return; }
    $('am-look').disabled = true; $('am-look').textContent = 'Looking…'; $('am-err').hidden = true; $('am-add').disabled = true;
    try { AM.info = await post('/studio/remote/inspect', Object.assign({ url }, extra || {})); AM.url = AM.info.page; renderInfo(); }
    catch (e) { $('am-result').hidden = true; $('am-err').hidden = false; $('am-err').textContent = e.message; }
    finally { $('am-look').disabled = false; $('am-look').textContent = 'Look up'; }
  }
  $('am-look').onclick = () => { AM.fam = ''; lookup(); };
  $('am-url').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); AM.fam = ''; lookup(); } });
  function renderInfo() {
    const i = AM.info, lora = i.kind === 'lora'; if (S.st) S.st.tokens = i.tokens || S.st.tokens; renderTokens();
    $('am-result').hidden = false;
    $('am-name').textContent = i.name; $('am-kind').textContent = lora ? 'LoRA' : i.kind ? 'model' : i.type; $('am-nsfw').hidden = !i.nsfw;
    $('am-meta').innerHTML = [i.base ? `base model: <b>${esc(i.base)}</b>` : '', esc(i.licence), `<a href="${esc(i.page)}" target="_blank" rel="noopener noreferrer">open page ↗</a>`].filter(Boolean).join(' · ');
    $('am-ver-box').hidden = !(i.versions && i.versions.length > 1);
    $('am-ver').innerHTML = (i.versions || []).map(v => `<option value="${esc(v.id)}">${esc(v.name)}${v.base ? ` — ${esc(v.base)}` : ''}</option>`).join('');
    $('am-ver').value = String(i.version.id);
    $('am-file').innerHTML = i.files.map(f => `<option value="${esc(f.key)}">${esc(f.name)} · ${gbs(f.bytes)}${f.detail ? ` · ${esc(f.detail)}` : ''}${f.primary ? ' ★' : ''}</option>`).join('');
    $('am-file').value = i.file;
    $('am-fam').innerHTML = '<option value="">— pick the family —</option>' + i.families.map(f => `<option value="${esc(f.id)}">${esc(f.label)}</option>`).join('');
    $('am-fam').value = AM.fam || i.family || '';
    $('am-fam-why').textContent = i.family ? `detected from ${i.family_why}` : lora ? 'optional for a LoRA' : 'not detected — pick it';
    $('am-label').value = i.suggested_label || i.name;
    const words = i.trained_words || []; $('am-words-box').hidden = !words.length;
    $('am-words').innerHTML = words.slice(0, 20).map(w => `<span class="chip">${esc(w)}</span>`).join('');
    const warn = [];
    if (i.already) warn.push(`Already on the box as "${i.already}" — adding it again only adds another entry.`);
    if (!i.kind) warn.push(`CivitAI type "${i.type}" is neither a checkpoint nor a LoRA, so it can't be added here.`);
    if (i.unsupported) warn.push(i.unsupported + '.');
    if (i.access && i.access !== 'ok') warn.push(i.access);
    if (i.allinone) warn.push('This file bundles its own text encoder / VAE, so it loads as one checkpoint (no extra downloads).');
    if (i.warn_fp8) warn.push('This is an fp8 file: this GPU driver has crashed on fp8 encoders before — a GGUF (Q8_0) of the same model is the safer pick.');
    if (i.vpred) warn.push('v-prediction model: it will be run with --prediction v automatically.');
    if (i.family && i.sniffed && fam(i.family) && fam(i.sniffed) && fam(i.family).group !== fam(i.sniffed).group) warn.push(`Careful: the file's tensors look like ${famLabel(i.sniffed)}, not ${famLabel(i.family)}.`);
    $('am-warn').hidden = !warn.length; $('am-warn').textContent = warn.join(' ');
    const p = i.plan || {}, items = p.items || [];
    $('am-plan').innerHTML = items.map(f => `<div class="f${f.present ? ' have' : ''}"><span>${esc(f.name)}</span><span>${f.present ? 'already on disk' : gbs(f.bytes)}</span></div>`).join('') +
      `<div class="f"><b>To download</b><span><b>${gbs(p.download_bytes || 0)}</b> · ${gbs(p.free_bytes || 0)} free${p.queued_bytes ? ` · ${gbs(p.queued_bytes)} still queued` : ''}</span></div>`;
    const blocked = !i.kind || (!lora && !$('am-fam').value) || (i.unsupported && !$('am-fam').value) || (i.access && /API key|gated|refused/i.test(i.access)) || p.ok_space === false || (i.unet_only);
    $('am-add').disabled = !!blocked; $('am-add').textContent = lora ? 'Download LoRA' : 'Download & add model';
  }
  $('am-fam').onchange = () => { AM.fam = $('am-fam').value; lookup({ url: AM.url, file: $('am-file').value, family: AM.fam || undefined }); };
  $('am-file').onchange = () => lookup({ url: AM.url, file: $('am-file').value, family: AM.fam || undefined });
  $('am-ver').onchange = () => { AM.fam = ''; lookup({ url: AM.url.replace(/modelVersionId=\d+/, `modelVersionId=${$('am-ver').value}`) }); };
  $('am-add').onclick = async () => {
    const i = AM.info; if (!i) return; $('am-add').disabled = true;
    try {
      const job = await post('/studio/remote/add', { url: i.page, file: $('am-file').value, family: $('am-fam').value || null, label: $('am-label').value.trim() || i.suggested_label });
      toast(`Downloading ${job.label}…`); $('am-result').hidden = true; $('am-url').value = ''; AM.info = null; AM.fam = ''; pollJobs();
    } catch (e) { $('am-warn').hidden = false; $('am-warn').textContent = e.message; $('am-add').disabled = false; }
  };
  async function pollJobs() {
    clearTimeout(AM.poll); AM.poll = null; let r;
    try { r = await api('/studio/remote/jobs'); } catch (e) { AM.poll = setTimeout(pollJobs, 5000); return; }
    const isLive = j => ['queued', 'downloading', 'verifying'].includes(j.state);
    const box = $('am-jobs'); box.innerHTML = '';
    for (const j of r.jobs.slice(0, 6)) {
      const pct = j.state === 'done' ? 100 : j.total ? Math.min(100, j.done / j.total * 100) : 0;
      const state = { queued: 'queued', downloading: `${pct.toFixed(0)}% · ${gbs(j.done)} of ${gbs(j.total)}${j.speed ? ` · ${(j.speed / 1e6).toFixed(0)} MB/s` : ''}`, verifying: 'verifying…', done: 'done', failed: 'failed', cancelled: 'cancelled' }[j.state] || j.state;
      const d = document.createElement('div'); d.className = 'job';
      d.innerHTML = `<div class="top2"><b>${esc(j.label)}</b><span>${esc(state)}</span></div>${isLive(j) ? '<div class="bar"><i></i></div>' : ''}` +
        (j.error ? `<div class="error">${esc(j.error)}</div>` : j.current ? `<div class="hint">${esc(j.current)}</div>` : j.result ? `<div class="hint">${esc(j.result)}</div>` : '');
      const bar = d.querySelector('.bar i'); if (bar) bar.style.width = `${pct.toFixed(1)}%`;
      if (isLive(j)) {
        const b = document.createElement('button'); b.type = 'button'; b.className = 'btn sm'; b.textContent = 'Cancel';
        b.onclick = async () => { try { await post('/studio/remote/cancel', { id: j.id }); } catch (e) { /* gone */ } pollJobs(); };
        d.querySelector('.top2').appendChild(b);
      }
      box.appendChild(d);
    }
    const done = r.jobs.filter(j => j.state === 'done').map(j => j.id);
    if (AM.seen && done.some(id => !AM.seen.includes(id))) { toast('Download finished — it is in the model list now'); await refreshModels(); applyCaps(); renderMine(); }
    AM.seen = done;
    const act = r.jobs.filter(isLive);
    $('dl-pill').hidden = !act.length;
    if (act.length) $('dl-pill').textContent = `⬇ ${act.length > 1 ? act.length + ' downloads' : act[0].total ? Math.round(act[0].done / act[0].total * 100) + '%' : 'queued'}`;
    if (act.length || !$('addm').hidden) AM.poll = setTimeout(pollJobs, act.length ? 1500 : 6000);
  }
  function renderMine() {
    const ms = S.models.filter(m => m.user), ls = (S.st && S.st.loras) || [];
    $('am-mine-n').textContent = `${ms.length} model${ms.length === 1 ? '' : 's'} · ${ls.length} LoRA${ls.length === 1 ? '' : 's'}`;
    const box = $('am-list'); box.innerHTML = ms.length || ls.length ? '' : '<p class="hint">Nothing added yet.</p>';
    const add = (kind, id, label, sub) => {
      const d = document.createElement('div'); d.className = 'it';
      d.innerHTML = `<span><b>${esc(label)}</b> <small>${esc(sub)}</small></span><button class="btn sm" type="button">Remove</button>`;
      d.querySelector('button').onclick = async () => {
        if (!confirm(`Remove "${label}" from the list?`)) return;
        const del = confirm('Also delete its downloaded file from disk?\nOK = delete the file · Cancel = keep the file');
        try { const r = await post('/studio/remote/remove', { kind, id, delete_files: del }); toast(`Removed${r.deleted.length ? `; deleted ${r.deleted.join(', ')}` : ''}`); await refreshModels(); renderMine(); }
        catch (e) { toast(e.message); }
      };
      box.appendChild(d);
    };
    for (const m of ms) add('model', m.id, m.label, `${famLabel(m.family)} · ${m.vram_gb} GB`);
    for (const l of ls) add('lora', l.file, l.name, `LoRA · ${famLabel(l.family) || 'family unknown'}`);
  }

  // ---------- drop a PNG: load its generation settings ----------
  async function pngText(file) {
    const buf = new Uint8Array(await file.arrayBuffer()), dv = new DataView(buf.buffer); const out = {};
    if (buf.length < 8 || buf[1] !== 0x50) return out;
    let i = 8; const dec = new TextDecoder('latin1'), u8 = new TextDecoder('utf-8');
    while (i + 8 < buf.length) {
      const n = dv.getUint32(i), type = dec.decode(buf.subarray(i + 4, i + 8)), body = buf.subarray(i + 8, i + 8 + n);
      if (type === 'tEXt') { const z = body.indexOf(0); out[dec.decode(body.subarray(0, z))] = dec.decode(body.subarray(z + 1)); }
      if (type === 'iTXt') { const z = body.indexOf(0); if (body[z + 1] === 0) { let p = z + 3; p = body.indexOf(0, p) + 1; p = body.indexOf(0, p) + 1; out[dec.decode(body.subarray(0, z))] = u8.decode(body.subarray(p)); } }
      if (type === 'IEND') break;
      i += 12 + n;
    }
    return out;
  }
  function applyParams(text) {
    // A1111 / sd.cpp "parameters": prompt, "Negative prompt: ...", then "Steps: N, Sampler: x, CFG scale: y, Seed: z, Size: WxH, ..."
    const lines = text.split('\n'); let neg = '', params = '', prompt = [];
    for (const l of lines) { if (/^Negative prompt:/.test(l)) neg = l.replace(/^Negative prompt:\s*/, ''); else if (/^Steps:\s*\d+/.test(l)) params = l; else if (params) params += '\n' + l; else if (neg) neg += '\n' + l; else prompt.push(l); }
    const g = re => { const m = params.match(re); return m ? m[1].trim() : null; };
    let sd = null; const si = params.indexOf('SDCPP: '); if (si >= 0) { try { sd = JSON.parse(params.slice(si + 7)); } catch (e) { sd = null; } }
    const file = g(/(?:Unet|Model):\s*([^,]+)/);
    const mm = file && S.models.find(m => (m.files || []).includes(file));
    if (mm && mm.id !== S.model) { S.model = mm.id; store.set('model', mm.id); applyModelDefaults(); applyCaps(); setupTabs(); renderModelButton(); }
    $('prompt').value = prompt.join('\n').trim(); $('neg').value = neg.trim();
    const steps = g(/Steps:\s*(\d+)/), cfg = g(/CFG scale:\s*([\d.]+)/), seed = g(/Seed:\s*(\d+)/), size = params.match(/Size:\s*(\d+)x(\d+)/), sampler = g(/Sampler:\s*([^,]+)/);
    if (steps && !U().fixed_steps) setSlider('steps', Number(steps)); if (cfg) setSlider('cfg', Number(cfg)); if (seed) $('seed').value = seed;
    if (size) { S.custom = true; $('cw').value = size[1]; $('ch').value = size[2]; }
    if (sampler && [...$('sampler').options].some(o => o.value === sampler)) $('sampler').value = sampler;
    if (sd && sd.clip_skip != null && sd.clip_skip !== -1) $('clipskip').value = sd.clip_skip;
    renderSizes(); updateNotes();
    toast(mm ? `Loaded the settings (and switched to ${mm.label})` : 'Loaded the prompt and settings from the image');
  }
  document.addEventListener('dragover', e => { if (e.dataTransfer && [...e.dataTransfer.types].includes('Files')) e.preventDefault(); });
  document.addEventListener('drop', async e => {
    if (!e.dataTransfer || !e.dataTransfer.files.length) return; e.preventDefault();
    const f = e.dataTransfer.files[0];
    if (f.type === 'image/png') { const t = await pngText(f); if (t.parameters) { applyParams(t.parameters); return; } }
    if (f.type.startsWith('image/')) { if (needsSource(S.mode)) addFiles([f], 'src'); else toast('No generation settings in that image — drop it on the source box (Edit / Inpaint / Image→Image) to use it as a picture'); }
  });

  // ---------- help + keys ----------
  $('help-btn').onclick = () => { $('help').hidden = false; $('help-close').focus(); };
  $('help-close').onclick = () => { $('help').hidden = true; };
  $('help').addEventListener('click', e => { if (e.target === $('help')) $('help').hidden = true; });
  function trapFocus(e, box) {
    const f = qsa('button:not([disabled]), input:not([disabled]), select, textarea, a[href], [tabindex="0"]', box).filter(x => x.offsetParent !== null);
    if (!f.length) return; const first = f[0], lastEl = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); lastEl.focus(); } else if (!e.shiftKey && document.activeElement === lastEl) { e.preventDefault(); first.focus(); }
  }
  document.addEventListener('keydown', e => {
    for (const id of ['addm', 'help']) if (!$(id).hidden) { if (e.key === 'Escape') { e.preventDefault(); $(id).hidden = true; } else if (e.key === 'Tab') trapFocus(e, $(id)); return; }
    if (!$('model-pop').hidden && e.key === 'Escape') { closePicker(); $('model-btn').focus(); return; }
    if (!$('lb').hidden) {
      const act = { Escape: closeViewer, ArrowLeft: () => lbNav(-1), ArrowRight: () => lbNav(1), '+': () => $('lb-in').onclick(), '=': () => $('lb-in').onclick(),
        '-': () => $('lb-out').onclick(), '0': () => lbz.reset(), '1': () => $('lb-1x').onclick(), c: () => { if (!$('lb-cmp').hidden) $('lb-cmp').onclick(); } }[e.key];
      if (act) { e.preventDefault(); act(); } else if (e.key === 'Tab') trapFocus(e, $('lb')); return;
    }
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName);
    if (!typing && (e.key === 'm' || e.key === 'M') && !e.ctrlKey && !e.metaKey && !e.altKey) { e.preventDefault(); openPicker(); return; }
    if (!typing && e.key === '?') { $('help').hidden = false; return; }
    if (!typing && e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); run(); return; }
    if ($('paint').hidden || typing) return;
    if (e.code === 'Space') { e.preventDefault(); if (!spaceDown) { spaceDown = true; $('paint').classList.add('hand'); $('brush-cur').hidden = true; } }
    else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'z') { e.preventDefault(); undoMask(); }
    else if (e.key === '[' || e.key === ']') { const b = $('brush'); b.value = Number(b.value) + (e.key === ']' ? 8 : -8); }
  });
  document.addEventListener('keyup', e => { if (e.code === 'Space' && spaceDown) { spaceDown = false; $('paint').classList.toggle('hand', hand); } });

  // ---------- boot ----------
  (async () => {
    await refreshModels();
    applyModelDefaults(); applyCaps(); setupTabs(); renderModelButton();
    const m = M();
    if (m && (m.state === 'stopped' || m.state === 'failed') && !(m.missing && m.missing.length)) { try { await post('/studio/models/load', { model: m.id }); } catch (e) { /* shown by refresh */ } refreshModels(); }
    // re-attach jobs that were running when the page was closed or reloaded
    const saved = store.get('jobs', []);
    if (saved.length) { S.jobs = saved.map(j => Object.assign({ status: 'queued', steps: [], P: null, source: null }, j)); S.focus = S.jobs[S.jobs.length - 1].id; setStatus(`Re-attached ${saved.length} running job${saved.length > 1 ? 's' : ''}`); poll(); }
    await loadGallery(true, true);
    if (G.items[0] && !S.current && !S.jobs.length) selectItem(gItem(G.items[0]));
    checkOldHistory();
  })();
})();
