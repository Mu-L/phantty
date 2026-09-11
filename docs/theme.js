// Apply before styles paint; only an explicit choice overrides the OS theme.
(() => {
  const key = 'wispterm-site-theme';
  const root = document.documentElement;
  const system = window.matchMedia('(prefers-color-scheme: light)');
  const valid = value => value === 'light' || value === 'dark';
  let preference = null;
  try { preference = localStorage.getItem(key); } catch { /* Storage may be disabled. */ }
  if (!valid(preference)) preference = null;

  function apply() {
    const light = (preference || (system.matches ? 'light' : 'dark')) === 'light';
    root.dataset.theme = light ? 'light' : 'dark';
    const chinese = root.lang.startsWith('zh');
    document.querySelectorAll('[data-theme-toggle]').forEach(button => {
      const label = chinese ? `切换到${light ? '暗色' : '亮色'}模式` : `Switch to ${light ? 'dark' : 'light'} mode`;
      button.setAttribute('aria-label', chinese ? '亮色模式' : 'Light mode');
      button.setAttribute('aria-checked', String(light));
      button.title = label;
    });
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.content = light ? '#f7f9fc' : '#1b1e28';
  }

  apply();
  document.addEventListener('DOMContentLoaded', () => {
    apply();
    document.querySelectorAll('[data-theme-toggle]').forEach(button => {
      button.setAttribute('role', 'switch');
      button.innerHTML = `<span class="theme-toggle__thumb" aria-hidden="true">
        <svg class="theme-toggle__sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M4.9 4.9l1.4 1.4m11.4 11.4 1.4 1.4M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/></svg>
        <svg class="theme-toggle__moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20.5 14.1A8.5 8.5 0 0 1 9.9 3.5a8.5 8.5 0 1 0 10.6 10.6Z"/></svg>
      </span>`;
      button.hidden = false;
      button.addEventListener('click', () => {
        preference = root.dataset.theme === 'light' ? 'dark' : 'light';
        try { localStorage.setItem(key, preference); } catch { /* Keep the choice for this page. */ }
        apply();
      });
    });
  });
  system.addEventListener('change', () => { if (!preference) apply(); });
  window.addEventListener('storage', event => {
    if (event.key === key || event.key === null) {
      preference = valid(event.newValue) ? event.newValue : null;
      apply();
    }
  });
})();
