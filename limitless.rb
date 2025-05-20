#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Incrementally sync all your Limitless lifelogs (a.k.a. transcripts).
#
#   ruby limitless.rb sync [--dir DIR] [--since …] [--until …] [--poll 10]
#
#   --dir   Download folder (default: ./transcripts)
#   --since / --until  Restrict the range (ISO date/time or YYYY‑MM‑DD)
#   --poll  Poll every N minutes until interrupted (Ctrl‑C)
#
# Environment:
#   LIMITLESS_API_KEY   – required
#
# Only std‑lib: net/http, uri, json, optparse, time, set, fileutils, io/console.
# No gems required – add them here if that ever changes.

require "net/http"
require "uri"
require "json"
require "time"
require "optparse"
require "fileutils"
require "set"
require "io/console"

API_BASE = "https://api.limitless.ai/v1"
API_KEY  = ENV["LIMITLESS_API_KEY"] or abort "Set LIMITLESS_API_KEY"

# Simple global rate limiter – minimum delay between API calls (milliseconds)
MIN_API_DELAY_MS = 3000               # tweak as needed
$last_api_call_at = nil              # monotonic timestamp of the previous call

# Custom Error for API interactions
class ApiError < StandardError; end

def ms_to_timestamp(ms)
  total = ms.to_i
  hrs   = total / 3_600_000
  mins  = (total % 3_600_000) / 60_000
  secs  = (total % 60_000) / 1_000
  ms_val    = total % 1_000 # Renamed to avoid conflict with method name
  format("%02d:%02d:%02d.%03d", hrs, mins, secs, ms_val)
end

# Helper – enforces the new single-resource envelope shape returned by
# GET /lifelogs/{id}. Raises if the file is one of the old, "flat" JSON blobs.

def lifelog_from(json)
  json.dig("data", "lifelog") or raise "Unsupported JSON structure: 'data.lifelog' key missing."
end

# Convert a Limitless transcript JSON file to a side-car .vtt file in the
# same directory. Headings are ignored, only spoken blockquotes are kept.
# Returns the written VTT path, or nil if it already exists.
def json_to_vtt(json_path, outdir = nil)
  data = JSON.parse(File.read(json_path))
  ll   = lifelog_from(data)
  id   = ll.fetch("id")
  start_iso = ll["startTime"]
  end_iso   = ll["endTime"]
  base_dir  = outdir || File.dirname(json_path)
  vtt_path  = File.join(base_dir, "#{id}.vtt")

  # Skip if the target already exists and is non-empty.
  return nil if File.size?(vtt_path) # File.size? is nil for 0-byte or non-existent

  # Extract and sort unique speaker names
  speakers = ll.fetch("contents", []).map { |c| c["speakerName"] }.compact.uniq.sort

  File.open(vtt_path, "w") do |f|
    f.puts "WEBVTT"
    f.puts
    f.puts "NOTE ID: #{id}"
    f.puts "NOTE StartTime: #{start_iso}" if start_iso
    f.puts "NOTE EndTime: #{end_iso}"   if end_iso
    f.puts "NOTE Speakers: #{speakers.join(", ")}" unless speakers.empty?
    f.puts

    ll.fetch("contents", []).each do |chunk|
      next unless chunk["type"] == "blockquote"
      s_ms = chunk["startOffsetMs"] || chunk["startOffset"]
      e_ms = chunk["endOffsetMs"]   || chunk["endOffset"]
      next unless s_ms && e_ms
      speaker = chunk["speakerName"] || "Unknown"
      text    = chunk["content"].to_s.gsub(/\r?\n/, " ").strip

      f.puts "#{ms_to_timestamp(s_ms)} --> #{ms_to_timestamp(e_ms)}"
      f.puts "<v #{speaker}> #{text}"
      f.puts
    end
  end

  vtt_path
end

