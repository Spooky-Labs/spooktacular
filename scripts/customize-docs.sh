#!/bin/bash
# Post-processes DocC output to add Spooktacular branding.
#
# Injects custom CSS (matching spooktacular.app design) and a
# small script that adds our navbar + footer to the DocC SPA.
#
# Usage: ./scripts/customize-docs.sh
# Run after ./scripts/build-docs.sh --static
#
# This is automated — build-docs.sh calls it automatically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOCS_DIR="$PROJECT_DIR/docs/api"

if [ ! -f "$DOCS_DIR/index.html" ]; then
    echo "Error: DocC output not found at $DOCS_DIR/index.html"
    echo "Run ./scripts/build-docs.sh --static first."
    exit 1
fi

echo "Customizing DocC output..."

# 1. Create custom CSS
cat > "$DOCS_DIR/custom-spooktacular.css" << 'CSSEOF'
/* Spooktacular DocC Branding — matches spooktacular.app design */

/* Dark mode overrides */
[data-color-scheme="dark"] body, body {
  --color-fill: #07050f;
  --color-fill-secondary: #0f0a1a;
  --color-fill-tertiary: #1a1035;
  --color-nav-solid-background: rgba(7, 5, 15, 0.85);
}

:root {
  --color-link: #a78bfa;
  --color-type-icon-blue: #a78bfa;
  --color-syntax-keywords: #c4b5fd;
  --color-syntax-param-internal-name: #a78bfa;
}

/* Nav glass morphism */
.nav, .nav--is-sticking {
  background-color: rgba(7, 5, 15, 0.85) !important;
  backdrop-filter: blur(20px) saturate(180%) !important;
  -webkit-backdrop-filter: blur(20px) saturate(180%) !important;
  border-bottom: 1px solid rgba(139, 108, 224, 0.15) !important;
}

/* Code blocks */
pre {
  background-color: #1a1035 !important;
  border: 1px solid rgba(139, 108, 224, 0.15) !important;
  border-radius: 8px !important;
}

/* Top banner */
.spook-banner {
  position: fixed;
  top: 0;
  left: 0;
  right: 0;
  z-index: 10000;
  background: rgba(7, 5, 15, 0.92);
  backdrop-filter: blur(20px) saturate(180%);
  -webkit-backdrop-filter: blur(20px) saturate(180%);
  border-bottom: 1px solid rgba(139, 108, 224, 0.15);
  padding: 8px 20px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
  font-size: 13px;
}

.spook-banner a {
  color: #8b7faa;
  text-decoration: none;
  padding: 4px 10px;
  border-radius: 4px;
  transition: color 0.2s;
}
.spook-banner a:hover { color: #f0eaff; }

.spook-banner-logo {
  display: flex;
  align-items: center;
  gap: 6px;
  color: #f0eaff !important;
  font-weight: 700;
  font-size: 14px;
}

.spook-banner-links {
  display: flex;
  align-items: center;
  gap: 2px;
}

.spook-banner-cta {
  background: linear-gradient(135deg, #a78bfa, #7c3aed);
  color: #fff !important;
  padding: 5px 14px !important;
  border-radius: 6px;
  font-weight: 600;
  font-size: 12px;
  margin-left: 8px;
}
.spook-banner-cta:hover { opacity: 0.9; }

/* Push DocC content down */
.nav { top: 36px !important; }
#app { padding-top: 36px; }

/* Footer */
.spook-footer {
  border-top: 1px solid rgba(139, 108, 224, 0.15);
  padding: 24px 20px;
  text-align: center;
  font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
  font-size: 12px;
  color: #8b7faa;
  background: #07050f;
}
.spook-footer a { color: #a78bfa; text-decoration: none; }
.spook-footer a:hover { text-decoration: underline; }

@media (max-width: 768px) {
  .spook-banner-links { display: none; }
}
CSSEOF

# 2. Create custom JS (using safe DOM methods, no innerHTML)
cat > "$DOCS_DIR/custom-spooktacular.js" << 'JSEOF'
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
JSEOF

# 3. Inject CSS and JS into index.html
INDEX="$DOCS_DIR/index.html"

if ! grep -q "custom-spooktacular.css" "$INDEX"; then
    sed -i '' 's|</head>|<link rel="stylesheet" href="/api/custom-spooktacular.css"></head>|' "$INDEX"
fi

if ! grep -q "custom-spooktacular.js" "$INDEX"; then
    sed -i '' 's|</body>|<script src="/api/custom-spooktacular.js"></script></body>|' "$INDEX"
fi

# 4. Update page title
sed -i '' 's|<title>Documentation</title>|<title>Spooktacular API Reference</title>|' "$INDEX"

echo "✓ DocC customized with Spooktacular branding"
