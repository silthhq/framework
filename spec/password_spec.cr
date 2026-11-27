require "./spec_helper"

describe Silth::Blake2b do
  it "matches RFC 7693" do
    Silth::Blake2b.digest("abc".to_slice).hexstring.should eq(
      "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
    Silth::Blake2b.digest(Bytes.empty, 32).hexstring.should eq("0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8")
    Silth::Blake2b.new(64).update(Bytes.new(100, 1_u8)).update(Bytes.new(200, 1_u8)).final.should eq(Silth::Blake2b.digest(Bytes.new(300, 1_u8)))
  end
end

describe Silth::Argon2 do
  it "matches the Argon2id vector of RFC 9106" do
    params = Silth::Argon2::Params.new(32, 3, 4, 32, Silth::Argon2::Type::ID)
    tag = Silth::Argon2.derive(Bytes.new(32, 1_u8), Bytes.new(16, 2_u8), params, Bytes.new(8, 3_u8), Bytes.new(12, 4_u8))
    tag.hexstring.should eq("0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
  end

  it "verifies PHC strings made by other implementations" do
    # Rust's `argon2` crate (a Loco application), password "12341234"
    digest = "$argon2id$v=19$m=19456,t=2,p=1$ETQBx4rTgNAZhSaeYZKOZg$eYTdH26CRT6nUJtacLDEboP0li6xUwUF/q5nSlQ8uuc"
    Silth::Argon2.verify("12341234", digest).should be_true
    Silth::Argon2.verify("12341235", digest).should be_false
    Silth::Argon2.params(digest).memory.should eq(19456)
    Silth::Argon2.verify("x", "$argon2id$garbage").should be_false
  end

  it "hashes and verifies its own PHC strings" do
    digest = Silth::Argon2.hash("secret", memory: 64, iterations: 1)
    digest.should start_with("$argon2id$v=19$m=64,t=1,p=1$")
    Silth::Argon2.verify("secret", digest).should be_true
  end
end

describe Silth::Password do
  it "verifies bcrypt and Argon2id, hashes with the configured algorithm" do
    bcrypt = Silth::Password.hash("secret")
    bcrypt.should start_with("$2")
    argon = Silth::Argon2.hash("secret", memory: 64, iterations: 1)
    Silth::Password.verify("secret", bcrypt).should be_true
    Silth::Password.verify("secret", argon).should be_true
    Silth::Password.verify("secret", "plain").should be_false
    Silth::Password.needs_rehash?(bcrypt).should be_false
    Silth::Password.needs_rehash?(argon).should be_true
    Silth.config.set("auth.password_algorithm", "argon2id")
    Silth::Password.hash("secret").should start_with("$argon2id$v=19$m=64,t=1,p=1$")
    Silth::Password.needs_rehash?(argon).should be_false
    Silth::Password.needs_rehash?(bcrypt).should be_true
  ensure
    Silth.config.set("auth.password_algorithm", "bcrypt")
  end
end

class CreateAccountsSpecTable < Silth::Migration
  version 2026_01_01_000004

  def change
    create_table :spec_accounts do |t|
      t.id
      t.string :email, null: false
      t.string :password_digest
    end
  end
end

class SpecAccount < Silth::Model
  include Silth::Auth::Authenticatable
  table spec_accounts
  primary_key
  column email : String
  column password_digest : String?, hidden: true
end

describe "Silth::Auth.rehash" do
  it "stores a password again with the configured algorithm after a login" do
    legacy = "$argon2id$v=19$m=19456,t=2,p=1$ETQBx4rTgNAZhSaeYZKOZg$eYTdH26CRT6nUJtacLDEboP0li6xUwUF/q5nSlQ8uuc"
    account = SpecAccount.create!(email: "ada@example.com", password_digest: legacy)
    account.authenticate?("12341234").should be_true
    Silth::Auth.rehash(account, "12341234")
    fresh = SpecAccount.find(account.id)
    fresh.password_digest.not_nil!.should start_with("$2")
    fresh.authenticate?("12341234").should be_true
  end
end
