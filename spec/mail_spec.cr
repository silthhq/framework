require "./spec_helper"

class MarkdownSpecMail < Silth::Mail
  def initialize(@name : String, @url : String)
  end

  def build : Nil
    to "ada@example.com", "Ada"
    subject "Welcome aboard"
    markdown "spec/fixtures/views/mail_welcome.md.ecr", name: @name, plan: "Pro <b>", url: @url
    attach_data "hello", "hello.txt", "text/plain"
  end
end

class MarkdownSpecMailPreview < Silth::MailPreview
  def welcome : Silth::Mail
    MarkdownSpecMail.new("Ada", "https://example.com/confirm?a=1&b=2")
  end
end

module MailSpec
  def self.context : {Silth::Context, IO::Memory}
    io = IO::Memory.new
    {Silth::Context.new(HTTP::Server::Context.new(HTTP::Request.new("GET", "/"), HTTP::Server::Response.new(io))), io}
  end
end

describe "Markdown mails" do
  it "renders themed HTML with inline styles, values shown as is" do
    mail = MarkdownSpecMail.new("Tom & <Jerry>", "https://example.com/confirm?a=1&b=2").prepare!
    html = mail.html_body.not_nil!
    html.should contain(%(Welcome, Tom &amp; &lt;Jerry&gt;!</h1>))
    html.should match(/<h1 id="[^"]*" style="margin:0 0 16px/)
    html.should contain(%(<strong>Pro &lt;b&gt;</strong>))
    html.should contain(%(<a href="https://example.com/confirm?a=1&amp;b=2" style="display:inline-block))
    html.should contain(%(Code: 123 &amp; co</td>))
    html.should contain(%(<li>one</li>))
    html.should_not contain(%(class="anchor"))
    html.should contain(%(<title>Welcome aboard</title>))
  end

  it "derives the text version with readable links" do
    text = MarkdownSpecMail.new("Tom & <Jerry>", "https://example.com/c?a=1&b=2").prepare!.text_body.not_nil!
    text.should contain("Welcome, Tom & <Jerry>!")
    text.should contain("Confirm my address (https://example.com/c?a=1&b=2)")
    text.should contain("- one")
    text.lines.none?(&.ends_with?(' ')).should be_true
  end

  it "is what `silth g mail` generates, with a preview" do
    dir = File.tempname("silth-gen", nil)
    Dir.mkdir_p(dir)
    begin
      Dir.cd(dir) do
        Silth::Generators.generate("mail", "Welcome", [] of String, output: IO::Memory.new)
        File.read("src/mails/welcome_mail.cr").should contain(%(markdown "mails/welcome", name: @name))
        File.read("src/views/mails/welcome.md.ecr").should contain("<%= button")
        File.read("src/mails/previews/welcome_mail_preview.cr").should contain("class WelcomeMailPreview < Silth::MailPreview")
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe Silth::MailPreview do
  it "lists previews and renders them without sending" do
    Silth::MailPreview.all.should contain({"MarkdownSpecMailPreview", ["welcome"]})
    Silth::MailPreview.render("MarkdownSpecMailPreview", "welcome").not_nil!.subject_line.should eq("Welcome aboard")
    Silth::MailPreview.render("MarkdownSpecMailPreview", "nope").should be_nil
    Silth::Mailer.sent.should be_empty
  end

  it "shows previews in the profiler" do
    viewer = Silth::Profiler::MailViewer
    viewer.index.should contain(%(href="/_silth/profiler/mails/preview/MarkdownSpecMailPreview/welcome"))
    page = viewer.show("mails/preview/MarkdownSpecMailPreview/welcome")
    page.should contain("Welcome aboard")
    page.should contain(%(<iframe sandbox src="/_silth/profiler/mails/preview/MarkdownSpecMailPreview/welcome/html"))
    page.should contain("hello.txt")

    ctx, io = MailSpec.context
    viewer.serve_raw(ctx, "mails/preview/MarkdownSpecMailPreview/welcome/html")
    ctx.response.close
    io.to_s.should contain("Content-Security-Policy: default-src 'none'")
    io.to_s.should contain("Welcome, Ada!")

    WelcomeCapture.new.deliver
    viewer.show("mails/sent/0").should contain("Captured")
  end
end

class WelcomeCapture < Silth::Mail
  def build : Nil
    to "bob@example.com"
    subject "Captured"
    text "Hi"
  end
end

class InlineLogoSpecMail < Silth::Mail
  def build : Nil
    to "ada@example.com"
    subject "Logo"
    html %(<img src="cid:logo">)
    attach_inline Bytes[0x89, 0x50, 0x4E, 0x47], "logo.png", "image/png", "logo"
  end
end

describe "Silth::Mail inline attachments" do
  it "carries a Content-ID the HTML refers to" do
    mime = InlineLogoSpecMail.new.to_mime
    mime.should contain("Content-ID: <logo>")
    mime.should contain("Content-Disposition: inline; filename=\"logo.png\"")
  end
end
