# rails-minify

Fewer generated Active Record methods, ZJIT turned on after boot, and checks
for callback problems, for Rails apps. One repository, one folder per gem:

| gem | what it does |
|---|---|
| [rails-minify](rails-minify) | One switch for strict mode, enums and ZJIT after boot; `minify:check` for callback problems. Experimental patches for parts of Rails and common gems that redo work on every request. Start here. |
| [activerecord-minimizer](activerecord-minimizer) | Only readers and writers per column (strict mode removes the other 19 attribute methods), enum methods without closures. Experimental: call sites compiled to what the removed methods stood for, smaller records. |
| [activesupport-minimizer](activesupport-minimizer) | Callback checks: missing targets, long chains, callbacks that save their own record. Experimental: callback chains as one generated method per chain. |
| [actionpack-minimizer](actionpack-minimizer) | Optional and experimental: route helpers as string interpolation; `render` and `link_to` in templates without their option-hash machinery. |
| [rubocop-minify](rubocop-minify) | RuboCop cop and ERB fixer that rewrite calls to the methods strict mode removes. |

Most of what's here was built as per-call speedups. In production they made
no measurable difference, so they're experimental now and off by default;
[rails-minify's README](rails-minify#what-paid-off-in-production) has the
numbers.

```ruby
# Gemfile
gem "rails-minify"
gem "rubocop-minify", require: false, group: :development

# config/environments/production.rb
config.rails_minify.enabled = true
```

Ruby 3.4+, Rails 8.0, 8.1 and main. MIT licensed.

## Development

Each folder is its own gem with its own Gemfile and tests:

```sh
cd activerecord-minimizer && bundle install && bundle exec rake test
```
