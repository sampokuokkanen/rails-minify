# frozen_string_literal: true

require "active_record"
require "ar_minimizer/version"
require "ar_minimizer/slim"

# ActiveRecord defines, for every column, a reader, a writer and one method per
# attribute method pattern: name?, name_changed?, name_was, saved_change_to_name?,
# name_before_type_cast, restore_name!, ... (22 patterns in Rails 8.1).
#
# ArMinimizer::Slim stops generating everything except the readers and writers.
# The missing methods still work: ActiveModel's method_missing matches them
# against the same patterns and calls the same proxy (attribute_changed?("name")).
#
# ArMinimizer::Build rewrites static call sites at deploy time so they don't pay
# for method_missing:
#
#   user.name_changed?
#   # becomes
#   (::User.equal?(user.class) ? user.attribute_changed?(-"name") : user.name_changed?)
module ArMinimizer
  autoload :Index, "ar_minimizer/index"
  autoload :Rewriter, "ar_minimizer/rewriter"
  autoload :Build, "ar_minimizer/build"
  autoload :Views, "ar_minimizer/views"
  autoload :Profile, "ar_minimizer/profile"
  autoload :Manifest, "ar_minimizer/manifest"
  autoload :Enums, "ar_minimizer/enums"
  autoload :Census, "ar_minimizer/census"
  autoload :SmallRecords, "ar_minimizer/small_records"
  autoload :Loader, "ar_minimizer/loader"
end

require "ar_minimizer/railtie" if defined?(Rails::Railtie)
