# activesupport-minimizer

Finds callback problems Rails only reports when the chain runs, and,
experimentally, runs `ActiveSupport::Callbacks` chains as generated methods.
Part of [rails-minify](../rails-minify), whose `bin/rails minify:check` runs
the checks in CI.

## Checks

`AsMinimizer::Check`, for any class using `define_callbacks` (controllers,
models, validations, Active Job):

* `callback_targets`: callbacks naming a method that doesn't exist. Rails
  registers callbacks by name and finds out when the chain runs: for a
  controller, a 500 on every action the filter covers.
* `long_chains(limit: 5)`: chains with more than `limit` of the app's own
  callbacks (Rails' and gems' don't count; controllers per action).
  Callbacks inherited from `exclude` (default `ApplicationController`) don't
  count either; a base class over the limit is reported once, with the
  classes that inherit it.
* `callback_loops`: model callbacks that call `save`, `update`, `touch`, ...
  on the record they run for, which runs the chain again (found with Prism),
  with the guard if there is one.

## Experimental: unrolled callbacks

Off unless set. Faster per call in benchmarks; in production it made pages no
faster and cost ~20 MB per worker, because each worker generates the methods
as chains first run (see [Numbers](#numbers)).

```ruby
# config/environments/production.rb
config.as_minimizer.unroll_callbacks = true
config.as_minimizer.source_dir = "tmp/rails_minify/callbacks" # optional: write the generated methods out
```

The first time a chain runs for a class (for controllers: per action), it
becomes one method:

```ruby
before_save :normalize
before_save :check, if: :published?

# Post#save
halted = false
value = nil
if !halted
  halted = true
  catch(:abort) do
    self.normalize
    halted = false
  end
  halted_callback_hook(:normalize, :save) if halted
end
if !halted && self.published?
  ...
end
value = !halted && (block_given? ? yield : true)
...
```

It follows `run_callbacks`: before callbacks in order with the chain's
terminator after each (`throw :abort`, `performed?` for controllers, or any
custom one), around callbacks nesting the rest of the chain (passed as a
Proc, like ActiveSupport does), after callbacks last-defined first, skipped
after a halt when the chain says so. Symbols, procs of any arity, objects
(`before_save(record)`, `validate(record)`, `around(controller)`) and
`Conditionals::Value` work as filters and conditions. For controllers,
`only:`/`except:` are decided per action, so other actions' filters are gone;
with `raise_on_missing_callback_actions` on they are checked at runtime
instead, as Rails does. A chain that changes gets a new method.

### Debugging

Backtraces name the chain and the line in it:

```
app/models/user.rb:140:in 'User#generate_username'
unrolled: User#validation:32:in 'block in User#__as_validation'
unrolled: User#validation:31:in 'Kernel#catch'
```

where stock Rails shows `CallTemplate::MethodCall#make_lambda`,
`Filters::Before#call`, `DefaultTerminator#call`... With `source_dir`, those
frames point at a real file (`tmp/rails_minify/callbacks/User/validation.rb`),
so you can open the exact code that ran. `AsMinimizer::Unroller.source_for(User, :save)`
prints it too.

## Numbers

Ruby 4.0, Rails 8.1, µs per call (`bench/models.rb`, a model with 2
validations, 2 before_save, 2 after_save, after_initialize):

|                          | stock | unrolled | stock (YJIT) | unrolled (YJIT) |
|--------------------------|------:|---------:|-------------:|----------------:|
| `valid?`                 |  13.9 |      9.2 |          5.8 |             3.2 |
| `Post.new`               |   7.0 |      6.4 |          2.8 |             2.4 |
| `create!` (SQLite memory)|   182 |      174 |           70 |              65 |

A controller action behind 9 callbacks: 12.6 µs of callback overhead → 4.0 µs
(6.4 → 2.3 µs with YJIT).

[Japan Voyage](https://japanvoyage.jp)'s test suite (4317 runs) gives the same results with it on.

In production there (Falcon, 6 workers, half of them unrolling, the same
traffic for an hour, October 2026): no faster, ~20 MB more per worker. That
was before the app was preloaded; generating the methods at boot, before the
fork, for the loaded classes would be the next thing to try, and then mostly
for memory.
