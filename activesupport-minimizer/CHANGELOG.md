# Changelog

## 0.1.0 (2026-10-18)

First release.

- ActiveSupport::Callbacks chains run as one generated method per class and chain (per action for controllers).
- `source_dir` writes the generated methods out, so backtraces point at real files.
- Census and check of callbacks naming methods that don't exist.
