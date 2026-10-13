'use strict';
const $ = id => document.getElementById(id);
const fields = ['speed','unit','direction','target','phase','notes','speed-unknown','independent'];
let batch, token, reviewer = '', labels = {}, caseIndex = 0, frameIndex = 19;
let evidence = new Set(), speedFrame = null, dirty = false, timer = null, loadGeneration = 0;
let ready = false, images = [], baseRevision = 0, saving = false;
const current = () => batch.cases[caseIndex];
const stamp = seconds => `${String(Math.floor(seconds/60)).padStart(2,'0')}:${(seconds%60).toFixed(3).padStart(6,'0')}`;
const status = text => { $('status').textContent = text; };
const error = text => { $('form-error').textContent = text; $('form-error').hidden = !text; };
const draftKey = () => `review-draft:${batch.batch_id}:${reviewer}:${current().event_id}`;

async function api(path, options = {}) {
  const response = await fetch(path, {...options, headers:{'Content-Type':'application/json','X-Review-Token':token || '',...(options.headers || {})}});
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || `Request failed (${response.status})`);
  return data;
}
function stop() { clearTimeout(timer); timer = null; $('play').textContent = 'Play history'; }
function displayed() { return current().frames[frameIndex]; }
function showFrame(index) {
  frameIndex = Math.max(0, Math.min(current().frames.length - 1, index));
  const frame = displayed();
  $('frame').src = images[frameIndex]?.src || `/frames/${frame.frame_id}`;
  $('timeline').value = String(frameIndex);
  $('frame-info').textContent = `${frameIndex+1}/${current().frames.length} · ${stamp(frame.source_time_s)}`;
  $('back-frame').disabled = !ready || frameIndex === 0;
  $('next-frame').disabled = !ready || frameIndex === current().frames.length - 1;
  $('mark-evidence').textContent = evidence.has(frame.frame_id) ? 'Unmark this evidence frame' : 'Mark this frame as evidence';
}
function play() {
  if (!ready) return;
  if (timer !== null) { stop(); return; }
  if (frameIndex === current().frames.length - 1) showFrame(0);
  $('play').textContent = 'Pause';
  function step() {
    if (frameIndex >= current().frames.length - 1) { stop(); return; }
    const delay = (current().frames[frameIndex+1].source_time_s - displayed().source_time_s) * 1000;
    timer = setTimeout(() => { showFrame(frameIndex + 1); step(); }, delay);
  }
  step();
}
function drawEvidence() {
  $('evidence-list').replaceChildren();
  current().frames.filter(f => evidence.has(f.frame_id)).forEach(frame => {
    const button = document.createElement('button'); button.type = 'button';
    button.textContent = `${stamp(frame.source_time_s)} ×`; button.setAttribute('aria-label',`Remove evidence at ${stamp(frame.source_time_s)}`);
    button.onclick = () => { evidence.delete(frame.frame_id); if (speedFrame === frame.frame_id) speedFrame = null; drawEvidence(); speedHint(); markDirty(); showFrame(frameIndex); };
    $('evidence-list').append(button);
  });
}
function speedHint() {
  const frame = current().frames.find(f => f.frame_id === speedFrame);
  $('speed-frame').textContent = frame ? `Speed observed at ${stamp(frame.source_time_s)}.` : 'Enter speed while its supporting frame is displayed.';
}
function readForm() {
  return {speed:$('speed').value, unit:$('unit').value, direction:$('direction').value, target:$('target').value,
    phase:$('phase').value, notes:$('notes').value, speedUnknown:$('speed-unknown').checked,
    independent:$('independent').checked, evidence:[...evidence], speedFrame};
}
function applyForm(value) {
  $('speed').value = value.speed ?? ''; $('unit').value = value.unit ?? '';
  $('direction').value = value.direction ?? ''; $('target').value = value.target ?? '';
  $('phase').value = value.phase ?? ''; $('notes').value = value.notes ?? '';
  $('speed-unknown').checked = Boolean(value.speedUnknown); $('speed').disabled = Boolean(value.speedUnknown);
  $('independent').checked = Boolean(value.independent); evidence = new Set(value.evidence || []); speedFrame = value.speedFrame || null;
  drawEvidence(); speedHint();
}
function markDirty() {
  dirty = true; $('saved-state').textContent = 'Unsaved changes'; error('');
  try { localStorage.setItem(draftKey(), JSON.stringify({baseRevision, value:readForm()})); }
  catch { status('Browser draft storage is unavailable. Use Save before leaving this page.'); }
}
function drawNav() {
  $('cases').replaceChildren();
  batch.cases.forEach((c, index) => {
    const button = document.createElement('button'); button.type = 'button'; button.textContent = String(index+1).padStart(2,'0');
    button.setAttribute('aria-current',String(index === caseIndex)); button.setAttribute('aria-label',`Moment ${index+1}${labels[c.event_id] ? ', saved' : ', not saved'}`);
    if (labels[c.event_id]) button.classList.add('done');
    button.disabled = saving;
    button.onclick = () => { if (!dirty || confirm('This label has unsaved changes. Leave it as a browser draft?')) loadCase(index); };
    $('cases').append(button);
  });
  $('progress').textContent = `${Object.keys(labels).length} / ${batch.cases.length} saved`;
}
async function loadCase(index) {
  stop(); ready = false; const generation = ++loadGeneration; caseIndex = index; dirty = false; error('');
  $('workspace').scrollIntoView({block:'start',behavior:'instant'});
  $('zoom').checked = false; $('frame').parentElement.classList.remove('full-size');
  const c = current(); const saved = labels[c.event_id]; baseRevision = saved?.revision || 0;
  $('case-title').textContent = `Moment ${String(index+1).padStart(2,'0')}`;
  $('interval').textContent = `${stamp(c.input_interval_s[0])} → decision ${stamp(c.decision_time_s)}`;
  $('timeline').max = String(c.frames.length - 1);
  let value = saved ? {speed:saved.observations.hud_speed_displayed ?? '', unit:saved.observations.hud_unit,
    direction:saved.observations.turn_direction,target:saved.observations.turn_target,phase:saved.observations.corner_phase,
    notes:saved.notes,speedUnknown:saved.observations.hud_speed_displayed === null, independent:true,
    evidence:saved.evidence_frame_ids,speedFrame:saved.observations.speed_source_frame_id} : {};
  try {
    const draft = JSON.parse(localStorage.getItem(draftKey()) || 'null');
    if (draft && draft.baseRevision === baseRevision) { value = draft.value; dirty = true; }
  } catch { /* A corrupt/unavailable browser draft never replaces saved disk labels. */ }
  applyForm(value); drawNav(); $('saved-state').textContent = dirty ? 'Unsaved draft restored' : saved ? `Saved · revision ${saved.revision}` : 'Not saved';
  $('save').textContent = index === batch.cases.length-1 ? 'Save label' : 'Save & next';
  $('loading').hidden = false; $('loading').textContent = 'Loading history…';
  for (const id of ['play','timeline','mark-evidence','save','back-frame','next-frame']) $(id).disabled = true;
  const nextImages = c.frames.map(f => { const img = new Image(); img.src = `/frames/${f.frame_id}`; return img; });
  images = nextImages; showFrame(c.frames.length - 1);
  try {
    await Promise.all(nextImages.map(img => img.decode()));
    if (generation !== loadGeneration) return;
    ready = true; $('loading').hidden = true;
    for (const id of ['play','timeline','mark-evidence','save']) $(id).disabled = false;
    showFrame(frameIndex);
  } catch {
    if (generation !== loadGeneration) return;
    $('loading').textContent = 'Could not load every frame. Reload before labeling.';
    error('Incomplete history: saving is disabled. No missing frames are silently replaced.');
  }
}
async function start(event) {
  event.preventDefault(); const name = $('reviewer').value.trim();
  if (!name) return;
  $('start').disabled = true;
  try {
    const result = await api(`/api/labels?reviewer=${encodeURIComponent(name)}`);
    reviewer = name; labels = result.labels;
    $('reviewer-display').textContent = `Reviewer: ${reviewer} · Independent labels, pending second review`;
    $('setup').hidden = true; $('workspace').hidden = false; status('');
    await loadCase(Math.max(0,batch.cases.findIndex(c => !labels[c.event_id])));
  } catch (e) { status(e.message); }
  finally { $('start').disabled = false; }
}
async function save(event) {
  event.preventDefault(); stop(); if (!ready || saving) return;
  if (!$('speed-unknown').checked && $('speed').value.trim() === '') { error('Enter the displayed speed, or explicitly mark it unknown.'); return; }
  const value = $('speed-unknown').checked ? null : Number($('speed').value);
  if (value !== null && (!Number.isInteger(value) || value < 0 || value > 999)) { error('Use a whole displayed value from 0–999, or Unknown.'); return; }
  const payload = {batch_id:batch.batch_id,event_id:current().event_id,reviewer_id:reviewer,base_revision:baseRevision,
    independent_of_teacher:$('independent').checked,notes:$('notes').value,evidence_frame_ids:[...evidence],
    observations:{hud_speed_displayed:value,hud_unit:$('unit').value,speed_source_frame_id:value === null ? null : speedFrame,
      turn_direction:$('direction').value,turn_target:$('target').value,corner_phase:$('phase').value}};
  saving = true; $('save').disabled = true; $('change-reviewer').disabled = true;
  fields.forEach(id => $(id).disabled = true); $('mark-evidence').disabled = true; drawNav();
  try {
    const result = await api('/api/labels',{method:'POST',body:JSON.stringify(payload)});
    labels[current().event_id] = result.label; baseRevision = result.label.revision; dirty = false;
    try { localStorage.removeItem(draftKey()); } catch { /* Disk save remains authoritative. */ }
    $('saved-state').textContent = `Saved · revision ${result.label.revision}`;
    status(`${current().event_id} saved on your Mac.${Object.keys(labels).length === batch.cases.length ? ' All ten moments are saved; these still need independent checking.' : ''}`);
    if (caseIndex < batch.cases.length-1) await loadCase(caseIndex+1);
  } catch (e) { error(e.message); status('Not saved. Your inputs are still here.'); }
  finally {
    saving = false; $('save').disabled = !ready; $('change-reviewer').disabled = false;
    fields.forEach(id => $(id).disabled = false); $('speed').disabled = $('speed-unknown').checked;
    $('mark-evidence').disabled = !ready; drawNav();
  }
}
async function exportLabels() {
  $('export').disabled = true;
  try {
    const result = await api('/api/export',{method:'POST',body:JSON.stringify({batch_id:batch.batch_id,reviewer_id:reviewer})});
    status(`Exported ${result.label_count} saved labels to ${result.path}. Unsaved drafts are not included.`);
  } catch(e) { status(`Export failed: ${e.message}`); }
  finally { $('export').disabled = false; }
}
async function boot() {
  try {
    const data = await api('/api/bootstrap'); batch = data.batch; token = data.token; $('start').disabled = false;
    $('reviewer-form').onsubmit = start; $('label-form').onsubmit = save; $('play').onclick = play;
    $('back-frame').onclick = () => { stop(); showFrame(frameIndex-1); };
    $('next-frame').onclick = () => { stop(); showFrame(frameIndex+1); };
    $('timeline').oninput = () => { stop(); showFrame(Number($('timeline').value)); };
    $('zoom').onchange = () => $('frame').parentElement.classList.toggle('full-size',$('zoom').checked);
    $('view-frame').onclick = () => $('case-title').scrollIntoView({block:'start',behavior:'instant'});
    $('mark-evidence').onclick = () => {
      const id = displayed().frame_id;
      if (evidence.has(id)) { evidence.delete(id); if (speedFrame === id) speedFrame = null; } else evidence.add(id);
      drawEvidence(); speedHint(); markDirty(); showFrame(frameIndex);
    };
    fields.forEach(id => $(id).addEventListener('input',() => {
      if (id === 'speed-unknown') { $('speed').disabled = $('speed-unknown').checked; if ($('speed-unknown').checked) { $('speed').value = ''; speedFrame = null; } }
      if (id === 'speed' && $('speed').value !== '') { speedFrame = displayed().frame_id; evidence.add(speedFrame); }
      drawEvidence(); speedHint(); showFrame(frameIndex); markDirty();
    }));
    $('export').onclick = exportLabels;
    $('change-reviewer').onclick = () => {
      if (dirty && !confirm('Leave this label as an unsaved browser draft and change reviewer?')) return;
      stop(); ++loadGeneration; dirty = false; $('workspace').hidden = true; $('setup').hidden = false; status(''); $('reviewer').focus();
    };
    window.addEventListener('beforeunload',event => { if (dirty) { event.preventDefault(); event.returnValue = ''; } });
  } catch(e) { $('fatal').hidden = false; $('fatal').textContent = `Review tool could not start: ${e.message}`; }
}
boot();
