# Changelog

## 0.1.0 (2026-10-18)

First release.

- `config.rails_minify.enabled` turns on activerecord-, activesupport- and actionpack-minimizer.
- Patches: `:action_text_plain_text` (cached plain text, including blob attachments), `:request_host` (rails/rails#59104 for Rails 8.0/8.1), `:omniauth` (strategies skip requests that can't be theirs).
- `minify:census` and `minify:check` tasks.
