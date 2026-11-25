require "./spec_helper"

module QueueSpec
  class_getter log = [] of String

  # Runs the block with an in-memory queue and a worker to drain it.
  def self.with_memory_queue(&)
    previous = Silth::Queue.driver
    driver = Silth::Queue::MemoryDriver.new
    Silth::Queue.driver = driver
    log.clear
    begin
      yield Silth::Queue::Worker.new(["default", "mail"], 1, driver: driver), driver
    ensure
      Silth::Queue.driver = previous
    end
  end

  def self.with_config(yaml : String, &)
    previous = Silth.config
    Silth.config = Silth::Config.new(YAML.parse(yaml))
    begin
      yield
    ensure
      Silth.config = previous
    end
  end
end

class ImportRowJob < Silth::Job
  retries 1
  getter row : Int32

  def initialize(@row : Int32)
  end

  def perform : Nil
    raise "bad row #{row}" if row < 0
    QueueSpec.log << "row #{row}"
  end
end

class ImportReportJob < Silth::Job
  getter label : String

  def initialize(@label : String)
  end

  def perform : Nil
    QueueSpec.log << "#{label} #{batch.try(&.progress)}%"
  end
end

class StockJob < Silth::Job
  unique for: 1.minute
  getter sku : String

  def initialize(@sku : String)
  end

  def perform : Nil
    QueueSpec.log << "stock #{sku}"
  end
end

class ThrottledJob < Silth::Job
  rate_limit 2, per: 1.minute
  getter n : Int32

  def initialize(@n : Int32)
  end

  def perform : Nil
    QueueSpec.log << "throttled #{n}"
  end
end

class MailRateJob < Silth::Job
  queue mail
  getter n : Int32

  def initialize(@n : Int32)
  end

  def perform : Nil
    QueueSpec.log << "mail #{n}"
  end
end

# The batch table is created once, outside the per-example transactions.
Silth::Batch::DatabaseStore.new.ensure_table

describe "unique jobs" do
  it "skips duplicates until the first one has run" do
    QueueSpec.with_memory_queue do |worker|
      StockJob.new("a").dispatch.should_not be_nil
      StockJob.new("a").dispatch.should be_nil
      StockJob.new("b").dispatch.should_not be_nil
      worker.drain
      QueueSpec.log.should eq(["stock a", "stock b"])
      StockJob.new("a").dispatch.should_not be_nil
    end
  end
end

describe "rate-limited jobs" do
  it "puts extra jobs back without using their retries" do
    QueueSpec.with_memory_queue do |worker, driver|
      3.times { |i| ThrottledJob.new(i).dispatch }
      worker.drain
      QueueSpec.log.should eq(["throttled 0", "throttled 1"])
      driver.size("default").should eq(1)
      driver.pop(["default"]).should be_nil # back for the next window
    end
  end

  it "limits a whole queue from config/queue.yml" do
    QueueSpec.with_config("queue:\n  rate_limits:\n    mail: 1/1m") do
      QueueSpec.with_memory_queue do |worker|
        MailRateJob.new(1).dispatch
        MailRateJob.new(2).dispatch
        worker.drain
        QueueSpec.log.should eq(["mail 1"])
      end
    end
    QueueSpec.with_config("queue:\n  rate_limits:\n    mail: lots") do
      expect_raises(Silth::ConfigError, /Invalid rate limit 'lots'/) { Silth::Queue.rate_limit("mail") }
    end
  end
end

describe Silth::Batch do
  it "runs the success and complete callbacks once every job succeeded" do
    QueueSpec.with_memory_queue do |worker|
      batch = Silth::Batch.dispatch([ImportRowJob.new(1), ImportRowJob.new(2)], name: "import",
        on_success: ImportReportJob.new("success"), on_failure: ImportReportJob.new("failure"),
        on_complete: ImportReportJob.new("complete"))
      Silth::Batch.find(batch.id).not_nil!.progress.should eq(0)
      worker.drain
      QueueSpec.log.should eq(["row 1", "row 2", "success 100%", "complete 100%"])
      done = Silth::Batch.find(batch.id).not_nil!
      done.finished?.should be_true
      done.failed?.should be_false
    end
  end

  it "cancels the rest of the batch on the first failure" do
    QueueSpec.with_memory_queue do |worker|
      batch = Silth::Batch.dispatch([ImportRowJob.new(-1), ImportRowJob.new(2)],
        on_success: ImportReportJob.new("success"), on_failure: ImportReportJob.new("failure"),
        on_complete: ImportReportJob.new("complete"))
      worker.drain
      QueueSpec.log.should eq(["failure 100%", "complete 100%"]) # row 2 was skipped, callbacks run last
      failed = Silth::Batch.find(batch.id).not_nil!
      {failed.cancelled?, failed.failed_jobs, failed.finished?}.should eq({true, 1, true})
    end
  end

  it "keeps going with allow_failures" do
    QueueSpec.with_memory_queue do |worker|
      Silth::Batch.dispatch([ImportRowJob.new(-1), ImportRowJob.new(2)], allow_failures: true,
        on_success: ImportReportJob.new("success"), on_complete: ImportReportJob.new("complete"))
      worker.drain
      QueueSpec.log.should eq(["row 2", "complete 100%"])
    end
  end

  it "finishes right away without jobs" do
    QueueSpec.with_memory_queue do |worker|
      batch = Silth::Batch.dispatch([] of Silth::Job, on_complete: ImportReportJob.new("complete"))
      worker.drain
      QueueSpec.log.should eq(["complete 100%"])
      Silth::Batch.find(batch.id).not_nil!.finished?.should be_true
    end
  end
end
