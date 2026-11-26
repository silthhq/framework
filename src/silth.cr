# Silth — a dark, elegant, batteries-included web framework for Crystal.
#
# ```
# require "silth"
# ```
#
# Everything lives in the `Silth` namespace. See https://silth.dev/docs.

# Standard library only.
require "json"
require "yaml"
require "uuid"
require "log"
require "html"
require "uri"
require "base64"
require "file_utils"
require "mime"
require "http/server"
require "http/client"
require "http/web_socket"
require "digest/sha256"

module Silth
  VERSION = "0.1.0"

  # `MAJOR.MINOR` of `VERSION`: the release line (`0.1`) that documentation and
  # Docker image tags follow.
  def self.release_line : String
    VERSION.split(/[.\-+]/)[0, 2].join('.')
  end
end

# Foundations
require "./silth/support/inflector"
require "./silth/support/dotenv"
require "./silth/support/crypto"
require "./silth/support/fake"
require "./silth/errors"
require "./silth/support/deprecation"
require "./silth/config"
require "./silth/logging"
require "./silth/instrument"
require "./silth/markdown"

# HTTP
require "./silth/http/params"
require "./silth/http/session"
require "./silth/http/context"
require "./silth/router"
require "./silth/middleware"
require "./silth/routes"
require "./silth/view"
require "./silth/view/helpers"
require "./silth/controller"
require "./silth/component"
require "./silth/middleware/core"
require "./silth/middleware/csrf"
require "./silth/middleware/errors"
require "./silth/assets"

# Data
require "./silth/db"
require "./silth/db/dialect"
require "./silth/db/query_builder"
require "./silth/db/drivers/sqlite"
require "./silth/db/drivers/postgres"
require "./silth/db/drivers/mysql"
require "./silth/db/schema"
require "./silth/db/migration"
require "./silth/db/schema_dump"
require "./silth/orm/cast"
require "./silth/orm/model"
require "./silth/orm/query"
require "./silth/validation"

# Application services
require "./silth/i18n"
require "./silth/redis"
require "./silth/cache"
require "./silth/rate_limit"
require "./silth/events"
require "./silth/concurrency"
require "./silth/http_client"
require "./silth/auth"
require "./silth/authorization"
require "./silth/queue"
require "./silth/queue_batch"
require "./silth/scheduler"
require "./silth/mailer"
require "./silth/mail_markdown"
require "./silth/notifications"
require "./silth/storage"
require "./silth/telemetry"
require "./silth/profiler"
require "./silth/pubsub"
require "./silth/unlogged"
require "./silth/realtime"
require "./silth/live"
require "./silth/live_upload"
require "./silth/workflow"
require "./silth/openapi"
require "./silth/billing"

# Kernel & tooling
require "./silth/core"
require "./silth/app"
require "./silth/cli/command"
require "./silth/cli/commands"
require "./silth/deploy"
require "./silth/generators"
require "./silth/generators/app"
