# Loads the whole application. Shared by the server (src/server.cr), the CLI
# (src/cli.cr) and the specs.
require "silth"

# Base classes first (subclasses need them defined).
require "./models/application_model"
require "./controllers/application_controller"
require "./controllers/api_controller"

require "./models/**"
require "./requests/**"
require "./policies/**"
require "./events/**"
require "./listeners/**"
require "./jobs/**"
require "./mails/**"
require "./notifications/**"
require "./middleware/**"
require "./components/**"
require "./channels/**"
require "./controllers/**"
require "./commands/**"
require "../config/routes"

Silth.configure do |app|
  # app.middleware.use MyGlobalMiddleware.new
  # app.middleware_groups["web"] << TrackVisits.new
  # app.alias_middleware("admin") { RequireAdmin.new }
end

# Scheduled tasks (run `silth schedule:work` or cron `silth schedule:run`):
# Silth.schedule do |s|
#   s.call("prune-tokens") { Silth::Auth::AccessToken.where(:expires_at, "<", Time.utc).delete_all }.daily_at("03:00")
# end
