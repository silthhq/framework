# Application CLI: `silth <command>` compiles and runs this file.
require "./app"
require "../db/migrations/**"
require "../db/seeders/**"
require "../db/seeds"
require "../db/schema"

exit Silth::CLI.run(ARGV)
