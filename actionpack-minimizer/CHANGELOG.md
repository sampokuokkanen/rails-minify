# Changelog

## 0.2.0 (unreleased)

- No longer a dependency of rails-minify: an optional gem. README: experimental, and it needs work (generating before a preloading server forks, a production result) before it's worth turning on. No code changes.

## 0.1.0 (2026-10-18)

First release.

- Named route helpers as interpolation over cached URL parts, with Rails' own escaping.
- Templates: `render` of partials and records, and `link_to` (with literal or computed options, and block form), compiled to direct calls.
