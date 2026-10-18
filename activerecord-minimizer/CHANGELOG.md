# Changelog

## 0.1.3 (2026-10-18)

- `ar_minimizer:manifest` stops, saying why, when no model's table exists (a database not set up yet), instead of writing a manifest that describes no models.

## 0.1.2 (2026-10-18)

- Strict mode no longer breaks what gems and Rails call by name, so a keep
  list is only needed for an app's own names:
  - `<attr>_in_database` and `clear_<attr>_change` are generated on first
    call: `increment!`/`decrement!`, and so counter caches, raised before.
  - Devise models keep every attribute method of the columns Devise uses
    (email, encrypted_password, unconfirmed_email and the configured keys).
    Recoverable asks `respond_to?("will_save_change_to_<key>?")` before
    clearing the reset password token, so without these an old reset link
    kept working after a password change.
  - Active Storage blobs and Action Mailbox inbound emails keep the methods
    those frameworks call.

## 0.1.1 (2026-10-18)

- Small records work on Rails main, whose attribute sets take a `default_keys` argument and get a fresh `{}` from Rails; the association cache Rails main leaves `nil` until used is left alone.
- CI also runs the tests on Rails 8.0 and a pinned commit of main.

## 0.1.0 (2026-10-18)

First release.

- Slim: only readers and writers are generated; strict mode (the default) removes the other attribute methods and names the replacement in the NoMethodError. `strict = false` generates them on first call instead.
- Keep list (`config/ar_minimizer_keep.txt`) and profiling (`AR_MINIMIZER_PROFILE`, `ar_minimizer:profile`) for methods gems call by name.
- Manifest (`ar_minimizer:manifest`, `ar_minimizer:manifest:check`).
- Call-site compilation at load time, in templates, or in place (`ar_minimizer:build`), for receivers whose model is known; `guards = true` also compiles the rest behind a class check.
- Enum predicates and bang methods as plain methods.
- Small records: no Hashes for records that never fill them.
