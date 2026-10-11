// Parses WebVTT, SRT and TTML/DFXP into cues: [{ start, end, text }] with times in seconds.
// Cue text keeps <i>, <b> and <u>, which WebVTT supports; other markup is dropped.
(() => {
  const CLOCK = /(?:(\d+):)?(\d{1,2}):(\d{2})(?:[.,](\d{1,3}))?/;

  const clock = (value) => {
    const match = CLOCK.exec(value || '');
    if (!match) return NaN;
    const [, hours, minutes, seconds, fraction = '0'] = match;
    return (+hours || 0) * 3600 + +minutes * 60 + +seconds + +fraction.padEnd(3, '0') / 1000;
  };

  const clean = (text) =>
    text
      .replace(/\{\\[^}]*\}/g, '')
      .replace(/<(?!\/?(?:i|b|u)>)[^>]*>/g, '')
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean)
      .join('\n');

  // WebVTT and SRT share the same block layout: optional id, "start --> end", then text lines.
  function parseBlocks(text) {
    const cues = [];
    for (const block of text.replace(/\r\n?/g, '\n').split(/\n\s*\n/)) {
      const lines = block.split('\n');
      const timing = lines.findIndex((line) => line.includes('-->'));
      if (timing < 0) continue;
      const [from, to] = lines[timing].split('-->');
      const start = clock(from);
      const end = clock(to);
      const body = clean(lines.slice(timing + 1).join('\n'));
      if (Number.isFinite(start) && Number.isFinite(end) && end > start && body) cues.push({ start, end, text: body });
    }
    return cues;
  }

  const TTP = 'http://www.w3.org/ns/ttml#parameter';
  const TTS = 'http://www.w3.org/ns/ttml#styling';

  function parseTTML(text) {
    const doc = new DOMParser().parseFromString(text, 'application/xml');
    if (doc.getElementsByTagName('parsererror').length) return [];
    const root = doc.documentElement;
    const parameter = (name) => root.getAttributeNS(TTP, name) || root.getAttribute(`ttp:${name}`);
    const tickRate = +parameter('tickRate') || 10_000_000;
    const frameRate = +parameter('frameRate') || 30;

    const time = (value) => {
      if (!value) return NaN;
      let match = /^([\d.]+)(h|ms|m|s|f|t)$/.exec(value.trim());
      if (match) {
        const n = +match[1];
        return { h: n * 3600, m: n * 60, s: n, ms: n / 1000, f: n / frameRate, t: n / tickRate }[match[2]];
      }
      match = /^(\d+):(\d{2}):(\d{2}):(\d{2})$/.exec(value.trim());
      if (match) return +match[1] * 3600 + +match[2] * 60 + +match[3] + +match[4] / frameRate;
      return clock(value);
    };

    const textOf = (node) => {
      let output = '';
      for (const child of node.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) {
          output += child.nodeValue.replace(/\s+/g, ' ');
        } else if (child.nodeType === Node.ELEMENT_NODE) {
          if (child.localName === 'br') {
            output += '\n';
          } else {
            const inner = textOf(child);
            const style = child.getAttributeNS(TTS, 'fontStyle') || child.getAttribute('tts:fontStyle') || '';
            output += /italic/.test(style) ? `<i>${inner}</i>` : inner;
          }
        }
      }
      return output;
    };

    const cues = [];
    for (const paragraph of doc.getElementsByTagNameNS('*', 'p')) {
      const start = time(paragraph.getAttribute('begin'));
      let end = time(paragraph.getAttribute('end'));
      if (!Number.isFinite(end)) end = start + time(paragraph.getAttribute('dur'));
      const body = clean(textOf(paragraph));
      if (Number.isFinite(start) && Number.isFinite(end) && end > start && body) cues.push({ start, end, text: body });
    }
    return cues;
  }

  function parse(text) {
    text = String(text || '').replace(/^﻿/, '');
    const cues = /<tt[\s>]/.test(text.slice(0, 4000)) ? parseTTML(text) : text.includes('-->') ? parseBlocks(text) : [];
    return cues.sort((a, b) => a.start - b.start);
  }

  globalThis.SoftSubs = { parse };
})();
