require "./spec_helper"

describe Silth::Model do
  it "creates, validates and finds records" do
    note = Note.create!(title: "First", views: 3)
    note.persisted?.should be_true
    Note.find(note.id).title.should eq("First")
    bad = Note.new(title: "x")
    bad.valid?.should be_false
    bad.errors["title"].first.should contain("too short")
    expect_raises(Silth::ORM::RecordInvalid) { Note.create!(title: "") }
  end

  it "tracks changes and updates only dirty columns" do
    note = Note.create!(title: "Dirty")
    note.views = 9
    note.changes.should eq({"views" => {0, 9}})
    note.save!
    note.changed?.should be_false
    Note.find(note.id).views.should eq(9)
  end

  it "chains scopes and query methods" do
    Note.create!(title: "Pinned A", pinned: true, views: 10)
    Note.create!(title: "Pinned B", pinned: true, views: 1)
    Note.create!(title: "Plain", views: 50)
    Note.pinned.count.should eq(2)
    Note.pinned.popular(5).pluck(:title).should eq(["Pinned A"])
    Note.where(:views, ">", 5).order(views: :desc).first.title.should eq("Plain")
    Note.where_in(:title, ["Plain", "Pinned B"]).count.should eq(2)
    # InnoDB only indexes FULLTEXT rows on commit, so skip inside a transactional spec.
    Note.search([:title, :body], "plain").count.should eq(1) unless Silth::DB.connection.dialect.name == "mysql"
    Note.paginate(1, 2).total_pages.should eq(2)
  end

  it "handles relations and eager loading" do
    author = Author.create!(name: "Ada")
    Note.create!(title: "Mine", author_id: author.id)
    author.notes.count.should eq(1)
    author.notes.build(title: "Built").author_id.should eq(author.id)
    notes = Note.includes(:author).where(author_id: author.id).to_a
    notes.first.author.not_nil!.name.should eq("Ada")
    Author.includes(:notes).find(author.id).notes.size.should eq(1)
  end

  it "soft deletes" do
    note = Note.create!(title: "Trash")
    note.destroy
    Note.find?(note.id).should be_nil
    Note.with_trashed.find(note.id).trashed?.should be_true
    Note.only_trashed.count.should eq(1)
  end

  it "rolls back transactions and serializes JSON" do
    expect_raises(Exception) do
      Note.transaction do
        Note.create!(title: "Ghost")
        raise "abort"
      end
    end
    Note.where(title: "Ghost").exists?.should be_false
    note = Note.create!(title: "JSON", meta: JSON.parse(%({"k":1})))
    JSON.parse(note.to_json)["meta"]["k"].as_i.should eq(1)
  end

  it "uses the raw query builder" do
    Silth::DB.table("notes").insert(title: "Raw", views: 7)
    Silth::DB.table("notes").where(title: "Raw").first["views"].should eq(7)
    Silth::DB.table("notes").where(title: "Raw").update(views: 8).should eq(1)
    Silth::DB.scalar("SELECT COUNT(*) FROM notes WHERE title = ?", ["Raw"]).should eq(1)
  end
end
