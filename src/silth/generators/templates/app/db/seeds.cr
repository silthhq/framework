# `silth db:seed` runs DatabaseSeeder.
class DatabaseSeeder < Silth::Seeder
  def run
    # call UsersSeeder
    # User.create!(name: "Admin", email: "admin@example.com", password_digest: Silth::Crypto.hash_password("password"))
  end
end
