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
      button.textContent = chinese ? (light ? '暗色' : '亮色') : (light ? 'Dark' : 'Light');
      const label = chinese ? `切换到${light ? '暗色' : '亮色'}模式` : `Switch to ${light ? 'dark' : 'light'} mode`;
      button.setAttribute('aria-label', label);
      button.title = label;
    });
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.content = light ? '#f7f9fc' : '#1b1e28';
  }

  apply();
  document.addEventListener('DOMContentLoaded', () => {
    apply();
    document.querySelectorAll('[data-theme-toggle]').forEach(button => {
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
