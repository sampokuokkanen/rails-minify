# actionpack-minimizer

Precompiles named route helpers and the common view helpers. Part of
[rails-minify](../rails-minify); controller callbacks are in
activesupport-minimizer.

```ruby
# config/environments/production.rb
config.ap_minimizer.route_helpers = true
config.ap_minimizer.views = true
```

## Route helpers

Rails builds every URL from scratch. Its "optimized" path still merges
hashes and runs the Journey formatter; with `default_url_options` set (most
apps with a locale in their URLs), every helper takes the full `url_for`
path with recall, defaults and route matching. Here the original helper
runs once with placeholder arguments, and what surrounds the placeholders is
reused:

```ruby
trip_url("Zq9ArmSentinel0Zq9")  # => "https://example.com/ja/trips/Zq9ArmSentinel0Zq9"
# later calls:
"https://example.com/ja/trips/#{escape_segment(trip.to_param)}"
```

The cache key is everything else that goes into the URL: url_options except
the request's path parameters (host, script name, default_url_options such
as the locale), whether Rails would optimize, the helper and argument count
(which decide the segment each argument fills), and the request's path
parameters only for route parts nothing else provides (usually none; Rails
fills those from the request). Arguments are escaped with Rails' own
`escape_segment` (skipped for ids and slugs with nothing to escape).

Options hashes, nil or empty `to_param`, more than four arguments, glob
routes, constrained segments filled by arguments, and arguments that would
land in the query string or anchor use the original helper.

## Views

Each template's compiled Ruby is rewritten when ActionView compiles it:

```ruby
render "comments/comment", comment: c      # -> __ap_render_partial(...)
render partial: "comments/comment", locals: { comment: c }
link_to post.title, post_path(post)        # -> __ap_link_to(...)
link_to "Edit", edit_path, class: "btn"    # -> __ap_link_to_attrs(..., " class=\"btn\"")
link_to trip_path(trip), class: "card" do  # -> __ap_link_to_block(..., " class=\"card\"", 3) do
render @comment                            # -> __ap_render_object(@comment)
```

`render @comment` (and `render @comment, extra: 1`) works out the partial
path and local name with Rails' own ObjectRenderer once per
`to_partial_path` and controller prefix (so namespaced controllers still get
`admin/comments/_comment`), then does what ObjectRenderer does after that.
Collections (`render @comments`) and components (`render_in`) are told
apart at runtime and keep Rails' render: the collection renderer is already
the faster one, instrumenting once per collection.

For `link_to` with html options, Rails' `tag_options` renders each pair on
its own and concatenates them, so literal pairs (strings, symbols, numbers,
booleans, nil, arrays and `data:`/`aria:` hashes of those) are rendered once,
by `tag_options`, when the template compiles, and computed values per call
(plain Strings and Symbols inline with Rails' escaping, anything else through
`tag_options` for that one pair); `href` goes after them, as `link_to` puts
it. Option values are evaluated once, in order. Computed keys, `**splats`,
`method:`, `remote:` and `href:` keep `link_to`. Block-form `link_to` keeps its block
(and the rewrites inside it) and renders it with `capture`, as `content_tag`
does. Name and url are evaluated once each, in order; a url that isn't a
String goes to `link_to` with the original options.

A template whose rewrite doesn't parse is left as written; the census lists it.

`__ap_render_partial` caches the template per path, local names and lookup
details, then does what PartialRenderer does after its lookup (the
`render_partial.action_view` event with the same payload, `template.render`),
without the renderer object and option hashes. `__ap_link_to` builds the `<a>`
with link_to's escaping when the URL is a String, and calls `link_to`
otherwise. Partials named without a directory are looked up under the
controller's prefixes, which are part of the cache key. Collections, `as:`/`object:`, blocks and views overriding
`render`/`link_to`/`url_for`/`content_tag` keep the stock path.

## Numbers

Ruby 4.0, Rails 8.1.

Without `default_url_options` (Rails' optimized path), YJIT:

| route helper            | stock   | compiled |
|-------------------------|--------:|---------:|
| `root_path`             | 767 ns  | 167 ns   |
| `post_path(post)`       | 1532 ns | 494 ns   |
| `post_url(post)`        | 2971 ns | 495 ns   |

With `default_url_options` returning the locale and a `scope "(:locale)"`
(Rails' full path), YJIT:

| route helper            | stock   | compiled |
|-------------------------|--------:|---------:|
| `trip_path(1)`          | 7979 ns | 582 ns   |
| `trips_path`            | 5547 ns | 167 ns   |

Each helper is a small body calling one shared method. A version with
specialized branches per helper was 40% faster per call, but with [Japan Voyage](https://japanvoyage.jp)'s
~1,100 helpers it cost 19 MB and made whole pages 3% slower under YJIT
(more code to compile and keep in cache), so it's gone.

In Japan Voyage's controller and integration tests, 34,646 of 34,873 helper
calls (99.3%) took the compiled path.

A page rendering 50 partials with two `link_to` each (`bench/views.rb`):
830 → 385 µs per page, 423 → 218 µs with YJIT.

`link_to` with literal html options (`bench/links.rb`, 50 per page): 7.6 → 2.0 µs
per link, 4.4 → 1.1 µs with YJIT. With a computed class: 7.3 → 2.5 µs,
4.3 → 1.5 µs. Block form with options: 9.3 → 3.4 µs, 5.4 → 1.8 µs with YJIT.

Single-record `render @comment`: 4.9 → 2.6 µs, 10.3 → 5.0 µs without YJIT.

Japan Voyage: 999 of 1,080 `render`/`link_to` call sites compile (233 partial
renders, 149 record renders, of which collections and components take Rails'
path at runtime, 375 `link_to`, 242 block-form `link_to`: all of them).

Japan Voyage's test suite (4317 runs) gives the same results with both on.

Note: with eager loading, Rails frees each route's AST once routes are
finalized, so `Route#glob?` raises afterwards; glob status is recorded when
helpers are defined.
