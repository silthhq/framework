module Silth
  # Fake data generator for seeds, factories and tests (no external dictionaries).
  #
  # ```
  # Silth::Fake.name       # => "Mira Vance"
  # Silth::Fake.email      # => "mira.vance42@example.test"
  # Silth::Fake.sentence   # => "Ancient shells echo beneath the pale lake."
  # ```
  module Fake
    extend self

    FIRST = %w(Ada Ash Bram Cora Dain Elia Fenn Gale Hollis Iris Jace Kael Lyra Mira Nox Orin Pell Quinn Rhea Soren Tamsin Una Vale Wren Xan Yara Zeph)
    LAST  = %w(Ashgrove Blackmere Crane Dusk Ember Fallow Greaves Hallow Ivers Juniper Kestrel Lark Moth Nightingale Oakes Pale Quill Rook Sable Thorne Umber Vance Wick Yew)
    WORDS = %w(ancient abyss pale lake shell crystal lantern hollow echo dream silk thread moss stone kingdom ruin mask
      void soul ember dusk dawn veil whisper shadow light path deep root crown spire garden mist frost bloom song
      silent wandering forgotten luminous quiet distant hidden broken sacred gentle restless endless)
    DOMAINS = %w(example.test silth.test mail.test)
    CITIES  = %w(Dirtmouth Greenreach Hallownest Lumen Mistral Nocturne Pharos Quietbay Rainhold Silvermere Thornfield Umbra)
    COMPANIES = %w(Labs Works Collective Guild Studio Forge Systems Atelier Foundry)

    @@rng = Random.new

    def seed(value : Int) : Nil
      @@rng = Random.new(value)
    end

    def rand(range : Range(Int32, Int32)) : Int32
      @@rng.rand(range)
    end

    def number(min : Int32 = 0, max : Int32 = 1000) : Int32
      @@rng.rand(min..max)
    end

    def float(min : Float64 = 0.0, max : Float64 = 1.0) : Float64
      min + @@rng.rand * (max - min)
    end

    def bool(chance : Float64 = 0.5) : Bool
      @@rng.rand < chance
    end

    def pick(list : Array(T)) : T forall T
      list[@@rng.rand(list.size)]
    end

    def first_name : String
      pick(FIRST)
    end

    def last_name : String
      pick(LAST)
    end

    def name : String
      "#{first_name} #{last_name}"
    end

    def username : String
      "#{first_name.downcase}#{last_name.downcase[0, 3]}#{number(1, 999)}"
    end

    def email : String
      "#{first_name.downcase}.#{last_name.downcase}#{number(1, 9999)}@#{pick(DOMAINS)}"
    end

    def word : String
      pick(WORDS)
    end

    def words(count : Int32 = 3) : Array(String)
      Array.new(count) { word }
    end

    def sentence(words : Int32 = 8) : String
      text = self.words(words).join(' ')
      text.capitalize + "."
    end

    def paragraph(sentences : Int32 = 4) : String
      Array.new(sentences) { sentence(number(6, 12)) }.join(' ')
    end

    def paragraphs(count : Int32 = 3) : String
      Array.new(count) { paragraph }.join("\n\n")
    end

    def title : String
      words(number(2, 5)).map(&.capitalize).join(' ')
    end

    def slug : String
      words(3).join('-')
    end

    def city : String
      pick(CITIES)
    end

    def company : String
      "#{last_name} #{pick(COMPANIES)}"
    end

    def url : String
      "https://#{word}.#{pick(DOMAINS)}/#{slug}"
    end

    def phone : String
      "+33 6 #{Array.new(4) { number(10, 99) }.join(' ')}"
    end

    def uuid : String
      UUID.random.to_s
    end

    def hex_color : String
      "#%06x" % @@rng.rand(0xFFFFFF)
    end

    def date(from : Time = Time.utc - 365.days, to : Time = Time.utc) : Time
      span = (to - from).total_seconds
      from + (@@rng.rand * span).seconds
    end

    def price(min : Float64 = 1.0, max : Float64 = 500.0) : Float64
      float(min, max).round(2)
    end

    def vector(dimensions : Int32) : Array(Float32)
      Array(Float32).new(dimensions) { (@@rng.rand * 2 - 1).to_f32 }
    end
  end
end
