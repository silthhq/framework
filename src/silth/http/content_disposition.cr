require "uri"

module Silth
  # A `Content-Disposition` header that survives any file name (RFC 6266):
  # an ASCII fallback for old clients, and the exact UTF-8 name in `filename*`.
  #
  # ```
  # Silth::ContentDisposition.format("attachment", "Facture été.pdf")
  # # => %(attachment; filename="Facture _t_.pdf"; filename*=UTF-8''Facture%20%C3%A9t%C3%A9.pdf)
  # ```
  module ContentDisposition
    # Characters RFC 5987 allows unescaped in `filename*`.
    ATTR_CHARS = "!#$&+-.^_`|~"

    def self.format(disposition : String, filename : String) : String
      %(#{disposition}; filename="#{ascii_fallback(filename)}"; filename*=UTF-8''#{encode(filename)})
    end

    # Printable ASCII kept, anything else (and `"`, `\\`) replaced by `_`.
    def self.ascii_fallback(filename : String) : String
      filename.gsub { |c| c.ascii? && !c.ascii_control? && c != '"' && c != '\\' ? c : '_' }
    end

    def self.encode(filename : String) : String
      String.build do |io|
        filename.each_byte do |byte|
          char = byte.unsafe_chr
          if byte < 0x80 && (char.ascii_alphanumeric? || ATTR_CHARS.includes?(char))
            io << char
          else
            io << '%' << byte.to_s(16).upcase.rjust(2, '0')
          end
        end
      end
    end
  end
end
