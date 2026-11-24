# Minimal, dependency-free `.env` loader.
#
# Files are loaded in this order (first value wins, real ENV always wins):
# `.env.<env>.local`, `.env.local`, `.env.<env>`, `.env`
module Silth::Dotenv
  extend self

  def load(root : String = Dir.current, env : String = Silth.env) : Nil
    files = [".env.#{env}.local", (env == "test" ? nil : ".env.local"), ".env.#{env}", ".env"].compact
    files.each do |name|
      path = File.join(root, name)
      next unless File.file?(path)
      parse(File.read(path)).each do |key, value|
        ENV[key] = value unless ENV.has_key?(key)
      end
    end
  end

  def parse(content : String) : Hash(String, String)
    result = {} of String => String
    lines = content.lines
    i = 0
    while i < lines.size
      line = lines[i].strip
      i += 1
      next if line.empty? || line.starts_with?('#')
      line = line.lchop("export ").lstrip
      eq = line.index('=') || next
      key = line[0...eq].strip
      raw = line[(eq + 1)..].strip
      value =
        if raw.starts_with?('"')
          # Double quoted, may span multiple lines, supports escapes and ${VAR}.
          buffer = raw[1..]
          while !closed_quote?(buffer, '"') && i < lines.size
            buffer += "\n" + lines[i]
            i += 1
          end
          inner = buffer.rchop.sub(/"\s*(#.*)?$/, "")
          expand(unescape(inner), result)
        elsif raw.starts_with?('\'')
          raw[1..].sub(/'\s*(#.*)?$/, "")
        else
          expand(raw.sub(/\s+#.*$/, ""), result)
        end
      result[key] = value
    end
    result
  end

  private def closed_quote?(text : String, quote : Char) : Bool
    escaped = false
    text.each_char do |c|
      if escaped
        escaped = false
      elsif c == '\\'
        escaped = true
      elsif c == quote
        return true
      end
    end
    false
  end

  private def unescape(text : String) : String
    text.gsub("\\n", "\n").gsub("\\t", "\t").gsub("\\\"", "\"").gsub("\\\\", "\\")
  end

  private def expand(text : String, local : Hash(String, String)) : String
    text.gsub(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/) do |_, m|
      ENV[m[1]]? || local[m[1]]? || m[2]? || ""
    end
  end
end
