# Changelog

## 0.2.0 (unreleased)

Narrowed to what held up in production (Japan Voyage, each part on half the workers under the same traffic; README, "What paid off in production").

- `config.rails_minify.enabled` turns on only strict mode (`ar_minimizer.slim`), enums and ZJIT after boot. ZJIT only in production and from Ruby 4.1 (4.0's ZJIT isn't meant for production); set `config.rails_minify.zjit` yourself otherwise.
- No longer turned on by `enabled`: `ar_minimizer.views`, `.load_time`, `.small_records`, `as_minimizer.unroll_callbacks`, `ap_minimizer.route_helpers`, `.views`, and the patches. Each still works when set on its own and is documented as experimental. Patches: `config.rails_minify.patches = true` for all, or a list.
- actionpack-minimizer is no longer a dependency; rails-minify loads it, and `minify:census` covers it, when it's in the Gemfile.
- Requires activerecord-minimizer and activesupport-minimizer 0.2.

## 0.1.3 (2026-10-18)

- `config.rails_minify.zjit = true` turns ZJIT on after boot, as `config.yjit` does for YJIT, instead of `RUBY_ZJIT_ENABLE=1` compiling boot-only code too. Japan Voyage, per process: 24% fewer compiled methods, 18 MB less JIT memory, about 25 MB less RSS, the same speed.

## 0.1.2 (2026-10-18)

- `minify:check` also fails on callback chains longer than `callback_limit` (default 5, `ApplicationController`'s callbacks excluded) and on model callbacks that save their own record again; `callback_limit_mode` and `callback_loops` set either to `:warn`. Works without the rest of rails-minify turned on; the manifest check runs only when there is a manifest.
- Requires activesupport-minimizer 0.1.1.

## 0.1.1 (2026-10-18)

- `:omniauth` isn't installed when OmniAuth already skips requests that can't be the strategy's (a public `Strategy#passthrough?`, as in the version proposed upstream); its own helper no longer shares that name.

## 0.1.0 (2026-10-18)

First release.

- `config.rails_minify.enabled` turns on activerecord-, activesupport- and actionpack-minimizer.
- Patches: `:action_text_plain_text` (cached plain text, including blob attachments), `:request_host` (rails/rails#59104 for Rails 8.0/8.1), `:omniauth` (strategies skip requests that can't be theirs).
- `minify:census` and `minify:check` tasks.