# Convert a Limitless transcript JSON file to a plain-text side-car (.txt) file.
# Format:
#   SpeakerName:
#   First utterance line
#   Next utterance line
#   
#   OtherSpeaker:
#   Their utterance
# – A blank line is inserted whenever the speaker changes.
# Returns the written .txt path, or nil if it already exists.
def json_to_txt(json_path, outdir = nil)
  data     = JSON.parse(File.read(json_path))
  ll       = lifelog_from(data)
  id       = ll.fetch("id")
  start_iso = ll["startTime"]
  end_iso   = ll["endTime"]
  base_dir = outdir || File.dirname(json_path)
  txt_path = File.join(base_dir, "#{id}.txt")

  return nil if File.size?(txt_path)

  # Extract and sort unique speaker names
  speakers = ll.fetch("contents", []).map { |c| c["speakerName"] }.compact.uniq.sort

  File.open(txt_path, "w") do |f|
    # Add header similar to VTT but without "NOTE "
    f.puts "ID: #{id}"
    f.puts "StartTime: #{start_iso}" if start_iso
    f.puts "EndTime: #{end_iso}"   if end_iso
    f.puts "Speakers: #{speakers.join(', ')}" unless speakers.empty?
    f.puts # Blank line after header

    prev_speaker = nil

    ll.fetch("contents", []).each do |chunk|
      next unless chunk["type"] == "blockquote"
      speaker = (chunk["speakerName"] || "Unknown").to_s.strip
      text    = chunk["content"].to_s.gsub(/\r?\n/, " ").strip
      next if text.empty?

      if speaker != prev_speaker
        f.puts "" unless prev_speaker.nil?   # blank line between speaker blocks
        f.puts "#{speaker}:"
        prev_speaker = speaker
      end

      f.puts text
    end
  end

  txt_path
end

# Convert a Limitless transcript JSON file to a Markdown side-car (.md) file.
# Simply extracts the "markdown" field of the lifelog (if present) and writes
# it verbatim. Returns the written .md path, or nil if it already exists.

def json_to_md(json_path, outdir = nil)
  data = JSON.parse(File.read(json_path))
  ll   = lifelog_from(data)
  id   = ll.fetch("id")
  base_dir = outdir || File.dirname(json_path)
  md_path = File.join(base_dir, "#{id}.md")

  return nil if File.size?(md_path)

  markdown = ll["markdown"]
  raise "No markdown field present in lifelog #{id}." if markdown.nil? || markdown.empty?

  # Normalize newlines to \n for consistency
  content = markdown.gsub(/\r?\n/, "\n")
  File.write(md_path, content)
  md_path
end

# Helper for processing multiple files for VTT/TXT conversion
def process_files_for_conversion(args, options, conversion_method, extension_name, mode_description)
  if args.empty?
    abort "Error: Provide transcript JSON files or glob patterns when using --#{extension_name} for #{mode_description}."
  end

  files = args.flat_map { |pattern| Dir.glob(pattern) }.uniq
  if files.empty?
    abort "Error: No files matched the given pattern(s) for #{mode_description}."
  end

  total = files.size
  converted_count = 0
  skipped_count = 0
  error_count = 0

  puts "Starting #{mode_description} for #{plural(total, 'file')}..."

  files.each_with_index do |path, idx|
    base_name = File.basename(path, '.json')
    progress_prefix = "[#{idx + 1}/#{total}] #{base_name}"
    begin
      output_path = conversion_method.call(path, options[:outdir])
      if output_path.nil?
        puts "#{progress_prefix}: Skipped existing .#{extension_name}"
        skipped_count += 1
      else
        puts "#{progress_prefix}: Saved -> #{output_path}"
        converted_count += 1
      end
    rescue JSON::ParserError => e
      warn "#{progress_prefix}: Error parsing JSON: #{e.message.lines.first.strip} – skipping."
      error_count += 1
    rescue StandardError => e
      warn "#{progress_prefix}: Error processing: #{e} – skipping."
      error_count += 1
    end
  end

  puts "---"
  puts "#{mode_description} complete."
  puts "Successfully converted: #{converted_count}"
  puts "Skipped (already exist): #{skipped_count}"
  puts "Errors: #{error_count}"
  puts "---"
end

def plural(n, word, plural_suffix = 's')
  "#{n} #{word}#{n == 1 ? '' : plural_suffix}"
end

# ---------------------------------------------------------------------------
# Helper: build OptionParser instances without mutating opts hashes.
# ---------------------------------------------------------------------------

def build_sync_parser(target_hash = nil)
  OptionParser.new do |o|
    o.banner = "usage: limitless sync [options]"
    o.on("--poll [N]", Integer, "Poll every N minutes (default 3)") { |v| target_hash[:poll] = v || 3 if target_hash }
    o.on("--dir DIR",              "Destination directory")        { |v| target_hash[:dir]   = v if target_hash }
    o.on("--since DATE_OR_TS",     "Start date/time")              { |v| target_hash[:since] = v if target_hash }
    o.on("--until DATE_OR_TS",     "End   date/time")              { |v| target_hash[:until] = v if target_hash }
    o.on("--help", "Show this help") { puts o; exit }
  end
end

def build_convert_parser(target_hash = nil)
  banner = "usage: limitless convert <md|txt|vtt> file…"
  OptionParser.new do |o|
    o.banner = banner
    o.on("--outdir DIR", "Output directory (default current directory)") { |v| target_hash[:outdir] = v if target_hash }
    o.on("--type TYPE",  "Conversion type (md|txt|vtt) – overrides positional fmt") { |v| target_hash[:type] = v if target_hash }
    o.on("--help", "Show this help") { puts o; exit }
  end
