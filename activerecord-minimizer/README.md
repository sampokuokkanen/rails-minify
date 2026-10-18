# activerecord-minimizer

Active Record generates a reader, a writer and one method per attribute
method pattern for every column of every model: `name?`, `name_changed?`,
`name_was`, `saved_change_to_name?`, `name_before_type_cast`,
`restore_name!`, ... 21 patterns in Rails 8.1, so 21 methods per column.
activerecord-minimizer generates the readers and writers only, and compiles
the call sites that used the rest into the calls they stood for. Part of
[rails-minify](../rails-minify).

```ruby
# Gemfile
gem "activerecord-minimizer"

# config/environments/production.rb
config.ar_minimizer.slim = true
```

## Strict mode

With `slim` on, the other 19 methods per column are gone. Calling one raises
`NoMethodError` naming its replacement, and `respond_to?` says no:

```
name_changed? was removed by activerecord-minimizer's strict mode; use attribute_changed?(:name, ...)
```

[rubocop-minify](../rubocop-minify) rewrites those calls in your Ruby and ERB.
Gems that call them by name (Devise's `will_save_change_to_email?`, Active
Storage's `service_name_changed?`, counter caches) get them back from a keep
list, `config/ar_minimizer_keep.txt`, one `name` or `Model#name` per line.
To find what to put there, run the test suite with `strict = false` and
`AR_MINIMIZER_PROFILE=tmp/ar_minimizer`, then `bin/rails ar_minimizer:profile`.

Rails itself still gets what it needs:

* `<attr>_before_type_cast` and `<attr>_came_from_user?` answer `respond_to?`
  and are generated on first call. Form fields and numericality validation ask
  before calling them, and quietly do something else when told no (a form
  would show the cast value, `"abc"` would validate as 0).
* `<enum>_for_database` and `updated_at_before_type_cast`/`_came_from_user?`
  are generated up front: Rails calls them on hot paths.
* Aliases (`alias_attribute`, Rails' own `id_value`), partial selects
  (`select(:id)`) and columns only one query selects (`AS trips_count`) work
  as before.

`config.ar_minimizer.strict = false` keeps the removed methods working: the
first call to one generates it on that model.

## Compiling call sites

Calls whose receiver is known to be a record of a model with that column are
compiled to what the generated method would have done:

```ruby
# what you write                       # what runs
user.name_changed?                     user.attribute_changed?(-"name")
user.active?                           (!!user.active)
user.age?                              ((user.age || 0) != 0)
user.name?                             (!user.name.blank?)
```

`name?` compiles by column type, to what `query_attribute` works out to for
those values; enums, time zone aware datetimes, `encrypts`, `serialize` and
`normalizes` columns keep `query_attribute(:name)`. The receiver's type comes
from the code (Prism) and the manifest: `self` inside a model or a concern it
includes, locals and instance variables assigned from `Model.find`, `.new`,
`.create`, finders and scopes, associations, and block parameters of
relations. A receiver that may be nil gets a nil check instead
(`nil == user ? user.name? : ...`). Calls whose receiver isn't known are left
as written; `config.ar_minimizer.guards = true` compiles them too, behind a
class check.

Where it compiles:

* **Load time** (`config.ar_minimizer.load_time = true`) compiles `app/` and
  `lib/` as Ruby loads them, through require-hooks, so bootsnap caches the
  compiled iseqs. Source files stay untouched and no database is needed.
* **Views** (`config.ar_minimizer.views = true`) compiles each template's Ruby
  as Action View compiles it (any handler: ERB, Herb, ...).
* **Build** (`RAILS_ENV=production bin/rails ar_minimizer:build`) rewrites
  `app/` and `lib/` in place instead, like explode_sqlite. Production only (or
  `FORCE=1`); `DRY_RUN=1` previews.

All three read the **manifest**, `config/ar_minimizer.json`, written by
`bin/rails ar_minimizer:manifest`: per model its columns and their query kind,
the attribute method patterns, hand-written methods, superclass, app modules,
associations, scopes, and names it defines another way (an enum predicate
with the same name as another model's column). Commit it like
`db/schema.rb`; `bin/rails ar_minimizer:manifest:check` fails CI when it's
stale, and an eager-loading boot logs an error if it is.

Never compiled: methods any model defines by hand, names used as columns,
primary key methods, `defined?(...)`, calls with blocks, heredoc arguments.

## More

* **Enums** (`config.ar_minimizer.enums = true`) replaces the closures Rails
  defines for enum predicates and bang methods, which build and intern the
  `<name>_for_database` symbol on every call, with ordinary methods carrying
  the enum's values: `def published? = public_send(:status_for_database) == 1`.
  1.3–1.6× faster predicates; non-finite float values keep Rails' closures.
* **Small records** (`config.ar_minimizer.small_records = true`). A loaded
  record owns two Hashes most records never put anything in, 160 bytes each:
  the association cache and the attribute set's Attribute objects. Both start
  as one shared frozen empty Hash and get their own on the first insert. A
  read-only record goes from 1,480 to 1,160 bytes (23 columns), at the same
  speed. Destroyed and frozen records still raise on writes.
* **Census** (`ArMinimizer::Census`, run by rails-minify's
  `bin/rails minify:census`): how many call sites compile, and why the others
  don't.

## Numbers

Rails 8.1, Ruby 4.0, M-series Mac. `bench/calls.rb`, ns per call:

| call                   | stock | compiled | stock (YJIT) | compiled (YJIT) |
|------------------------|------:|---------:|-------------:|----------------:|
| `name?` (string)       |  1050 |      548 |          565 |             328 |
| `age?` (integer)       |   843 |      380 |          464 |             212 |
| `active?` (boolean)    |   535 |      380 |          283 |             214 |
| `name_changed?`        |   768 |      718 |          405 |             327 |

(Measured with the class guard; calls on known receivers skip it.)

On [Japan Voyage](https://japanvoyage.jp) (191 models, 2009 columns):

* Generated attribute methods at boot: 44,835 → about 4,500. Memory used by
  `define_attribute_methods`: 16.4 → about 6 MB; time 374 → about 225 ms.
* Test suite (4317 runs) in strict mode, after rubocop-minify's rewrites and
  with a 41-line keep list: the same results as the untouched app.

## Requirements and caveats

* Ruby 3.4+, Rails 8.0, 8.1 and main (`rake test:rails`).
* It overrides `define_attribute_method_pattern` and the instance
  `attribute_method?`, both private, and calls nodoc `_has_attribute?`.
* A stale manifest can compile a call to a method added by hand since: keep
  `ar_minimizer:manifest:check` in CI.
* Methods generated lazily (`strict = false`) after a server forks are per
  worker; list hot ones in the keep file to generate them at boot.
* Error highlighting in compiled views can point at the wrong column. Line
  numbers are right.
