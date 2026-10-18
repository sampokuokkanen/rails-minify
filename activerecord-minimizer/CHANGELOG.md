# Changelog

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
