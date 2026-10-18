# Changelog

## 0.1.1 (2026-10-18)

- `:omniauth` isn't installed when OmniAuth already skips requests that can't be the strategy's (a public `Strategy#passthrough?`, as in the version proposed upstream); its own helper no longer shares that name.

## 0.1.0 (2026-10-18)

First release.

- `config.rails_minify.enabled` turns on activerecord-, activesupport- and actionpack-minimizer.
- Patches: `:action_text_plain_text` (cached plain text, including blob attachments), `:request_host` (rails/rails#59104 for Rails 8.0/8.1), `:omniauth` (strategies skip requests that can't be theirs).
- `minify:census` and `minify:check` tasks.