end

# ---------------------------------------------------------------------------
# Global help / top-level usage
# ---------------------------------------------------------------------------

if __FILE__ == $PROGRAM_NAME
  if ARGV.empty?
    puts "usage: limitless <sync|convert>    (use --help for details)"
    exit 0
  end

  if %w[-h --help help].include?(ARGV[0])
    puts "Limitless – Swiss-army knife for your lifelogs\n"
    puts "Commands and options:\n"
    puts build_sync_parser.to_s
    puts
    puts build_convert_parser.to_s
    exit 0
  end

  cmd = ARGV.shift or abort "usage: limitless <sync|convert> …"

  case cmd
  when "sync"
    sync_opts = {}
    build_sync_parser(sync_opts).parse!(ARGV)
    # Defer actual execution until the end of the file so that all helper
    # methods (e.g. sync_once) are defined before we call them.
    at_exit { run_sync(sync_opts) }

  when "convert"
    # Show convert command help if requested before specifying fmt
    if ARGV.empty? || %w[-h --help].include?(ARGV[0])
      puts build_convert_parser
      exit 0
    end

    fmt = ARGV.shift

    convert_opts = {}
    build_convert_parser(convert_opts).parse!(ARGV)
    at_exit { run_convert(fmt, ARGV, convert_opts) }

  else
    abort "unknown command #{cmd.inspect}"
  end
end

def request_json(path, params = {})
  # --- rate-limit -----------------------------------------------------------
  if $last_api_call_at
    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - $last_api_call_at) * 1000.0
    if elapsed_ms < MIN_API_DELAY_MS
      sleep((MIN_API_DELAY_MS - elapsed_ms) / 1000.0)
    end
  end
  $last_api_call_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Ensure the joined URI keeps the "/v1" prefix from API_BASE.
  clean_path = path.to_s.sub(%r{^/}, "")
  uri       = URI.join(API_BASE + "/", clean_path) # API_BASE should not have a trailing slash for this
  uri.query = URI.encode_www_form(params) if params.any?
  req       = Net::HTTP::Get.new(uri)
  req["X-API-Key"] = API_KEY

  begin
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      res = http.request(req)
      unless res.is_a?(Net::HTTPSuccess)
        error_message = "API request to #{uri.path} failed with status #{res.code}"
        # Try to include response body for more context, ensuring it's not excessively long
        body_summary = res.body.to_s
        if body_summary.length > 200
          body_summary = "#{body_summary[0,197]}..."
        end
        error_message += ": #{body_summary}" unless body_summary.empty?
        raise ApiError, error_message
      end
      JSON.parse(res.body)
    end
  rescue JSON::ParserError => e
    raise ApiError, "Failed to parse JSON response from API path #{uri.path}: #{e.message}"
  rescue SocketError, Errno::ECONNREFUSED => e # Network-level errors
    raise ApiError, "Network error while requesting #{uri.path}: #{e.message}"
  end
end

def existing_ids(dir)
  Dir.glob(File.join(dir, "*.json")).map { |p| File.basename(p, ".json") }.to_set
end

def filename_for(entry)
  "#{entry["id"]}.json"
end

# --- Helper methods for sync_once ---
def fetch_all_lifelog_ids(opts)
  all_ids = []
  cursor  = nil
  puts "Fetching list of lifelogs from API..."
  loop do
    begin
      page = request_json("lifelogs", {
        "timezone"        => opts[:timezone],
        "includeMarkdown" => "false",
        "includeHeadings" => "false",
        "limit"           => opts[:limit].to_s,
        "direction"       => "desc",
        "start"           => opts[:since],
        "end"             => opts[:until],
        "cursor"          => cursor
      }.compact)
    rescue ApiError => e
      warn "API Error while listing lifelogs (cursor=#{cursor.inspect}): #{e.message}"
      warn "Proceeding with #{plural(all_ids.size, 'ID')} collected "
      break
    end

    lifelogs    = page.dig("data", "lifelogs") || []
    all_ids    += lifelogs.map { |e| e["id"] }

    next_cursor = page.dig("meta", "lifelogs", "nextCursor")
    disp_cursor = next_cursor.nil? ? "none" :
                  (next_cursor.size <= 16 ? next_cursor : "#{next_cursor[0,8]}…#{next_cursor[-8,8]}")
    puts " Fetched #{plural(lifelogs.size, 'ID')} (next: #{disp_cursor})"

    cursor = next_cursor
    break if cursor.nil? || lifelogs.empty?
  end
  all_ids
