// Runs in the page's own JavaScript world. Watches fetch/XHR for video streams and subtitle files
// (their text included, since the page's cookies and tokens are already applied) and hands them
// to content.js with window.postMessage.
(() => {
  if (window.__softSubsHooked) return;
  window.__softSubsHooked = true;
  document.documentElement?.setAttribute('data-softsubs-hooked', '');

  const STREAM = /\.(m3u8|mpd|mp4|m4v|mov)(\?|#|$)/i;
  const SUBTITLE_URL = /\.(vtt|webvtt|srt|ttml|dfxp)(\?|#|$)/i;
  const SUBTITLE_TYPE = /vtt|ttml|srt|subrip|text\/plain|xml/i;
  const MAX_TEXT = 5 * 1024 * 1024;

  const post = (message) => window.postMessage({ source: 'softsubs-hook', ...message }, '*');

  const streamType = (url, contentType) => {
    if (/mpegurl/i.test(contentType) || /\.m3u8/i.test(url)) return 'hls';
    if (/dash\+xml/i.test(contentType) || /\.mpd/i.test(url)) return 'dash';
    return 'file';
  };

  const looksLikeSubtitles = (text) =>
    /^﻿?WEBVTT/.test(text) ||
    /<tt[\s>]/.test(text.slice(0, 4000)) ||
    /^﻿?\s*\d+\s*\r?\n\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->/.test(text);

  const inspect = (rawUrl, contentType, readText) => {
    let url;
    try { url = new URL(rawUrl, location.href).href; } catch { return; }
    if (!/^https?:/.test(url)) return;
    if (STREAM.test(url) || /mpegurl|dash\+xml/i.test(contentType)) {
      post({ kind: 'stream', url, type: streamType(url, contentType) });
    }
    if (!SUBTITLE_URL.test(url) && !SUBTITLE_TYPE.test(contentType)) return;
    Promise.resolve()
      .then(readText)
      .then((text) => {
        if (typeof text === 'string' && text.length < MAX_TEXT && looksLikeSubtitles(text)) {
          post({ kind: 'subtitles', url, text });
        }
      })
      .catch(() => {});
  };

  const originalFetch = window.fetch;
  window.fetch = function (input, init) {
    const promise = originalFetch.apply(this, arguments);
    promise.then((response) => {
      const url = response.url || (input && input.url) || String(input);
      inspect(url, response.headers.get('content-type') || '', () => response.clone().text());
    }, () => {});
    return promise;
  };

  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__softSubsUrl = url;
    return originalOpen.apply(this, arguments);
  };

  const originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function () {
    this.addEventListener('load', () => {
      inspect(this.responseURL || String(this.__softSubsUrl), this.getResponseHeader('content-type') || '', () => {
        if (this.responseType === '' || this.responseType === 'text') return this.responseText;
        if (this.response instanceof ArrayBuffer && this.response.byteLength < MAX_TEXT) {
          return new TextDecoder().decode(this.response);
        }
        return null;
      });
    });
    return originalSend.apply(this, arguments);
  };
})();
