const playStore = 'https://play.google.com/store/apps/details?id=app.cht.cht';

function decodeToken(token) {
  const base64 = token.replaceAll('-', '+').replaceAll('_', '/');
  return new TextDecoder('utf-8', { fatal: true })
    .decode(Uint8Array.from(atob(base64), (character) => character.charCodeAt(0)));
}

export function invitationForClipboard(token) {
  if (!shareDestinations(token, '')) return null;
  try {
    const magnet = decodeToken(token);
    const url = new URL(magnet);
    if (url.protocol !== 'magnet:' || url.pathname || url.host || url.hash) return null;
    const topic = url.searchParams.get('xt');
    if (topic === 'urn:chta:contact:1') {
      const card = url.searchParams.get('x.chta-card');
      if (!card || !/^[A-Za-z0-9_-]+$/.test(card)) return null;
      return decodeToken(card);
    }
    return topic === 'urn:chta:group:1' ? magnet : null;
  } catch {
    return null;
  }
}

export function shareDestinations(token, userAgent) {
  if (token.length > 32000 || !/^[A-Za-z0-9_-]+$/.test(token)) return null;
  const web = '/chat/contacts#chta=' + token;
  if (/Android/i.test(userAgent)) {
    const open = 'intent://share/open?payload=' + token +
      '#Intent;scheme=chta;package=app.cht.cht;S.browser_fallback_url=' +
      encodeURIComponent(playStore) + ';end';
    return { web, open, download: playStore };
  }
  const ios = /iPhone|iPod|iPad/i.test(userAgent);
  return { web, open: null, download: ios ? null : '/#platforms' };
}

if (typeof document !== 'undefined') {
  const userAgent = navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1
    ? 'iPad'
    : navigator.userAgent;
  const token = window.location.hash.slice(1);
  const destinations = shareDestinations(token, userAgent);
  const invitation = invitationForClipboard(token);
  const show = (id, url) => {
    const link = document.getElementById(id);
    link.hidden = !url;
    if (url) link.href = url;
  };
  if (destinations && invitation) {
    show('open-app', destinations.open);
    show('open-web', destinations.web);
    show('download', destinations.download);
    const copy = document.getElementById('copy');
    copy.hidden = false;
    copy.addEventListener('click', async () => {
      const status = document.getElementById('status');
      try {
        await navigator.clipboard.writeText(invitation);
        status.textContent = 'Copied. Paste it in Contacts in chta.';
      } catch {
        status.textContent = 'Could not copy the invitation. Try opening it in chta.';
      }
    });
    if (destinations.open) document.getElementById('download').textContent = 'Get it on Google Play';
  } else {
    document.getElementById('status').textContent = 'Ask the sender for a new invitation link.';
  }
}
