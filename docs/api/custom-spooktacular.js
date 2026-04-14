(function() {
  'use strict';

  function el(tag, attrs, children) {
    var e = document.createElement(tag);
    if (attrs) Object.keys(attrs).forEach(function(k) {
      if (k === 'text') e.textContent = attrs[k];
      else if (k === 'className') e.className = attrs[k];
      else e.setAttribute(k, attrs[k]);
    });
    if (children) children.forEach(function(c) { e.appendChild(c); });
    return e;
  }

  function link(href, text, cls) {
    var a = el('a', { href: href, text: text });
    if (cls) a.className = cls;
    if (href.startsWith('http')) a.setAttribute('target', '_blank');
    return a;
  }

  function injectBanner() {
    if (document.querySelector('.spook-banner')) return;
    var logo = el('a', { href: '/index.html', className: 'spook-banner-logo' }, [
      el('span', { text: 'Spooktacular' })
    ]);
    var links = el('div', { className: 'spook-banner-links' }, [
      link('/features.html', 'Features'),
      link('/compare.html', 'Compare'),
      link('/roadmap.html', 'Roadmap'),
      link('https://github.com/Spooky-Labs/spooktacular', 'GitHub'),
      link('/get-started.html', 'Get Started'),
      link('/download.html', 'Download', 'spook-banner-cta')
    ]);
    var banner = el('div', { className: 'spook-banner' }, [logo, links]);
    document.body.insertBefore(banner, document.body.firstChild);
  }

  function injectFooter() {
    if (document.querySelector('.spook-footer')) return;
    var footer = el('div', { className: 'spook-footer' });
    var line1 = document.createDocumentFragment();
    [
      link('/privacy.html', 'Privacy'),
      document.createTextNode(' · '),
      link('/terms.html', 'Terms'),
      document.createTextNode(' · '),
      link('https://github.com/Spooky-Labs/spooktacular/blob/main/LICENSE', 'MIT License'),
      document.createTextNode(' · '),
      link('https://github.com/Spooky-Labs/spooktacular', 'GitHub')
    ].forEach(function(n) { line1.appendChild(n); });
    footer.appendChild(line1);
    footer.appendChild(el('br'));
    var copy = document.createDocumentFragment();
    copy.appendChild(document.createTextNode('\u00A9 2026 '));
    copy.appendChild(link('https://github.com/Spooky-Labs', 'Spooky Labs'));
    copy.appendChild(document.createTextNode('. Made with \uD83C\uDF32\uD83C\uDF32\uD83C\uDF32 in Cascadia'));
    footer.appendChild(copy);
    document.body.appendChild(footer);
  }

  function inject() { injectBanner(); injectFooter(); }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', inject);
  } else {
    inject();
  }

  new MutationObserver(inject).observe(document.body, { childList: true, subtree: false });
})();
