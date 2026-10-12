const api = globalThis.browser ?? globalThis.chrome;
const HELPER = 'http://127.0.0.1:47800';
const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

let tab;
let frame;
let choices = [];
let devices = null; // Windows helper only: TVs it can send to. The Mac app uses macOS AirPlay instead.
const isSafari = typeof api.runtime.sendNativeMessage === 'function' && !!globalThis.browser;

async function helper(path, body) {
  const response = await fetch(HELPER + path, body
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
    : {});
  const json = await response.json();
  if (!response.ok || json.ok === false) throw new Error(json.error || `Soft Subs returned ${response.status}`);
  return json;
}

function setHelper(text, tone) {
  $('helper').textContent = text;
  $('helper').className = `pill ${tone}`;
}

// The helper app hosts the stream for the TV. If it isn't running, launch it (Safari: through the
// extension's native handler; Chrome on Windows: through the softsubs:// link the installer registers),
// then wait for its server to come up.
async function ensureHelper() {
  try {
    return await helper('/api/status');
  } catch {}
  setHelper('Starting app…', 'warn');
  try {
    if (isSafari) {
      await api.runtime.sendNativeMessage('com.keivi.softsubs', { action: 'launchApp' });
    } else {
      const launcher = await api.tabs.create({ url: 'softsubs://start', active: false });
      setTimeout(() => api.tabs.remove(launcher.id).catch(() => {}), 3000);
    }
  } catch {}
  for (let attempt = 0; attempt < 20; attempt++) {
    await sleep(500);
    try {
      return await helper('/api/status');
    } catch {}
  }
  return null;
}

async function scanFrames() {
  const results = new Map();
  const listener = (message, sender) => {
    if (message?.type === 'softsubs:scan-result' && sender.tab?.id === tab.id) {
      results.set(message.result.frameKey, message.result);
    }
  };
  api.runtime.onMessage.addListener(listener);
  try {
    const direct = await api.tabs.sendMessage(tab.id, { type: 'softsubs:scan' });
    if (direct) results.set(direct.frameKey, direct);
  } catch {}
  await sleep(500);
  api.runtime.onMessage.removeListener(listener);
  return [...results.values()];
}

function pickFrame(frames) {
  const withVideo = frames.filter((f) => f.video);
  withVideo.sort((a, b) => !b.video.paused - !a.video.paused || b.video.area - a.video.area);
  const best = withVideo[0];
  if (!best) return null;
  // Streams are sometimes requested from a different frame (or the top page); fall back to those.
  if (!best.streams.length) best.streams = frames.flatMap((f) => f.streams);
  return best;
}

function rankStreams(streams) {
  const score = (s) =>
    ({ hls: 30, dash: 20, file: 10 }[s.type] ?? 0) +
    (/master|playlist|index/i.test(s.url) ? 5 : 0) -
    (/subtitle|caption|audio|\.vtt|i-?frame/i.test(s.url) ? 25 : 0) -
    s.order * 0.01;
  const unique = [...new Map(streams.map((s) => [s.url, s])).values()];
  return unique.sort((a, b) => score(b) - score(a));
}

