# Changelog

## 0.2.0 (2026-10-20)

- README: the callback checks come first; unrolled callbacks are experimental (no faster in production, ~20 MB more per worker). No code changes.

## 0.1.2 (2026-10-18)

- Rails main: the controller terminator (now `AbstractController::Callbacks::TERMINATOR`, a lambda in 8.1) is recognized again, so a before_action is a plain call followed by `performed?` instead of a lambda passed to the terminator: one block less per callback to compile, one allocation less per call.
- The part of a chain an around callback wraps is a method of its own, which the around gets as a one-line block, instead of a proc holding the rest of the chain: no callbacks in blocks nested in blocks, and no proc allocated per around per run.

## 0.1.1 (2026-10-18)

- Unrolled callbacks: one method per class and chain instead of one per controller action (`only:`/`except:` become a Set lookup), and classes whose chains are the same share one method body. Fewer methods for the JIT to compile.
- `Check.long_chains`: chains with more than a limit (default 5) of the app's own callbacks. Callbacks inherited from excluded classes (default `ApplicationController`) don't count; a base class over the limit is reported once, with the classes that inherit it.
- `Check.callback_loops`: model callbacks that call `save`, `update`, `touch`, ... on their own record, which runs the callbacks again (found with Prism), with the guard if there is one.
- Census counts per class, not per action.

## 0.1.0 (2026-10-18)

First release.

- ActiveSupport::Callbacks chains run as one generated method per class and chain (per action for controllers).
- `source_dir` writes the generated methods out, so backtraces point at real files.
- Census and check of callbacks naming methods that don't exist.
