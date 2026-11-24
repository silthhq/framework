ENV["SILTH_ENV"] = "test"
require "spec"
require "silth/testing"
require "../src/app"
require "../db/migrations/**"
require "./factories/**"

Silth::Testing.setup # boots the app, migrates the test database, wraps each spec in a transaction
