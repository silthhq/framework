# Compile-time template processor (invoked through the `run` macro).
#
# Silth templates use the ECR syntax with safer defaults:
#
# * `<%= expr %>`   — output, **HTML escaped** (unless `expr` is `Silth::SafeHTML`)
# * `<%== expr %>`  — raw output (no escaping)
# * `<% code %>`    — control code
# * `<%# note %>`   — comment, removed at compile time
# * `<%-` / `-%>`   — trim surrounding whitespace
#
# Usage: crystal ecr_process.cr <template> <buffer_name>
require "ecr/lexer"

filename = ARGV[0]
buffer = ARGV[1]? || "@view_io"

unless File.exists?(filename)
  STDERR.puts "Silth template not found: #{filename}"
  exit 1
end

def append_loc(str, filename, line, column)
  str << "#<loc:"
  filename.inspect(str)
  str << ',' << line << ',' << column << '>'
end

def suppress_leading(token, string)
  if (token.type.output? || token.type.control?) && token.suppress_leading?
    char_index = string.rindex('\n')
    char_index = char_index ? char_index + 1 : 0
    byte_index = string.char_index_to_byte_index(char_index).not_nil!
    reader = Char::Reader.new(string)
    reader.pos = byte_index
    while reader.current_char.ascii_whitespace? && reader.has_next?
      reader.next_char
    end
    string = string.byte_slice(0, byte_index) if reader.pos == string.bytesize
  end
  string
end

def suppress_trailing(token, flag)
  if flag && token.type.string?
    idx = token.value.index('\n')
    token.value = token.value[idx + 1..-1] if idx
  end
end

lexer = ECR::Lexer.new(File.read(filename))
token = lexer.next_token
path = File.expand_path(filename)

output = String.build do |str|
  loop do
    case token.type
    when .string?
      string = token.value
      token = lexer.next_token
      string = suppress_leading(token, string)
      next if string.empty?
      str << buffer << " << "
      string.inspect(str)
      str << '\n'
    when .output?
      string = token.value
      line, column = token.line_number, token.column_number
      trailing = token.suppress_trailing?
      token = lexer.next_token
      suppress_trailing(token, trailing)
      if string.starts_with?('=')
        str << "#<loc:push>("
        append_loc(str, path, line, column + 1)
        str << string[1..] << ")#<loc:pop>.to_s(" << buffer << ")\n"
      else
        str << "::Silth::View.escape(" << buffer << ", #<loc:push>("
        append_loc(str, path, line, column)
        str << string << ")#<loc:pop>)\n"
      end
    when .control?
      string = token.value
      line, column = token.line_number, token.column_number
      trailing = token.suppress_trailing?
      token = lexer.next_token
      suppress_trailing(token, trailing)
      next if string.lstrip.starts_with?('#')
      str << "#<loc:push>"
      append_loc(str, path, line, column)
      str << ' ' unless string.starts_with?(' ')
      str << string << "#<loc:pop>\n"
    when .eof?
      break
    end
  end
end

print output
