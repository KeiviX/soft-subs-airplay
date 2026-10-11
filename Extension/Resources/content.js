// Runs in every frame. Collects what page-hook.js saw on the network, plus the page's <video> elements
// and text tracks, and reports it to the popup when asked.
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  const frameKey = Math.random().toString(36).slice(2);
  const streams = new Map();
  const networkSubtitles = new Map();
  const MAX_NETWORK_SUBTITLES = 30;
  const STREAM = /\.(m3u8|mpd|mp4|m4v|mov)(\?|#|$)/i;

  const typeOf = (url) => (/\.m3u8/i.test(url) ? 'hls' : /\.mpd/i.test(url) ? 'dash' : 'file');

  const addStream = (url, type = typeOf(url)) => {
    if (/^https?:/.test(url) && !streams.has(url)) streams.set(url, { url, type, order: streams.size });
  };

  window.addEventListener('message', (event) => {
    const data = event.data;
    if (event.source !== window || !data || data.source !== 'softsubs-hook') return;
    if (data.kind === 'stream') addStream(data.url, data.type);
    if (data.kind === 'subtitles' && networkSubtitles.size < MAX_NETWORK_SUBTITLES) networkSubtitles.set(data.url, data.text);
  });

  // If Safari didn't run page-hook.js in the page world from the manifest, inject it as a script tag.
  setTimeout(() => {
    if (document.documentElement?.hasAttribute('data-softsubs-hooked')) return;
    const script = document.createElement('script');
    script.src = api.runtime.getURL('page-hook.js');
    script.onload = () => script.remove();
    (document.head || document.documentElement)?.append(script);
  }, 0);

  const cuesOf = (track) => {
    try {
      return track?.cues
        ? Array.from(track.cues, (cue) => ({ start: cue.startTime, end: cue.endTime, text: cue.text ?? '' })).filter((cue) => cue.text)
        : [];
    } catch {
      return [];
    }
  };

  const describe = (video) => {
    const rect = video.getBoundingClientRect();
    const src = video.currentSrc || video.src || '';
    return {
      currentTime: video.currentTime,
      duration: Number.isFinite(video.duration) ? video.duration : null,
      paused: video.paused,
      area: Math.round(rect.width * rect.height),
      src: /^https?:/.test(src) ? src : null,
    };
  };

  const labelFromUrl = (url) => {
    try {
      return decodeURIComponent(new URL(url).pathname.split('/').pop()).replace(/\.\w+$/, '') || 'Subtitles';
    } catch {
      return 'Subtitles';
    }
  };

  const bestVideo = () =>
    [...document.querySelectorAll('video')].sort(
      (a, b) => (!b.paused) - (!a.paused) || b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight
    )[0];

  function scan() {
    for (const entry of performance.getEntriesByType('resource')) {
      if (STREAM.test(entry.name)) addStream(entry.name);
    }

    const videos = [...document.querySelectorAll('video')];
    const subtitles = [];
    videos.forEach((video, videoIndex) => {
      const src = video.currentSrc || video.src;
      if (/^https?:/.test(src)) addStream(src);

      const elements = [...video.querySelectorAll('track')];
      for (const element of elements) {
        if (!['subtitles', 'captions', ''].includes(element.kind) || !element.src) continue;
        subtitles.push({
          id: `track:${element.src}`,
          label: element.label || element.srclang || 'Subtitles',
          language: element.srclang || '',
          src: element.src,
          showing: element.track?.mode === 'showing',
          cues: cuesOf(element.track),
        });
      }
      Array.from(video.textTracks).forEach((track, trackIndex) => {
        if (!['subtitles', 'captions'].includes(track.kind)) return;
        if (elements.some((element) => element.track === track)) return;
        const cues = cuesOf(track);
        if (!cues.length) return;
        subtitles.push({
          id: `texttrack:${videoIndex}:${trackIndex}`,
          label: track.label || track.language || 'Subtitles',
          language: track.language || '',
          showing: track.mode === 'showing',
          cues,
        });
      });
    });

    for (const [url, text] of networkSubtitles) {
      // HLS subtitle segments carry X-TIMESTAMP-MAP; they're fragments, not whole files.
      if (/X-TIMESTAMP-MAP/.test(text)) continue;
      const cues = SoftSubs.parse(text);
      if (cues.length) subtitles.push({ id: `net:${url}`, label: labelFromUrl(url), language: '', cues });
    }

    const best = bestVideo();
    return {
      frameKey,
      pageUrl: location.href,
      isTop: window === window.top,
      video: best ? describe(best) : null,
      streams: [...streams.values()],
      subtitles,
    };
  }

  api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === 'softsubs:scan') {
      const result = scan();
      // Frames without a video only broadcast, so they can't win the race to answer the popup.
      Promise.resolve(api.runtime.sendMessage({ type: 'softsubs:scan-result', result })).catch(() => {});
      if (!result.video) return false;
      sendResponse(result);
      return false;
    }
    if (message?.type === 'softsubs:pause' && message.frameKey === frameKey) {
      bestVideo()?.pause();
    }
    return false;
  });
})();
