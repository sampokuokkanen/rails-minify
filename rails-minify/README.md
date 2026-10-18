# rails-minify

Cuts what Rails (and common gems) build or redo on every request.

```ruby
# Gemfile
gem "rails-minify"

# config/environments/production.rb
config.rails_minify.enabled = true
```

`enabled` turns on every part below; each can still be set on its own
(`config.ar_minimizer.enums = false`, `config.rails_minify.patches = [:omniauth]`).
Ruby 3.4+, Rails 8.0, 8.1 and main.

Turn it on in tests too, so a call to a method strict mode removed fails in CI
rather than in production. In development, strict mode alone is enough: the
same errors show up while you work, and the compiling parts, which don't
follow code reloads, stay off.

```ruby
# config/environments/test.rb
config.rails_minify.enabled = true

# config/environments/development.rb
config.ar_minimizer.slim = true # strict mode, without the rest
```

## Strict by default

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

## What's in it

| part | does | gem |
|---|---|---|
| attribute methods | readers and writers only (strict) | activerecord-minimizer |
| enums | predicates/bang methods as plain methods (1.3-1.6x) | activerecord-minimizer |
| small records | no Hashes for records that never fill them (-22% per record) | activerecord-minimizer |
| callbacks | chains as generated methods (`valid?` -33..45%) | activesupport-minimizer |
| route helpers | `post_path(post)` as interpolation (3-14x) | actionpack-minimizer |
| views | `render`/`link_to` without their machinery (2x per page of partials) | actionpack-minimizer |
| patches | below | rails-minify |
| rewrites | removed-method calls in Ruby and ERB, as RuboCop autocorrections | rubocop-minify (development) |

## Patches

For parts of Rails and common gems that redo work on every request.
`config.rails_minify.patches = [...]` picks them; all by default.

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

## Numbers

Japan Voyage, 132 production pages, with everything on (strict mode after
rubocop-minify's rewrites, all patches): identical HTML, and
1,561,283 → 1,224,141 allocations per pass (−21.6%). The machine was too
loaded for wall-clock times to mean much.

## Checks

* `bin/rails minify:census`: how much of the app runs compiled, and why the rest doesn't.
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
  * an out-of-date manifest.

  ```ruby
  config.rails_minify.callback_limit = 8
  config.rails_minify.callback_limit_exclude = ["ApplicationController", "Admin::BaseController"] # [] counts everything
  config.rails_minify.callback_limit_mode = :warn # report, don't fail
  config.rails_minify.callback_loops = :warn
  config.rails_minify.allow_callback_loops = ["Trip#recalculate"] # guarded on purpose
  ```

## Things found that are app config, not patches

* sentry-rails' `breadcrumbs_logger = [:active_support_logger]` subscribes to
  every notification (each SQL query, render, instantiation) and takes
  `Time.now` twice per event, Sentry enabled or not. `:monotonic_active_support_logger`
  avoids the clock calls; dropping it avoids the rest.
