# Changelog

## 0.1.1 (2026-10-18)

- Names activerecord-minimizer's keep list still generates (`config/ar_minimizer_keep.txt`, `KeepList`) are left alone, by the cop and by `minify-erb`: a bare `name` everywhere, `Model#name` once every model with that attribute is listed. With the rewrites done and the rest in the keep list, both report nothing, so they can run as checks.

## 0.1.0 (2026-10-18)

First release.

- `Minify/AttributeMethods`: rewrites calls to the attribute methods strict mode removes, from the app's manifest.
- `minify-erb`: the same rewrite in ERB templates (Herb), with `--fix`.
