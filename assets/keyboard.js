(() => {
  const rows = () => Array.from(document.querySelectorAll('[data-nav-row] a[href]'));
  let index = -1;
  addEventListener('keydown', (event) => {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;
    if (/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName || '')) return;
    if (event.key !== 'j' && event.key !== 'k') return;
    const links = rows();
    if (!links.length) return;
    index = event.key === 'j' ? Math.min(index + 1, links.length - 1) : Math.max(index - 1, 0);
    links[index].focus();
    links[index].scrollIntoView({ block: 'nearest' });
    event.preventDefault();
  });
})();
