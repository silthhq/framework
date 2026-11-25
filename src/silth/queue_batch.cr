module Silth
  # A group of jobs followed together, with jobs to run when they are done.
  #
  # ```
  # batch = Silth::Batch.dispatch(rows.map { |r| ImportRowJob.new(r.id) },
  #   name: "Import #{import.id}",
  #   on_success: ImportDoneJob.new(import.id),   # every job succeeded
  #   on_failure: ImportFailedJob.new(import.id), # first failure (the batch is cancelled)
  #   on_complete: CleanupJob.new(import.id))     # all processed, whatever happened
  #
  # Silth::Batch.find(batch.id).try(&.progress) # => 42 (percent)
  # ```
  #
  # Jobs read their batch with `batch` (`batch.try(&.cancelled?)` to stop early).
  # When a job fails for good the batch is cancelled and the remaining jobs are
  # skipped, unless `allow_failures: true`. Callbacks are jobs (not blocks) so any
  # worker can run them; they reach the batch through `batch` too.
  #
  # Batches live in `silth_job_batches` when a database is configured, in memory
  # otherwise (`queue.batches: database|memory`).
  class Batch
    getter id : String
    getter name : String
    getter total_jobs : Int32
    getter pending_jobs : Int32
    getter failed_jobs : Int32
    getter failed_job_ids : Array(String)
    getter allow_failures : Bool
    getter callbacks : Hash(String, {String, String, String})
    getter created_at : Time
    getter cancelled_at : Time?
    getter finished_at : Time?

    def initialize(@id, @name, @total_jobs, @pending_jobs, @failed_jobs, @failed_job_ids, @allow_failures, @callbacks,
                   @created_at, @cancelled_at = nil, @finished_at = nil)
    end

    # Creates the batch and queues its jobs (on *queue*, or each job's own queue).
    def self.dispatch(jobs : Array(Job), name : String = "", on_success : Job? = nil, on_failure : Job? = nil,
                      on_complete : Job? = nil, allow_failures : Bool = false, queue : String? = nil) : Batch
      callbacks = {} of String => {String, String, String}
      {"success" => on_success, "failure" => on_failure, "complete" => on_complete}.each do |event, job|
        job.try { |j| callbacks[event] = {j.class.name, j.to_json, j.class.queue_name} }
      end
      batch = new(Crypto.uuid7, name, jobs.size, jobs.size, 0, [] of String, allow_failures, callbacks, Time.utc)
      store.create(batch)
      jobs.each do |job|
        job.batch_id = batch.id
        job_processed(batch.id, "", false) unless job.dispatch(queue: queue) # a unique duplicate never runs
      end
      job_processed(batch.id, "", false, empty: true) if jobs.empty?
      batch
    end

    def self.find(id : String) : Batch?
      store.find(id)
    end

    def self.cancelled?(id : String) : Bool
      !!find(id).try(&.cancelled?)
    end

    # Records a processed job; runs the callbacks the change triggers.
    def self.job_processed(id : String, job_id : String, failed : Bool, empty : Bool = false) : Nil
      change = store.count_job(id, job_id, failed, empty) || return
      batch = change.batch
      batch.run_callback("failure") if change.first_failure
      if change.finished
        batch.run_callback("success") if batch.failed_jobs == 0 && !batch.cancelled?
        batch.run_callback("complete")
      end
    end

    def processed_jobs : Int32
      @total_jobs - @pending_jobs
    end

    # Percentage of processed jobs.
    def progress : Int32
      @total_jobs.zero? ? 100 : (processed_jobs * 100 // @total_jobs)
    end

    def finished? : Bool
      !@finished_at.nil?
    end

    def cancelled? : Bool
      !@cancelled_at.nil?
    end

    def failed? : Bool
      @failed_jobs > 0
    end

    # Skips the jobs that did not start yet.
    def cancel : Nil
      Batch.store.cancel(@id)
      @cancelled_at = Time.utc
    end

    # :nodoc:
    def run_callback(event : String) : Nil
      name, payload, queue = @callbacks[event]? || return
      job = Job.deserialize(name, payload)
      job.callback_batch_id = @id
      job.dispatch(queue: queue)
    end

    # The result of `Store#count_job`.
    record Change, batch : Batch, finished : Bool, first_failure : Bool

    abstract class Store
      abstract def create(batch : Batch) : Nil
      abstract def find(id : String) : Batch?
      # Atomically counts one processed job (*empty*: none, the batch had no jobs).
      abstract def count_job(id : String, job_id : String, failed : Bool, empty : Bool) : Change?
      abstract def cancel(id : String) : Nil

      # Applies one processed job to *batch*; returns the new batch and what changed.
      protected def apply(batch : Batch, job_id : String, failed : Bool, empty : Bool) : Change
        pending = empty ? batch.pending_jobs : batch.pending_jobs - 1
        failed_ids = failed ? batch.failed_job_ids + [job_id] : batch.failed_job_ids
        first_failure = failed && batch.failed_jobs == 0
        cancelled_at = batch.cancelled_at || (first_failure && !batch.allow_failures ? Time.utc : nil)
        finished = pending <= 0 && batch.finished_at.nil?
        updated = Batch.new(batch.id, batch.name, batch.total_jobs, {pending, 0}.max, failed_ids.size, failed_ids,
          batch.allow_failures, batch.callbacks, batch.created_at, cancelled_at, finished ? Time.utc : batch.finished_at)
        Change.new(updated, finished, first_failure)
      end
    end

    # Single process.
    class MemoryStore < Store
      @batches = {} of String => Batch
      @mutex = Mutex.new

      def create(batch : Batch) : Nil
        @mutex.synchronize { @batches[batch.id] = batch }
      end

      def find(id : String) : Batch?
        @mutex.synchronize { @batches[id]? }
      end

      def count_job(id : String, job_id : String, failed : Bool, empty : Bool) : Change?
        @mutex.synchronize do
          batch = @batches[id]? || return nil
          apply(batch, job_id, failed, empty).tap { |change| @batches[id] = change.batch }
        end
      end

      def cancel(id : String) : Nil
        @mutex.synchronize do
          if b = @batches[id]?
            @batches[id] = Batch.new(b.id, b.name, b.total_jobs, b.pending_jobs, b.failed_jobs, b.failed_job_ids,
              b.allow_failures, b.callbacks, b.created_at, b.cancelled_at || Time.utc, b.finished_at)
          end
        end
      end
    end

    # `silth_job_batches`, updated under a row lock so that a batch finishes once.
    class DatabaseStore < Store
      TABLE = "silth_job_batches"
      @ready = false

      def initialize(@connection : String? = nil)
      end

      def db : DB::Database
        database = DB.connection(@connection)
        ensure_table(database) unless @ready
        database
      end

      # Creates the table when missing (no DDL otherwise: MySQL would commit the
      # caller's transaction).
      def ensure_table(database : DB::Database = DB.connection(@connection)) : Nil
        @ready = true if database.table_exists?(TABLE)
        return if @ready
        DB::Schema.new(database).create_table(TABLE, if_not_exists: true) do |t|
          t.string :id, null: false, limit: 36
          t.string :name, null: false
          t.integer :total_jobs, null: false
          t.integer :pending_jobs, null: false
          t.integer :failed_jobs, null: false, default: 0
          t.text :failed_job_ids, null: false
          t.text :options, null: false
          t.timestamp :created_at, null: false
          t.timestamp :cancelled_at
          t.timestamp :finished_at
          t.primary_key [:id]
        end
        @ready = true
      end

      def create(batch : Batch) : Nil
        db.table(TABLE).insert({
          "id" => batch.id.as(DB::Value), "name" => batch.name.as(DB::Value), "total_jobs" => batch.total_jobs.as(DB::Value),
          "pending_jobs" => batch.pending_jobs.as(DB::Value), "failed_jobs" => 0.as(DB::Value),
          "failed_job_ids" => "[]".as(DB::Value), "options" => options_json(batch).as(DB::Value),
          "created_at" => batch.created_at.as(DB::Value),
        }, returning: nil)
      end

      def find(id : String) : Batch?
        db.table(TABLE).where(id: id).first?.try { |row| from_row(row) }
      end

      def count_job(id : String, job_id : String, failed : Bool, empty : Bool) : Change?
        database = db
        database.transaction do
          row = database.table(TABLE).where(id: id).lock_for_update.first? || return nil
          change = apply(from_row(row), job_id, failed, empty)
          b = change.batch
          database.table(TABLE).where(id: id).update({
            "pending_jobs" => b.pending_jobs.as(DB::Value), "failed_jobs" => b.failed_jobs.as(DB::Value),
            "failed_job_ids" => b.failed_job_ids.to_json.as(DB::Value), "cancelled_at" => b.cancelled_at.as(DB::Value),
            "finished_at" => b.finished_at.as(DB::Value),
          })
          change
        end
      end

      def cancel(id : String) : Nil
        db.table(TABLE).where(id: id).where_null(:cancelled_at).update(cancelled_at: Time.utc)
      end

      private def options_json(batch : Batch) : String
        {allow_failures: batch.allow_failures, callbacks: batch.callbacks}.to_json
      end

      private def from_row(row : DB::Row) : Batch
        options = JSON.parse(row["options"].to_s)
        callbacks = options["callbacks"].as_h.transform_values { |v| {v[0].as_s, v[1].as_s, v[2].as_s} }
        Batch.new(row["id"].to_s, row["name"].to_s, DB.as_i64(row["total_jobs"]).to_i32, DB.as_i64(row["pending_jobs"]).to_i32,
          DB.as_i64(row["failed_jobs"]).to_i32, Array(String).from_json(row["failed_job_ids"].to_s), options["allow_failures"].as_bool,
          callbacks, row["created_at"].as(Time), row["cancelled_at"].as?(Time), row["finished_at"].as?(Time))
      end
    end

    @@store : Store? = nil

    def self.store : Store
      @@store ||= begin
        default = DB.configured? ? "database" : "memory"
        case Silth.config.string("queue.batches", default)
        when "memory" then MemoryStore.new
        else               DatabaseStore.new(Silth.config.string?("queue.connection"))
        end
      end
    end

    def self.store=(@@store : Store?)
    end
  end
end
