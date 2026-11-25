require "./spec_helper"

class CreateRelationSpecTables < Silth::Migration
  version 2026_01_01_000002

  def change
    create_table :articles do |t|
      t.id
      t.string :title, null: false
      t.integer :remarks_count, null: false, default: 0
      t.lock_version
    end
    create_table :clips do |t|
      t.id
      t.string :name, null: false
    end
    create_table :remarks do |t|
      t.id
      t.string :body, null: false
      t.references :article, null: true, on_delete: :nullify
      t.string :remarkable_type
      t.bigint :remarkable_id
      t.soft_deletes
      t.index [:remarkable_type, :remarkable_id]
    end
    create_table :likes do |t|
      t.id
      t.string :likeable_type, null: false
      t.bigint :likeable_id, null: false
    end
  end
end

class Article < Silth::Model
  primary_key
  column title : String
  column remarks_count : Int32 = 0
  optimistic_locking
  has_many remarks : Remark, as: remarkable
end

class Clip < Silth::Model
  primary_key
  column name : String
  has_one remark : Remark, as: remarkable, dependent: :destroy
end

class Remark < Silth::Model
  primary_key
  column body : String
  soft_deletes
  belongs_to article : Article, optional: true, counter_cache: true
  belongs_to remarkable : Article | Clip, polymorphic: true, optional: true
end

class Like < Silth::Model
  primary_key
  belongs_to likeable, polymorphic: true
end

describe "polymorphic relations" do
  it "stores the type and id, and reads the record back" do
    article = Article.create!(title: "Hello")
    clip = Clip.create!(name: "Intro")
    on_article = Remark.create!(body: "nice", remarkable: article)
    on_clip = Remark.create!(body: "great", remarkable: clip)

    on_article.remarkable_type.should eq("Article")
    Remark.find(on_article.id).remarkable.as(Article).title.should eq("Hello")
    expect_raises(ArgumentError, /Like is not a valid remarkable/) { on_clip.remarkable = Like.new }
    Remark.find(on_clip.id).remarkable.as(Clip).name.should eq("Intro")
    article.remarks.pluck(:body).should eq(["nice"])
    clip.remark.try(&.body).should eq("great")

    created = article.remarks.create!(body: "via the relation")
    created.remarkable_type.should eq("Article")
    created.remarkable_id.should eq(article.id)
  end

  it "preloads every type at once" do
    article = Article.create!(title: "A")
    clip = Clip.create!(name: "C")
    Remark.create!(body: "1", remarkable: article)
    Remark.create!(body: "2", remarkable: clip)
    remarks = Remark.includes(:remarkable).order(id: :asc).to_a
    remarks.map(&.remarkable.class).should eq([Article, Clip])
    Article.includes(:remarks).find(article.id).remarks.to_a.map(&.body).should eq(["1"])
  end

  it "resolves untyped relations to any model" do
    clip = Clip.create!(name: "Liked")
    like = Like.create!(likeable: clip)
    Like.find(like.id).likeable.as(Clip).name.should eq("Liked")
    Like.includes(:likeable).first.likeable.should eq(clip)
  end
end

describe "counter caches" do
  it "counts children on create, move, soft delete, restore and destroy" do
    first = Article.create!(title: "First")
    second = Article.create!(title: "Second")
    remark = Remark.create!(body: "one", article: first)
    Remark.create!(body: "two", article: first)
    first.reload.remarks_count.should eq(2)

    remark.article = second
    remark.save!
    {first.reload.remarks_count, second.reload.remarks_count}.should eq({1, 1})

    remark.destroy # soft delete
    second.reload.remarks_count.should eq(0)
    remark.restore
    second.reload.remarks_count.should eq(1)
    remark.force_destroy
    second.reload.remarks_count.should eq(0)
    Remark.create!(body: "orphan").article.should be_nil
  end
end

describe "optimistic locking" do
  it "refuses to overwrite a newer version" do
    article = Article.create!(title: "Draft")
    mine = Article.find(article.id)
    theirs = Article.find(article.id)

    mine.update!(title: "Mine")
    mine.lock_version.should eq(1)
    expect_raises(Silth::ORM::StaleObjectError, /lock_version 0/) do
      theirs.update!(title: "Theirs")
    end
    expect_raises(Silth::ORM::StaleObjectError) { theirs.destroy }

    theirs.reload.update!(title: "Theirs")
    Article.find(article.id).title.should eq("Theirs")
    Article.find(article.id).lock_version.should eq(2)
    theirs.destroy.should be_true
  end
end
