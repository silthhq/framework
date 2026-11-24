# Compile-time helper (used through the `run` macro): embeds every file of a
# directory as a Crystal hash literal `{"relative/path" => "content"}`.
dir = ARGV[0]
files = Dir.glob(File.join(dir, "**", "*"), match: :dot_files).select { |f| File.file?(f) && !f.ends_with?(".DS_Store") }.sort
STDOUT << "{"
files.each do |file|
  STDOUT << File.join(file[(dir.size + 1)..]).inspect << " => " << File.read(file).inspect << ", "
end
STDOUT << "} of String => String"
