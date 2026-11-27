require "./spec_helper"

private def d(text : String) : Silth::Decimal
  Silth::Decimal.new(text)
end

describe Silth::Decimal do
  it "parses and prints, keeping the scale" do
    d("12.50").to_s.should eq("12.50")
    d("-0.05").to_s.should eq("-0.05")
    d(".5").to_s.should eq("0.5")
    d("1e3").to_s.should eq("1000")
    d("1.5E-3").to_s.should eq("0.0015")
    d(" 7 ").to_s.should eq("7")
    Silth::Decimal.new(0.1).to_s.should eq("0.1")
    Silth::Decimal.parse?("abc").should be_nil
    Silth::Decimal.parse?("1.2.3").should be_nil
    expect_raises(Silth::Decimal::InvalidError) { d("12,5") }
  end

  it "adds, subtracts and multiplies exactly, scales adding up" do
    (d("12.50") * 3).to_s.should eq("37.50")
    (d("12.50") + d("1.5")).to_s.should eq("14.00")
    (d("0.1") + d("0.2")).should eq(d("0.3"))
    (d("2.000") * d("12.50")).to_s.should eq("25.00000")
    (2 * d("1.5")).to_s.should eq("3.0")
    (d("7.5") % 2).to_s.should eq("1.5")
    [d("1.10"), d("2.205")].sum.to_s.should eq("3.305")
  end

  it "divides like rust_decimal" do
    (d("1.00") / 2).to_s.should eq("0.50")
    (d("10") / 4).to_s.should eq("2.5")
    (d("1") / 3).to_s.should eq("0.3333333333333333333333333333")
    (d("2") / 3).to_s.should eq("0.6666666666666666666666666667")
    (d("2") / d("0.5")).to_s.should eq("4")
    (d("-1") / 8).to_s.should eq("-0.125")
    expect_raises(DivisionByZeroError) { d("1") / 0 }
  end

  it "rounds half to even by default, never adding digits" do
    d("2.345").round(2).to_s.should eq("2.34")
    d("2.355").round(2).to_s.should eq("2.36")
    d("1.005").round(2, :ties_away).to_s.should eq("1.01")
    d("-2.5").round.to_s.should eq("-2")
    d("-2.5").round(0, :ties_away).to_s.should eq("-3")
    d("1.5").round(2).to_s.should eq("1.5")
    d("12.349").truncate(2).to_s.should eq("12.34")
    d("-5.1").floor.to_s.should eq("-6")
    d("5.1").ceil.to_s.should eq("6")
  end

  it "rescales, normalizes and formats" do
    d("12.5").rescale(2).to_s.should eq("12.50")
    d("3").to_fixed(2).should eq("3.00")
    d("12.345").to_fixed(2).should eq("12.34")
    d("12.500").normalize.to_s.should eq("12.5")
    d("0.000").normalize.to_s.should eq("0")
  end

  it "compares values whatever the scale" do
    d("12.50").should eq(d("12.5"))
    d("12.50").hash.should eq(d("12.5").hash)
    (d("1.01") > d("1.009")).should be_true
    (d("-1") < 0).should be_true
    [d("3"), d("1.5"), d("2")].max.to_s.should eq("3")
  end

  it "converts to JSON strings and reads strings or numbers" do
    {"total" => d("12.50")}.to_json.should eq(%({"total":"12.50"}))
    Array(Silth::Decimal).from_json(%([1.50, "2.30", 3])).map(&.to_s).should eq(["1.50", "2.30", "3"])
    d("12.50").to_f64.should eq(12.5)
    d("-12.9").to_i64.should eq(-12)
    d("12.50").to_big_d.should eq(BigDecimal.new("12.5"))
    Silth::Decimal.new(BigDecimal.new("3.25")).to_s.should eq("3.25")
  end
end