const formatTime = (seconds) => {
  if (!Number.isFinite(seconds)) return '';
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`;
};

function buildChoices(subtitles, streamType, duration) {
  const list = subtitles.map((track) => {
    const lastEnd = track.cues.length ? track.cues[track.cues.length - 1].end : 0;
    const coverage = duration && track.cues.length ? lastEnd / duration : track.src ? 1 : 0;
    let detail = track.src && !track.cues.length ? 'Subtitle file' : `${track.cues.length} lines`;
    if (coverage < 0.5 && duration && !track.src) {
      detail += `, partial (${Math.round(lastEnd / 60)} of ${Math.round(duration / 60)} min loaded)`;
    }
    if (track.showing) detail += ' · showing now';
    return { ...track, coverage, detail };
  });
  if (streamType === 'hls') {
    list.push({ id: 'builtin', label: "Stream's own subtitles", detail: 'Uses subtitle tracks inside the stream, if any', builtIn: true });
  }
  list.push({ id: 'none', label: 'No subtitles', detail: '', none: true });
  return list;
}

function defaultChoice(list) {
  const tracks = list.filter((c) => c.cues || c.src);
  const complete = tracks.filter((c) => c.coverage >= 0.5);
  return (
    complete.find((c) => c.showing) ??
    complete[0] ??
    list.find((c) => c.builtIn) ??
    tracks.find((c) => c.showing) ??
    tracks[0] ??
    list[list.length - 1]
  ).id;
}

function renderSubtitles(selectedId) {
  const container = $('subtitles');
  container.replaceChildren();
  for (const choice of choices) {
    const label = document.createElement('label');
    label.className = 'option';
    const input = document.createElement('input');
    input.type = 'radio';
    input.name = 'subtitles';
    input.value = choice.id;
    input.checked = choice.id === selectedId;
    const text = document.createElement('div');
    text.textContent = choice.label + (choice.language && choice.language !== choice.label ? ` (${choice.language})` : '');
    if (choice.detail) {
      const small = document.createElement('small');
      small.textContent = choice.detail;
      text.append(small);
    }
    label.append(input, text);
    container.append(label);
  }
}

function render() {
  const video = frame.video;
  $('found').hidden = false;
  $('video-title').textContent = tab.title || 'Video';
  $('video-time').textContent = video.duration
    ? `${formatTime(video.currentTime)} / ${formatTime(video.duration)}`
    : formatTime(video.currentTime);

  const streams = rankStreams(frame.streams);
  const select = $('stream');
  select.replaceChildren();
  for (const stream of streams) {
    const option = document.createElement('option');
    option.value = stream.url;
    option.dataset.type = stream.type;
    const path = new URL(stream.url).pathname.split('/').slice(-2).join('/');
    option.textContent = `${stream.type.toUpperCase()} · ${path}`;
    option.title = stream.url;
    select.append(option);
  }
  if (!streams.length) {
    $('status').textContent = "Couldn't find the stream URL. Reload the page with the extension enabled, start the video, then try again.";
  }

  const refreshChoices = () => {
    const type = select.selectedOptions[0]?.dataset.type;
    choices = buildChoices(frame.subtitles, type, video.duration);
    renderSubtitles(defaultChoice(choices));
  };
  select.onchange = refreshChoices;
  refreshChoices();
  $('send').disabled = !streams.length;
}

async function buildHeaders(url) {
  const headers = { 'User-Agent': navigator.userAgent };
  try {
    // Match Safari's default referrer policy: cross-site requests only carry the page's origin.
    // Many video hosts reject a full page URL as hotlinking.
    const page = new URL(frame.pageUrl);
    headers.Referer = page.origin === new URL(url).origin ? page.href : `${page.origin}/`;
    headers.Origin = page.origin;
  } catch {}
  try {
    const cookies = await api.cookies.getAll({ url });
    if (cookies.length) headers.Cookie = cookies.map((c) => `${c.name}=${c.value}`).join('; ');
  } catch {}
  return headers;
}

// Asks the Windows helper for TVs. Searching the network takes a few seconds, so this shows what's known
// straight away and keeps polling while the helper is still searching.
async function loadDevices(refresh = false) {
  $('tv').hidden = false;
  let result;
  try {
    result = await helper(`/api/devices${refresh ? '?refresh=1' : ''}`);
    renderDevices(result);
    for (let attempt = 0; result.scanning && attempt < 20; attempt++) {
      await sleep(1000);
      result = await helper('/api/devices');
      renderDevices(result);
    }
  } catch {
    renderDevices({ devices: [], scanning: false });
  }
}

function renderDevices(result) {
  devices = result.devices;
  const select = $('device');
  const previous = select.value;
  const saved = localStorage.getItem('softsubs:device');
  select.replaceChildren();
  for (const device of devices) {
    const option = document.createElement('option');
    option.value = device.id;
    option.textContent = device.name;
    select.append(option);
  }
  // Keep the current or last-used TV; otherwise the first one found.
  const pick = [previous, saved].find((id) => devices.some((d) => d.id === id)) ?? devices[0]?.id;
  if (pick) select.value = pick;
  $('no-tvs').hidden = devices.length > 0 || result.scanning;
  $('searching').hidden = !result.scanning;
  updateSendLabel();
}

function selectedDevice() {
  return devices?.find((d) => d.id === $('device').value) ?? null;
}

function updateSendLabel() {
  const device = selectedDevice();
  $('send').textContent = !devices ? 'Send to TV' : device ? `Send to ${device.name}` : 'Choose a TV';
  if (devices) $('send').disabled = !device || !$('stream').value;
}

function openPanel() {
  api.tabs.create({ url: `${HELPER}/` });
}

async function send() {
  const device = selectedDevice();
  if (device) localStorage.setItem('softsubs:device', device.id);
  const url = $('stream').value;
  const selectedId = document.querySelector('input[name="subtitles"]:checked')?.value;
  const choice = choices.find((c) => c.id === selectedId) ?? choices[choices.length - 1];
  $('send').disabled = true;
  $('status').textContent = 'Sending…';

  try {
    let subtitles = null;
    if (choice.src || choice.cues?.length) {
      let cues = choice.cues ?? [];
      // A <track> file is the complete set; loaded cues may only cover what has played so far.
      if (choice.src) {
        try {
          const fetched = SoftSubs.parse(await (await fetch(choice.src, { credentials: 'include' })).text());
          if (fetched.length) cues = fetched;
        } catch {}
      }
      if (!cues.length) throw new Error("Couldn't read that subtitle track.");
      subtitles = { label: choice.label, language: choice.language || '', cues };
    }

    await helper('/api/cast', {
      url,
      title: tab.title,
      headers: await buildHeaders(url),
      startTime: frame.video.currentTime,
      duration: frame.video.duration,
      subtitles,
      subtitlesOff: !!choice.none,
      preferredLanguage: choice.language || null,
      device: device?.id,
    });
    Promise.resolve(api.tabs.sendMessage(tab.id, { type: 'softsubs:pause', frameKey: frame.frameKey })).catch(() => {});
    watchStatus();
  } catch (error) {
    $('status').textContent = error.message;
    $('send').disabled = false;
  }
}

async function watchStatus() {
  for (;;) {
    try {
      const status = await helper('/api/status');
      $('status').textContent = status.platform !== 'windows' && status.playing && !status.onTV
        ? 'Playing on your Mac. Click the AirPlay button in the Soft Subs video controls.'
        : status.phase;
    } catch {
      $('status').textContent = 'Lost contact with the Soft Subs app.';
    }
    await sleep(1000);
  }
}

async function main() {
  [tab] = await api.tabs.query({ active: true, currentWindow: true });
  $('send').onclick = send;

  const [status, frames] = await Promise.all([ensureHelper(), scanFrames()]);
  // Chrome on Windows: the installer updates the extension's files on disk; reload once to pick them up.
  const mine = api.runtime.getManifest().version;
  if (!isSafari && status?.version && status.version !== mine && localStorage.getItem('softsubs:reloaded') !== status.version) {
    localStorage.setItem('softsubs:reloaded', status.version);
    api.runtime.reload();
    return;
  }
  if (status?.update?.available) {
    setHelper(`Update ${status.update.latest} available`, 'warn');
    $('helper').style.cursor = 'pointer';
    $('helper').onclick = openPanel;
  } else if (status) {
    setHelper(status.ffmpeg ? 'App ready' : 'App ready · no ffmpeg', status.ffmpeg ? 'ok' : 'warn');
  } else {
    setHelper('App not running', 'bad');
    $('status').textContent = 'Open the Soft Subs app (Start menu on Windows, Applications on Mac), then try again.';
  }

  frame = pickFrame(frames);
  if (!frame) {
    $('empty').hidden = false;
  } else {
    render();
    updateSendLabel();
    if (!status) $('send').disabled = true;
  }

  if (frame && status?.features?.includes('devices')) {
    $('device').onchange = updateSendLabel;
    $('refresh-tvs').onclick = (event) => { event.preventDefault(); loadDevices(true); };
    $('manage-tvs').onclick = (event) => { event.preventDefault(); openPanel(); };
    loadDevices();
  }
}

main();