end

def download_missing_lifelogs(missing_ids, total_remote_ids, opts)
  return 0 if missing_ids.empty?

  puts "Downloading #{plural(missing_ids.size, 'new entry')}..."
  downloaded_count = 0
  terminal_width = IO.console.winsize[1] rescue 80 # Get terminal width for pretty printing, default 80

  missing_ids.each_with_index do |id, idx|
    progress_prefix = "[#{idx + 1}/#{missing_ids.size}] #{id}"
    begin
      # Use print for line overwriting
      print "\r#{progress_prefix}: Fetching...".ljust(terminal_width)
      STDOUT.flush

      entry_data = request_json("lifelogs/#{id}", {
        "timezone"        => opts[:timezone],
        "includeMarkdown" => "true",
        "includeHeadings" => "true"
      })
    rescue ApiError => e
      # Move to next line before warning
      warn "\n#{progress_prefix}: Error fetching details: #{e.message} – skipping."
      next
    end

    path = File.join(opts[:dir], "#{id}.json") # Use id directly, filename_for was removed
    begin
      File.write(path, JSON.pretty_generate(entry_data)) # Use pretty_generate
      size = File.size?(path) || 0
      # Overwrite the line with progress, then print full info
      puts "\r#{progress_prefix}: Saved (#{size} bytes) -> #{path}".ljust(terminal_width)
      downloaded_count += 1
    rescue Errno::ENOENT, Errno::EACCES => e # Filesystem errors
       # Move to next line before warning
       warn "\n#{progress_prefix}: Error writing file #{path}: #{e.message} - skipping."
    end
  end
  # Ensure the final line is clear after the loop if print was used
  puts "" if missing_ids.any? 
  downloaded_count
end

def sync_once(opts)
  puts "Limitless Sync:"
  puts "  { dir=#{opts[:dir]}, since=#{opts[:since] || 'API default'}, until=#{opts[:until] || 'API default'} }"
  FileUtils.mkdir_p(opts[:dir], mode: opts[:dir_mode])

  # Already-downloaded transcript IDs
  local_ids = existing_ids(opts[:dir])

  # 1) Fetch all relevant lifelog IDs from the API
  all_remote_ids = fetch_all_lifelog_ids(opts)
  total_remote_count = all_remote_ids.size

  # Determine missing IDs
  # Convert to Set for efficient difference, though reject is fine for typical sizes
  missing_ids = all_remote_ids.reject { |id| local_ids.include?(id) }
  
  puts "Summary:"
  puts "  #{total_remote_count} found remotely"
  puts "- #{total_remote_count - missing_ids.size} already downloaded"
  puts "===="
  puts "  #{missing_ids.size} to download"

  # 2) Fetch missing lifelogs one-by-one
  downloaded_this_run = download_missing_lifelogs(missing_ids, total_remote_count, opts)
  
  puts "Finished: #{plural(downloaded_this_run, 'new entry')} added"

rescue Interrupt # Allow Ctrl-C during the main sync_once phases
  warn "\nSync operation interrupted by user."
  # No specific exit here, let the calling poll loop or main flow handle exit.
rescue StandardError => e # Catch any other unexpected errors during sync
  warn "Error during sync operation: #{e.message}"
  warn e.backtrace.join("\n") if opts[:debug] # Optional: add a --debug flag for full backtraces
end

# ---------------------------------------------------------------------------
#  Support helpers executed via the at_exit hooks above
# ---------------------------------------------------------------------------

def run_sync(opts)
  # Merge in the original defaults expected by sync_once
  defaults = {
    dir:      "transcripts",
    timezone: "UTC",
    limit:    10,
    dir_mode: 0o755
  }
  merged = defaults.merge(opts)

  if merged[:poll]
    puts "Polling every #{merged[:poll]} min – Ctrl-C to stop."
    loop do
      sync_once(merged)
      sleep merged[:poll] * 60
    end
  else
    sync_once(merged)
  end
end

def run_convert(fmt, files, opts = {})
  # Allow flag override
  fmt = (opts[:type] || fmt).to_s.downcase

  conv_method, ext_name = case fmt
  when "vtt" then [method(:json_to_vtt), "vtt"]
  when "txt" then [method(:json_to_txt), "txt"]
  when "md"  then [method(:json_to_md),  "md"]
  else
    abort "Unknown conversion type #{fmt.inspect} – expected md, txt, or vtt"
  end

  outdir = opts[:outdir]
  FileUtils.mkdir_p(outdir) if outdir
  process_files_for_conversion(files, opts, conv_method, ext_name, "#{fmt.upcase} conversion")
end