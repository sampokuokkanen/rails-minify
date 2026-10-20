# rails-minify

Fewer generated Active Record methods, ZJIT turned on after boot, and checks
for callback problems.

```ruby
# Gemfile
gem "rails-minify"

# config/environments/production.rb
config.rails_minify.enabled = true
```

`enabled` turns on what held up in production on a real app:

* strict mode (`config.ar_minimizer.slim`): only readers and writers per column;
* enum predicates and bang methods as plain methods (`config.ar_minimizer.enums`);
* ZJIT after boot (`config.rails_minify.zjit`), in production on Ruby 4.1+.

Each can still be set on its own (`config.ar_minimizer.enums = false`).
Everything else is [experimental](#experimental) and off unless you set it.
Ruby 3.4+, Rails 8.0, 8.1 and main.

Turn it on in tests too, so a call to a method strict mode removed fails in CI
rather than in production. In development, strict mode alone is enough: the
same errors show up while you work.

```ruby
# config/environments/test.rb
config.rails_minify.enabled = true

# config/environments/development.rb
config.ar_minimizer.slim = true # strict mode, without the rest
```

## Strict mode

Active Record defines, for every column, a reader, a writer and 19 more
methods (`name?`, `name_changed?`, `saved_change_to_name?`, ...). With
rails-minify they're gone: only readers and writers are generated, which
on a 191-model app is 42,210 → ~4,500 methods, ~10 MB less memory and ~150
ms less boot. Calling a removed method raises NoMethodError naming its
replacement:

```
name_changed? was removed by activerecord-minimizer's strict mode; use attribute_changed?(:name, ...)
```

rubocop-minify rewrites those calls in your code. For calls in gems
(Devise's `will_save_change_to_email?`, ...), list them in
`config/ar_minimizer_keep.txt`; `bin/rails ar_minimizer:profile` finds them.
`config.ar_minimizer.strict = false` keeps the removed methods working
instead, generated the first time each is called.

## ZJIT after boot

```ruby
config.rails_minify.zjit = true # instead of RUBY_ZJIT_ENABLE=1 / --zjit
```

`enabled` sets it in production on Ruby 4.1 and later; on 4.0, ZJIT isn't
meant for production yet, so set it yourself if you want it there. ZJIT
options still go in `RUBYOPT`, after `--zjit-disable` so they don't turn it
on at startup: `RUBYOPT="--zjit-disable --zjit-call-threshold=2"`.

`RUBY_ZJIT_ENABLE=1` turns ZJIT on before anything loads, so it also compiles
what runs only while booting: RubyGems, requiring and eager loading, and the
minimizers' own compiling. Rails turns YJIT on after boot (`config.yjit`) for
this reason, but has no such setting for ZJIT; this is that one. It works on
its own, without the rest of rails-minify.

On Japan Voyage, per process after the same 132 pages: 12,612 → 9,557
compiled methods, JIT code 45.9 → 35.3 MB, ZJIT memory 82.9 → 64.6 MB,
RSS about 25 MB less, the same CPU time per page.

## Checks

* `bin/rails minify:check` (for CI; works whether or not the rest of
  rails-minify is on) fails on:
  * callbacks naming methods that don't exist;
  * callback chains with more than `callback_limit` (default 5) of the app's
    own callbacks (Rails' and gems' don't count; controllers per action).
    Callbacks inherited from `callback_limit_exclude` (default
    `["ApplicationController"]`: time zone, locale, current user, the
    per-request basics) don't count either. A base class over the limit is
    reported once, with the classes that inherit it;
  * model callbacks that call `save`, `update`, `touch`, ... on the record
    they run for, which runs the chain again;
  * an out-of-date manifest, when there is one (only the experimental
    compiling parts use it).

  ```ruby
  config.rails_minify.callback_limit = 8
  config.rails_minify.callback_limit_exclude = ["ApplicationController", "Admin::BaseController"] # [] counts everything
  config.rails_minify.callback_limit_mode = :warn # report, don't fail
  config.rails_minify.callback_loops = :warn
  config.rails_minify.allow_callback_loops = ["Trip#recalculate"] # guarded on purpose
  ```

## What paid off in production

Each gem's README has benchmark numbers. In production, on
[Japan Voyage](https://japanvoyage.jp) (Falcon, 6 workers, ZJIT, SQLite),
each part ran for an hour on half the workers while the other half ran
without it, under the same traffic (about 5,000 requests per half):

| part | in production | in 0.2.0 |
|---|---|---|
| ZJIT after boot | HTML p50/p90/p99 75/131/231 → 70/126/208 ms, ~25 MB less per worker (an hour before against an hour after) | on with `enabled` (production, Ruby 4.1+) |
| enums | the same medians; that hour's lower mean and p99 came from a few slow requests, as it changes no allocations on these pages | on with `enabled`: harmless, no measured gain |
| strict | the same latency and memory; no calls to a removed method | on with `enabled`, so production runs what the tests run |
| small records | no difference (tens of records per request) | experimental |
| route helpers | no difference in view time | experimental |
| views (`render`/`link_to`) | no difference in view time | experimental |
| compiled call sites in views | ~22 MB more per worker, no faster | experimental |
| compiled call sites at load time | ~12% more CPU per request (not reproduced locally) | experimental |
| callbacks | no faster, ~20 MB more per worker | experimental |
| patches | no difference (view time 25.3 vs 26.8 ms) | experimental |

ZJIT after boot is the one part with a clear effect. What `enabled` turns on
is what Japan Voyage runs.

What the benchmarks speed up is per call: a method call, a Hash, a helper.
A page there spends ~30 ms in Active Record and ~30 ms in views, and those
savings were smaller than the difference between two halves of the same
workers. Parts that generate or compile code in each worker (callbacks,
compiled views) cost memory in every worker; most of these ran before the
app was preloaded, and would cost less with preloading.

Besides ZJIT after boot, what sped Japan Voyage up was outside this gem: a
preloading server warming the heap up before it forks, and one query fixed.
Together, HTML p50/p90/p99 went from 75/131/231 to 45/66/~105 ms.

## Experimental

Each was faster in benchmarks and made no measurable difference in
production (above). They still work, each turned on by its own setting:

| part | setting | gem |
|---|---|---|
| small records: no Hashes for records that never fill them (-22% per record) | `config.ar_minimizer.small_records` | activerecord-minimizer |
| call sites compiled to what removed methods stood for | `config.ar_minimizer.views`, `.load_time` | activerecord-minimizer |
| callback chains as generated methods (`valid?` -33..45%) | `config.as_minimizer.unroll_callbacks` | activesupport-minimizer |
| route helpers as interpolation (3-14x) | `config.ap_minimizer.route_helpers` | actionpack-minimizer |
| `render`/`link_to` without their machinery (2x per page of partials) | `config.ap_minimizer.views` | actionpack-minimizer |
| patches | `config.rails_minify.patches` | rails-minify |

actionpack-minimizer is no longer a dependency: add `gem "actionpack-minimizer"`
to use it. `bin/rails minify:census` shows how much of the app the compiling
parts cover, and why the rest isn't (actionpack-minimizer's part when it's
installed).

### Patches

For parts of Rails and common gems that redo work on every request. Off
unless `config.rails_minify.patches` is set: `true` for all of them, or a
list (`[:omniauth]`). In production they made no difference in view time;
each is on its way upstream.

* `:action_text_plain_text`: `ActionText::Content#to_plain_text` parses the
  HTML with Nokogiri, and looks up every attachment's record, on every call.
  It's computed once per distinct HTML (cache capped at 8 MB of HTML).
  Attachments that are Active Storage blobs, remote images or inline content
  are cached too: a blob without a caption contributes its filename, which a
  hit checks in one query (renamed or deleted: computed again). Other
  attachables aren't cached. In [Japan Voyage](https://japanvoyage.jp), 13% of all allocations on its
  pages came from it, and guides with images another 4.5%.
* `:request_host`: `ActionDispatch::Request#host` runs a regexp substitution
  on every call, port or not, and Rails reads it several times per request.
  rails/rails#59104 (Rails 8.2) for 8.1: no substitution without a port, and
  the host kept while the raw host is the same String. Not installed on 8.2.
* `:omniauth`: every OmniAuth strategy middleware dups itself and its
  options on every request before looking at the path. Requests that can't
  be OmniAuth's go straight to the app. Only when that's certain up front:
  a session is present, not in test mode, no `other_phase` or callable
  paths, and the strategy doesn't override how paths are matched. Not
  installed when OmniAuth already does this itself (it then has a public
  `Strategy#passthrough?`, as in the version proposed upstream).

### Allocations

Japan Voyage, 132 production pages, with everything on (strict mode after
rubocop-minify's rewrites, all patches): identical HTML, and
1,561,283 → 1,224,141 allocations per pass (−21.6%). The machine was too
loaded for wall-clock times to mean much.

## Things found that are app config

* sentry-rails' `breadcrumbs_logger = [:active_support_logger]` subscribes to
  every notification (each SQL query, render, instantiation) and takes
  `Time.now` twice per event, Sentry enabled or not. `:monotonic_active_support_logger`
  avoids the clock calls; dropping it avoids the rest.