class CreateLedgerSpecTable < Silth::Migration
  version 2026_01_01_000003

  def change
    create_table :ledger_entries do |t|
      t.id
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.decimal :rate, precision: 8, scale: 4
      t.date :due_on
      t.timestamps
    end
  end
end

class LedgerEntry < Silth::Model
  primary_key
  column amount : Decimal
  column rate : Decimal?
  column due_on : Date?
  timestamps
end

describe "Decimal and Date columns" do
  it "round-trips exact decimals and calendar dates" do
    entry = LedgerEntry.create!(amount: Decimal.new("12.50"), rate: Decimal.new("0.2"), due_on: Date.new(2026, 12, 31))
    fresh = LedgerEntry.find(entry.id)
    fresh.amount.should eq(Decimal.new("12.50"))
    fresh.due_on.should eq(Date.new(2026, 12, 31))
    unless Silth::DB.connection.dialect.name == "sqlite" # SQLite stores NUMERIC as REAL
      fresh.amount.to_s.should eq("12.50")
      fresh.rate.not_nil!.to_s.should eq("0.2000")
    end
    json = JSON.parse(fresh.to_json)
    json["due_on"].should eq("2026-12-31")
    json["amount"].as_s.to_f.should eq(12.5)
  end

  it "queries, assigns from strings and sums exactly" do
    LedgerEntry.create!(amount: Decimal.new("0.10"))
    LedgerEntry.create!(amount: Decimal.new("0.20"))
    entry = LedgerEntry.new
    entry.assign({"amount" => "7.05", "due_on" => "2027-01-15"})
    entry.amount.should eq(Decimal.new("7.05"))
    entry.due_on.should eq(Date.new(2027, 1, 15))
    LedgerEntry.where(amount: Decimal.new("0.10")).count.should eq(1)
    sum = LedgerEntry.where("amount < ?", Decimal.new("1")).sum_decimal(:amount)
    sum = sum.round(2) if Silth::DB.connection.dialect.name == "sqlite" # REAL arithmetic
    sum.should eq(Decimal.new("0.30"))
    LedgerEntry.where(due_on: Date.new(1999, 1, 1)).count.should eq(0)
  end
end

describe Silth::Date do
  it "does calendar arithmetic" do
    date = Date.new(2026, 1, 31)
    (date + 1).should eq(Date.new(2026, 2, 1))
    date.shift(months: 1).should eq(Date.new(2026, 2, 28))
    (Date.new(2026, 12, 25) - Date.new(2026, 11, 27)).should eq(28)
    Date.parse("2026-02-10").at_end_of_month.to_s.should eq("2026-02-28")
    Date.parse("2026-11-27T10:00:00Z").should eq(Date.new(2026, 11, 27))
    Date.parse?("2026-02-30").should be_nil
    (Date.new(2026, 11, 27)..Date.new(2026, 11, 29)).to_a.size.should eq(3)
    Date.new(2026, 11, 27).at_beginning_of_week.should eq(Date.new(2026, 11, 23))
    Date.new(2026, 11, 27).to_s("%d/%m/%Y").should eq("27/11/2026")
    Date.from_json(%("2026-11-27")).should eq(Date.new(2026, 11, 27))
  end
end

describe Silth::JSONTime do
  it "writes times with a fixed or automatic precision" do
    time = Time.utc(2026, 11, 27, 10, 0, 0)
    time.to_json.should eq(%("2026-11-27T10:00:00.000Z"))
    Silth::JSONTime.digits = nil
    time.to_json.should eq(%("2026-11-27T10:00:00Z"))
    (time + 250.milliseconds).to_json.should eq(%("2026-11-27T10:00:00.250Z"))
    (time + 123456.microseconds).to_json.should eq(%("2026-11-27T10:00:00.123456Z"))
    Time.local(2026, 11, 27, 11, 0, 0, location: Time::Location.fixed(3600)).to_json.should eq(%("2026-11-27T10:00:00Z"))
  ensure
    Silth::JSONTime.digits = 3
  end
end
