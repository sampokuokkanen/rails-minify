# rails-minify

Cuts what Rails (and common gems) build or redo at runtime. One repository,
one folder per gem:

| gem | what it does |
|---|---|
| [rails-minify](rails-minify) | Turns on the three minimizers below and patches parts of Rails and common gems that redo work on every request. Start here. |
| [activerecord-minimizer](activerecord-minimizer) | Only readers and writers per column (strict mode removes the other 19 attribute methods), call sites compiled to what those methods stood for, enum methods without closures, smaller records. |
| [activesupport-minimizer](activesupport-minimizer) | Callback chains (controller filters, model and validation callbacks, Active Job) as one generated method per chain. |
| [actionpack-minimizer](actionpack-minimizer) | Route helpers as string interpolation; `render` and `link_to` in templates without their option-hash machinery. |
| [rubocop-minify](rubocop-minify) | RuboCop cop and ERB fixer that rewrite calls to the methods strict mode removes. |

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
