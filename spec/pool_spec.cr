require "./spec_helper"

# A connection that only counts how often it is used.
private class FakeConnection < Silth::DB::Connection
  getter id : Int32
  @closed = false

  def initialize(@id : Int32)
  end

  def query(sql : String, args : Array(Silth::DB::Value)) : Silth::DB::ResultSet
    Silth::DB::ResultSet.new
  end

  def exec_script(sql : String) : Nil
  end

  def close : Nil
    @closed = true
  end

  def closed? : Bool
    @closed
  end

  def dialect : Silth::DB::Dialect
    Silth::DB::Dialect.for("sqlite3")
  end
end

private def fake_pool(size : Int32, timeout : Time::Span = 2.seconds) : Silth::DB::Pool
  ids = 0
  Silth::DB::Pool.new(size, timeout) { FakeConnection.new(ids += 1) }
end

describe Silth::DB::Pool do
  it "opens connections up to its size, then reuses them" do
    pool = fake_pool(2)
    a = pool.checkout
    b = pool.checkout
    pool.total.should eq(2)
    pool.release(a)
    pool.checkout.should be(a)
    pool.release(b)
  end

  it "serves waiting fibers in their order of arrival once they wait too long" do
    pool = fake_pool(1)
    held = pool.checkout
    served = [] of Int32
    done = Channel(Nil).new
    5.times do |i|
      spawn do
        conn = pool.checkout
        served << i
        sleep 1.millisecond # holds it long enough for the others to starve
        pool.release(conn)
        done.send(nil)
      end
      Fiber.yield
    end
    sleep 5.milliseconds
    pool.waiting.should eq(5)
    pool.release(held)
    5.times { done.receive }
    served.should eq([0, 1, 2, 3, 4])
    pool.waiting.should eq(0)
  end

  it "replaces a broken connection for the next waiter" do
    pool = fake_pool(1)
    conn = pool.checkout
    result = Channel(Int32).new
    spawn { result.send(pool.checkout.as(FakeConnection).id) }
    Fiber.yield
    conn.broken = true
    pool.release(conn)
    result.receive.should eq(2)
  end

  it "times out, and leaves the queue" do
    pool = fake_pool(1, 20.milliseconds)
    pool.checkout
    expect_raises(Silth::DB::PoolTimeout) { pool.checkout }
    pool.waiting.should eq(0)
  end
end
