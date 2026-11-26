require "./spec_helper"

describe "Releases" do
  it "keeps shard.yml, Silth::VERSION and the changelog in step" do
    YAML.parse(File.read("shard.yml"))["version"].as_s.should eq(Silth::VERSION)
    File.read("CHANGELOG.md").should contain("## [#{Silth::VERSION}]")
    Silth.release_line.should eq(Silth::VERSION.split('.')[0, 2].join('.'))
  end

  it "generates apps on the release line of the CLI, or on main with --edge" do
    released = Silth::Generators::App.new("demo", output: IO::Memory.new)
    released.dependency.should contain("version: ~> #{Silth::VERSION}")
    released.image_tag.should eq(Silth.release_line)
    edge = Silth::Generators::App.new("demo", output: IO::Memory.new, edge: true)
    edge.dependency.should contain("branch: main")
    edge.image_tag.should eq("edge")
    Silth::Generators::App.new("demo", silth_path: "../framework", output: IO::Memory.new).dependency.should eq("    path: ../framework")
  end
end

describe Silth::Commands::Export do
  it "writes pages as index.html, files as they are" do
    {"/" => "/index.html", "/docs" => "/docs/index.html", "/docs/0.1" => "/docs/0.1/index.html",
     "/docs/0.1/intro" => "/docs/0.1/intro/index.html", "/llms.txt" => "/llms.txt",
     "/docs/0.1/intro.md" => "/docs/0.1/intro.md", "/install.sh" => "/install.sh"}.each do |path, file|
      Silth::Commands::Export.output_file(path).should eq(file)
    end
  end
end

describe Silth::Deprecation do
  it "warns once per message and raises with SILTH_DEPRECATIONS=raise" do
    Silth::Deprecation.reset
    Silth.deprecated("profiler.keep_profiles", instead: "profiler.keep", removed_in: "0.3")
    Silth.deprecated("profiler.keep_profiles", instead: "profiler.keep", removed_in: "0.3")
    Silth::Deprecation.warnings.should eq(["profiler.keep_profiles is deprecated, use profiler.keep instead (removed in 0.3)"])
    ENV["SILTH_DEPRECATIONS"] = "raise"
    expect_raises(Silth::Deprecation::Error, /old_helper is deprecated/) { Silth.deprecated("old_helper") }
  ensure
    ENV.delete("SILTH_DEPRECATIONS")
    Silth::Deprecation.reset
  end
end
