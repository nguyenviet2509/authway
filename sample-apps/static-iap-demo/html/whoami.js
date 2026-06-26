// Fetch identity từ oauth2-proxy /oauth2/userinfo (same-origin, cookie auto).
(async () => {
  try {
    const res = await fetch('/oauth2/userinfo', { credentials: 'same-origin' });
    if (!res.ok) {
      document.querySelector('#who tbody').innerHTML =
        `<tr><td colspan="2">userinfo HTTP ${res.status}</td></tr>`;
      return;
    }
    const data = await res.json();
    const rows = [
      ['Email', data.email ?? '(missing)'],
      ['Subject', data.user ?? data.sub ?? '(missing)'],
      ['Preferred', data.preferredUsername ?? data.preferred_username ?? '(missing)'],
    ];
    document.querySelector('#who tbody').innerHTML = rows
      .map(([k, v]) => `<tr><td><strong>${k}</strong></td><td>${v}</td></tr>`)
      .join('');
  } catch (err) {
    document.querySelector('#who tbody').innerHTML =
      `<tr><td colspan="2">error: ${err.message}</td></tr>`;
  }
})();
