module Silth
  module Profiler
    # Links that open a file at a line in your editor: from the debug page, the
    # profiler's timeline, queries and exceptions.
    #
    # ```yaml
    # # config/profiler.yml
    # editor: ${SILTH_EDITOR:-vscode}   # vscode, cursor, zed, idea, sublime, textmate, emacs, macvim…
    # # editor: "myeditor://open?path={file}&line={line}"   # or any URL template
    # # editor_root: /home/me/blog        # the app's path on your machine (app running in Docker)
    # ```
    #
    # ```
    # Profiler::Editor.url("src/controllers/posts_controller.cr", 12)
    # # => "vscode://file/home/me/blog/src/controllers/posts_controller.cr:12"
    # ```
    module Editor
      TEMPLATES = {
        "vscode"          => "vscode://file{file}:{line}",
        "vscode-insiders" => "vscode-insiders://file{file}:{line}",
        "vscodium"        => "vscodium://file{file}:{line}",
        "cursor"          => "cursor://file{file}:{line}",
        "windsurf"        => "windsurf://file{file}:{line}",
        "zed"             => "zed://file{file}:{line}",
        "idea"            => "idea://open?file={file}&line={line}",
        "jetbrains"       => "idea://open?file={file}&line={line}",
        "sublime"         => "subl://open?url=file://{file}&line={line}",
        "textmate"        => "txmt://open?url=file://{file}&line={line}",
        "emacs"           => "emacs://open?url=file://{file}&line={line}",
        "macvim"          => "mvim://open?url=file://{file}&line={line}",
        "nova"            => "nova://open?path={file}&line={line}",
      }

      # The URL template in use (`{file}` and `{line}` placeholders), nil when no
      # editor is configured.
      def self.template : String?
        name = Silth.config.string?("profiler.editor").presence || return nil
        return nil if name == "none"
        TEMPLATES[name.downcase]? || (name.includes?("{file}") ? name : nil)
      end

      # A URL opening *file* (relative to the app or absolute) at *line*, or nil.
      def self.url(file : String, line : Int32) : String?
        template = self.template || return nil
        relative = file.lchop(Dir.current + "/")
        root = Silth.config.string?("profiler.editor_root").presence
        path = if root && !relative.starts_with?('/')
                 File.join(root, relative)
               else
                 File.expand_path(relative)
               end
        path = "/#{path}" unless path.starts_with?('/') # C:/… on Windows
        template.gsub("{file}", URI.encode_path(path)).gsub("{line}", line.to_s)
      end

      # HTML for `file:line`: a link to the editor when one is configured.
      def self.link(file : String, line : Int32, text : String = "#{file.lchop(Dir.current + "/")}:#{line}", css : String = "s-src") : String
        if href = url(file, line)
          %(<a class="#{css}" href="#{HTML.escape(href)}" title="Open in your editor">#{HTML.escape(text)}</a>)
        else
          %(<code class="#{css}">#{HTML.escape(text)}</code>)
        end
      end

      def self.link(source : Source, css : String = "s-src") : String
        text = source.method.empty? ? source.to_s : "#{source} · #{source.method}"
        link(source.file, source.line, text, css)
      end
    end
  end
end
