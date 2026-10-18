# rubocop-minify

RuboCop cops, and an ERB fixer, that rewrite code relying on what
[rails-minify](../rails-minify) removes from Rails. Part of rails-minify.

activerecord-minimizer's strict mode stops generating 19 of the 21 attribute
methods per column (`name?`, `name_changed?`, `saved_change_to_name?`, ...).
`Minify/AttributeMethods` rewrites the calls into what they stood for:

```ruby
venue.featured?                         # => venue.featured.present?
return unless venue.featured?           # => return unless venue.featured
venue.name?                             # => venue.name.present?
venue.rank?                             # => venue.query_attribute(:rank)
venue.name_changed?(to: "x")            # => venue.attribute_changed?(:name, to: "x")
before_save :geocode, if: :address_changed?
                                        # => if: -> { attribute_changed?(:address) }
```

`name?` follows the column's type: a boolean or date column reads as itself
where only truthiness matters (conditions, `!`, `&&`/`||` inside them) and as
`.present?` elsewhere; strings use `.present?`; numbers, enums and decorated
columns use `query_attribute`. Arguments, `&.` and nesting are kept.

## Setup

```ruby
# Gemfile
group :development do
  gem "rubocop-minify", require: false
end
```

```yaml
# .rubocop.yml
plugins:
  - rubocop-minify
```

The cop reads activerecord-minimizer's manifest, `config/ar_minimizer.json`
(`bin/rails ar_minimizer:manifest`): which names strict mode removes, from
which models, for which attribute and column type. Without a manifest it does
nothing.

```sh
bin/rubocop --only Minify/AttributeMethods -a   # Ruby: app, lib, test, db, ...
bundle exec minify-erb --fix app                # templates
```

RuboCop doesn't read ERB, so `minify-erb` does the same rewrite on the Ruby
inside each tag (parsed with Herb). Without `--fix` it lists the calls; it
exits non-zero while any are left, for CI.

Once the calls are rewritten and the rest are in the keep list, both report
nothing: keep the cop in `.rubocop.yml` and `minify-erb app` in CI, and new
code that calls a removed method is caught before it runs.

## What it won't rewrite

Names in activerecord-minimizer's keep list (`config/ar_minimizer_keep.txt`)
are still generated, so their calls are left alone: a bare `name` everywhere,
`Model#name` once every model with that attribute is listed.

Receivers aren't typed, so the cop only rewrites what can't mean something
else, and reports the rest for you to fix by hand or add to the keep list:

* Names the app also defines (`def featured?` in a presenter, `delegate`,
  `attr_reader`, `alias_method`, ...), scanned from `app/` and `lib/`
  (`DefinitionPaths`).
* Names another model defines some other way, such as an enum predicate
  called like another model's column (the manifest's `shadows`).
* Names Ruby or Active Record define everywhere (`key?`, `empty?`,
  `readonly?`), and calls with arguments to methods that take none.
* Calls without a receiver outside a model, or in a module included by
  models of which only some have the column. In templates, `self` is a view,
  so receiver-less calls are never records.
* Private proxies (`name_will_change!` → `attribute_will_change!(:name)`) on
  another object; on `self` they're rewritten.
* Method names passed to `send`, `try` and `delegate`.

## Configuration

```yaml
Minify/AttributeMethods:
  Manifest: config/ar_minimizer.json
  DefinitionPaths:
    - "app/**/*.rb"
    - "lib/**/*.rb"
  KeepList: config/ar_minimizer_keep.txt
```

## On Japan Voyage

191 models: 130 calls in Ruby (app, lib, test, db) and 21 templates rewritten
automatically; 11 names left for the keep list, all of them names some other
class defines too. After that the cop and `minify-erb` report nothing, and
the test suite gives the same results in strict mode.
