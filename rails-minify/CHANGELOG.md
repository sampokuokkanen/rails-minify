# Changelog

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
