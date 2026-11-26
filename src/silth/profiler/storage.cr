module Silth
  module Profiler
    # Keeps the profiles in a SQLite file as well as in memory, so they survive
    # a restart: `silth serve` rebuilds and restarts the app on every change.
    #
    # ```yaml
    # # config/profiler.yml
    # persist: true                        # off by default, on in new apps
    # persist_path: tmp/profiler.sqlite3   # the default
    # ```
    #
    # It writes through its own SQLite connection, outside the app's pools and
    # instrumentation. Rows written by another version of Silth are skipped.
    class Storage
      Log = ::Log.for("silth.profiler")

      # Bumped when the JSON of `Profile` changes.
      FORMAT = 1

      getter path : String

      def initialize(@path : String)
        Dir.mkdir_p(File.dirname(@path))
        @conn = DB::SQLite::Connection.new(DB.parse_url("sqlite3://#{@path}"))
        @mutex = Mutex.new
        @conn.exec_script("CREATE TABLE IF NOT EXISTS silth_profiles (token TEXT PRIMARY KEY, format INTEGER NOT NULL, " \
                          "started_at TEXT NOT NULL, data TEXT NOT NULL)")
      end

      # Saves *profile* and drops all but the newest *keep* ones.
      def save(profile : Profile, keep : Int32) : Nil
        @mutex.synchronize do
          @conn.query("INSERT OR REPLACE INTO silth_profiles (token, format, started_at, data) VALUES (?, ?, ?, ?)",
            [profile.token, FORMAT, profile.started_at.to_rfc3339(fraction_digits: 6), profile.to_json] of DB::Value)
          @conn.query("DELETE FROM silth_profiles WHERE token NOT IN (SELECT token FROM silth_profiles ORDER BY started_at DESC LIMIT ?)",
            [keep] of DB::Value)
        end
      end

      # The newest *keep* profiles, oldest first.
      def load(keep : Int32) : Array(Profile)
        rows = @mutex.synchronize do
          @conn.query("SELECT data FROM silth_profiles WHERE format = ? ORDER BY started_at DESC LIMIT ?", [FORMAT, keep] of DB::Value).rows
        end
        rows.reverse.compact_map do |row|
          Profile.from_json(row[0].to_s)
        rescue ex : JSON::ParseException | JSON::SerializableError
          Log.debug { "Skipped a saved profile: #{ex.message}" }
          nil
        end
      end

      def clear : Nil
        @mutex.synchronize { @conn.exec_script("DELETE FROM silth_profiles") }
      end

      def close : Nil
        @mutex.synchronize { @conn.close }
      end
    end
  end
end
