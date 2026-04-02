#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "time"
require "yaml"

ROOT = File.expand_path("..", __dir__)
CATALOG_PATH = File.join(ROOT, "data", "catalog.yaml")
INSTRUCTION_PATH = File.join(ROOT, "instruction.md")
LOG_DIR = File.join(ROOT, "tmp", "codex-fill")
FIELD_ALIASES = {
  "example_reddit" => "reddit_example"
}.freeze
ALLOWED_FIELDS = %w[definitions example tarot_cards reddit_example].freeze
FIELD_ORDER = %w[definitions example reddit_example tarot_cards].freeze
KNOWN_ITEM_KEYS = %w[id important definitions example example_source_title example_link reddit_example reddit_example_url tarot_cards].freeze

def blank?(value)
  value.nil? || (value.respond_to?(:empty?) && value.empty?)
end

def humanize_mood_id(mood_id)
  mood_id.sub(/\Amood_/, "").tr("_", " ")
end

def titleize(text)
  text.split.map { |word| word[0] ? word[0].upcase + word[1..] : word }.join(" ")
end

def load_catalog
  YAML.safe_load(File.read(CATALOG_PATH), permitted_classes: [], aliases: false)
end

def find_item_by_id(items, emotion_id)
  items.find { |item| item["id"] == emotion_id }
end

def important_item?(item)
  value = item["important"]
  value == true || value.to_s.strip == "true"
end

def field_filled?(item, field)
  case field
  when "definitions"
    definitions = item["definitions"]
    definitions.is_a?(Array) && definitions.length == 2 && definitions.all? { |entry| !blank?(entry.to_s.strip) }
  when "example"
    !blank?(item["example"].to_s.strip) &&
      !blank?(item["example_source_title"].to_s.strip) &&
      !blank?(item["example_link"].to_s.strip)
  when "reddit_example"
    !blank?(item["reddit_example"].to_s.strip) &&
      !blank?(item["reddit_example_url"].to_s.strip)
  when "tarot_cards"
    cards = item["tarot_cards"]
    cards.is_a?(Array) && !cards.empty? && cards.all? { |entry| !blank?(entry.to_s.strip) }
  else
    false
  end
end

def emotion_filled?(item)
  FIELD_ORDER.all? { |field| field_filled?(item, field) }
end

def mood_tone(mood_id)
  value = mood_id.to_s.sub(/\Amood_/, "")
  words = value.split("_")
  positive_tokens = %w[
    accomplished accepted adoring affectionate alive amazed amused appreciated at ease attentive
    awe balanced blessed blissful buoyant calm carefree cheerful confident connected content
    delighted eager ecstatic elated empowered encouraged energized engaged enjoyment enthusiastic
    euphoric fulfilled glad grateful happy hopeful inspired interested joyful loving loved
    motivated optimistic peaceful pleased proud refreshed relieved respected safe satisfied secure
    serene stoked successful supported thankful touched tranquil understood valued valid
    validated whole worthy zen
  ]
  negative_tokens = %w[
    abandoned abused afraid alienated angry anguished annoyed anxious apathetic apprehensive ashamed
    betrayed blue burdened burned out cancelled crushed defeated dejected depressed desolate despair
    disappointed disgusted disheartened distressed dread dysregulated embarrassed empty enraged exhausted
    excluded fearful forlon forlorn frustrated gaslit ghosted glum grief guilty heartbroken helpless
    hopeless horrified humiliated hurt hurting inadequate insecure invalidated irate irritable jealous jilted
    letdown lonely lost mad melncholic melancholic miserable minimized nauseated neglected nervous numb
    overwhelmed panicked pathetic peeved pessimistic pissed poopy regretful rejected remorseful resentful sad
    scared scorn shame shocked sorrowful spiteful strained stressed stuck suffocated tense terrified
    tired trapped troubled uncomfortable undervalued uneasy unhappy unmotivated unseen upset vengeful vulnerable
    weary worried worthless
  ]

  return :positive if words.any? { |token| positive_tokens.include?(token) }
  return :negative if words.any? { |token| negative_tokens.include?(token) }

  :mixed
end

def example_context(item)
  lines = []
  lines << "Current definitions:" if item["definitions"].is_a?(Array) && !item["definitions"].empty?
  item.fetch("definitions", []).each_with_index do |definition, index|
    lines << "#{index + 1}. #{definition}"
  end
  unless blank?(item["example"].to_s.strip) || blank?(item["example_source_title"].to_s.strip) || blank?(item["example_link"].to_s.strip)
    lines << "Current example: #{item['example']}"
    lines << "Current example source title: #{item['example_source_title']}"
    lines << "Current example link: #{item['example_link']}"
  end
  lines.join("\n")
end

def prompt_for(field, item, instructions)
  mood_id = item.fetch("id")
  mood_name = humanize_mood_id(mood_id)
  mood_label = titleize(mood_name)
  shared_header = <<~TEXT
    You are filling one field in a mood catalog.

    Mood id: #{mood_id}
    Mood label: #{mood_label}

    Important rules:
    - Do not edit files.
    - Do not run commands that change files or git state.
    - Return only JSON that matches the schema.
    - English level must stay around B2.

    Catalog writing instructions:
    #{instructions}
  TEXT

  case field
  when "definitions"
    <<~TEXT
      #{shared_header}

      Write the `definitions` field.

      Requirements:
      - Return exactly 2 definitions.
      - Each definition must be exactly 1 sentence.
      - Explain what the feeling means, what causes it, and what makes it distinct.
      - Do not just list synonyms.
      - Keep the wording clear, compact, and natural.
      - Do not use markdown inside the strings.
    TEXT
  when "example"
    <<~TEXT
      #{shared_header}

      Write the `example` field.

      #{example_context(item)}

      Requirements:
      - Return exactly 1 example paragraph as a string.
      - The example must come from a real article, book, or story.
      - Do not invent a scene.
      - Use a source tied to year 2010 or earlier only.
      - Do not use politics or politician figures in any way.
      - Return the source title and a stable public URL for that source in the `example_link` field.
      - If the source is a book or story, the URL can be a canonical page for the work, such as Wikipedia, Britannica, Project Gutenberg, or the publisher.
      - Use 2 to 4 short sentences.
      - It should feel like the first paragraph of a magazine feature, not a classroom sentence.
      - Name the real person, group, institution, or character from the source when possible.
      - Prefer concrete details from the real source such as a year, number, amount of money, age, time span, score, or count when available.
      - Prefer a real-world public fact, scandal, or high-stakes situation when that fits the mood naturally.
      - If that would feel forced, use a real scene from a real book or story with concrete stakes.
      - Show the feeling through the situation and make it clear why this mood fits the source.
      - Do not use an unnamed invented person like "she" or "he" unless the real source itself keeps the person unnamed.
      - Do not start with "Imagine".
      - Do not use markdown.
      - Return JSON with exactly these keys: `example`, `example_source_title`, `example_link`.
    TEXT
  when "tarot_cards"
    <<~TEXT
      #{shared_header}

      Write the `tarot_cards` field.

      #{example_context(item)}

      Requirements:
      - Return 1 to 3 tarot cards.
      - Use common Rider-Waite-Smith style names only.
      - Each item must be exactly in this format: `Card Name: short explanation.`
      - Keep each explanation to 1 sentence.
      - Make the match specific to this mood, not generic.
      - Do not use markdown beyond the plain strings.
    TEXT
  when "reddit_example"
    tone = mood_tone(mood_id)
    subreddit_hint =
      case tone
      when :positive
        "Prefer positive or reflective communities with personal stories that are easy to verify, including AskReddit, MadeMeSmile, BenignExistence, or similar threads."
      when :negative
        "Prefer conflict, confession, or distress discussions that are easy to verify, especially AskReddit, relationships, offmychest, AITAH, or similar story-driven threads."
      else
        "Pick a Reddit thread that naturally matches this mood and is easy to verify from search results."
      end

    source_url = item["reddit_source_url"].to_s.strip
    source_notes = item["reddit_source_notes"].to_s.strip
    source_username = item["reddit_source_username"].to_s.strip
    source_block =
      if source_url.empty? || source_notes.empty? || source_username.empty?
        <<~TEXT
          Source selection:
          - Use web search to find one real Reddit thread or comment that clearly fits the mood.
          - #{subreddit_hint}
          - Prefer older, widely cited Reddit threads that are easy to verify quickly from search results.
          - Use at most 3 web searches before choosing a source.
          - Spend at most about 60 seconds picking the source.
          - Use that one post as the only source.
          - Include the Reddit username and public Reddit URL in the result.
        TEXT
      else
        <<~TEXT
          Source to use (required):
          - Reddit URL: #{source_url}
          - Reddit username: #{source_username}
          - Source notes: #{source_notes}
        TEXT
      end

    source_requirements =
      if source_url.empty? || source_notes.empty? || source_username.empty?
        <<~TEXT
          - The example must come from one real Reddit source.
          - Use web search and cite only the chosen source.
          - Return the source URL in `reddit_example_url`.
          - Mention the Reddit username used by the source in the paragraph.
        TEXT
      else
        <<~TEXT
          - The example must come from the provided real Reddit source only.
          - Do not browse the web or search for any other source.
          - Mention the Reddit username exactly as provided in the paragraph.
          - Return the source URL in `reddit_example_url`.
        TEXT
      end

    <<~TEXT
      #{shared_header}

      Write the `reddit_example` field.

      #{example_context(item)}

      #{source_block}

      Requirements:
      - Return exactly 1 Reddit-based personal example paragraph as a string.
      #{source_requirements}
      - Do not invent a scene, account, or numbers.
      - Recent Reddit posts are allowed if they are a strong match and easy to verify.
      - Do not use politics or politician figures in any way.
      - Pick the first credible qualifying source quickly; do not keep searching for a perfect match.
      - If the post clearly shows the mood, use it even if the title does not literally name the mood.
      - Use 2 to 4 short sentences.
      - It should read like a magazine lead paragraph with concrete details when available.
      - Show why the chosen mood fits the post.
      - Do not start with "Imagine".
      - Do not use markdown.
    TEXT
  else
    raise "Unsupported field: #{field}"
  end
end

def schema_for(field)
  case field
  when "definitions"
    {
      type: "object",
      additionalProperties: false,
      required: ["definitions"],
      properties: {
        definitions: {
          type: "array",
          minItems: 2,
          maxItems: 2,
          items: { type: "string", minLength: 20, maxLength: 220 }
        }
      }
    }
  when "example"
    {
      type: "object",
      additionalProperties: false,
      required: ["example", "example_source_title", "example_link"],
      properties: {
        example: { type: "string", minLength: 80, maxLength: 800 },
        example_source_title: { type: "string", minLength: 4, maxLength: 240 },
        example_link: { type: "string", minLength: 10, maxLength: 500 }
      }
    }
  when "tarot_cards"
    {
      type: "object",
      additionalProperties: false,
      required: ["tarot_cards"],
      properties: {
        tarot_cards: {
          type: "array",
          minItems: 1,
          maxItems: 3,
          items: { type: "string", minLength: 12, maxLength: 180 }
        }
      }
    }
  when "reddit_example"
    {
      type: "object",
      additionalProperties: false,
      required: ["reddit_example", "reddit_example_url"],
      properties: {
        reddit_example: { type: "string", minLength: 80, maxLength: 800 },
        reddit_example_url: { type: "string", minLength: 10, maxLength: 500 }
      }
    }
  else
    raise "Unsupported field: #{field}"
  end
end

def validate_payload(field, payload)
  case field
  when "definitions"
    definitions = payload.fetch("definitions")
    raise "definitions must be an array" unless definitions.is_a?(Array) && definitions.length == 2
    cleaned = definitions.map do |entry|
      value = entry.to_s.strip
      raise "definition is too short" if value.length < 20
      raise "definition must be one sentence" unless value.count(".!?") >= 1
      value
    end
    { "definitions" => cleaned }
  when "example"
    example = payload.fetch("example").to_s.strip
    source_title = payload.fetch("example_source_title").to_s.strip
    source_url = payload.fetch("example_link").to_s.strip
    raise "example is too short" if example.length < 80
    raise "example source title is missing" if source_title.length < 4
    raise "example source url is invalid" unless source_url.match?(%r{\Ahttps?://}i)
    raise "example should not start with Imagine" if example.match?(/\Aimagine\b/i)
    {
      "example" => example,
      "example_source_title" => source_title,
      "example_link" => source_url
    }
  when "tarot_cards"
    cards = payload.fetch("tarot_cards")
    raise "tarot_cards must be an array" unless cards.is_a?(Array) && !cards.empty? && cards.length <= 3
    cleaned = cards.map do |entry|
      value = entry.to_s.strip
      raise "tarot card entry must contain a colon" unless value.include?(": ")
      value
    end
    { "tarot_cards" => cleaned }
  when "reddit_example"
    reddit_example = payload.fetch("reddit_example").to_s.strip
    reddit_url = payload.fetch("reddit_example_url").to_s.strip
    raise "reddit_example is too short" if reddit_example.length < 80
    raise "reddit example url is invalid" unless reddit_url.match?(%r{\Ahttps://([a-z0-9-]+\.)?reddit\.com/}i)
    raise "reddit example should not start with Imagine" if reddit_example.match?(/\Aimagine\b/i)
    {
      "reddit_example" => reddit_example,
      "reddit_example_url" => reddit_url
    }
  else
    raise "Unsupported field: #{field}"
  end
end

def json_scalar(value)
  JSON.generate(value.to_s)
end

def yaml_scalar(value)
  case value
  when true
    "true"
  when false
    "false"
  when Numeric
    value.to_s
  else
    JSON.generate(value.to_s)
  end
end

def item_key_order(item)
  extras = item.keys.reject { |key| KNOWN_ITEM_KEYS.include?(key) }.sort
  KNOWN_ITEM_KEYS + extras
end

def write_catalog(catalog)
  lines = []
  lines << "title: #{yaml_scalar(catalog.fetch('title'))}"
  lines << "asset_base: #{yaml_scalar(catalog.fetch('asset_base'))}"
  lines << "items:"

  catalog.fetch("items").each do |item|
    lines << "  - id: #{yaml_scalar(item.fetch('id'))}"

    item_key_order(item).each do |key|
      next if key == "id"

      value = item[key]
      next if blank?(value)
      next if value.is_a?(Array) && value.empty?

      if value.is_a?(Array)
        lines << "    #{key}:"
        value.each do |entry|
          lines << "      - #{yaml_scalar(entry)}"
        end
      else
        lines << "    #{key}: #{yaml_scalar(value)}"
      end
    end
  end

  File.write(CATALOG_PATH, lines.join("\n") + "\n")
end

def default_model_for(runner)
  case runner
  when "codex"
    "gpt-5.4"
  when "gemini"
    "gemini-2.5-pro"
  else
    raise "Unsupported runner: #{runner}"
  end
end

def llm_command(options, response_path)
  case options[:runner]
  when "codex"
    [
      "timeout",
      "--signal=TERM",
      "--kill-after=10s",
      "#{options[:timeout_seconds]}s",
      "codex",
      "exec",
      "--dangerously-bypass-approvals-and-sandbox",
      "--model",
      options[:model],
      "--config",
      %(model_reasoning_effort="#{options[:reasoning_effort]}"),
      "--output-last-message",
      response_path,
      "-"
    ]
  when "gemini"
    [
      "timeout",
      "--signal=TERM",
      "--kill-after=10s",
      "#{options[:timeout_seconds]}s",
      "gemini",
      "--model",
      options[:model],
      "--prompt",
      "",
      "--output-format",
      "text",
      "--approval-mode",
      "yolo"
    ]
  else
    raise "Unsupported runner: #{options[:runner]}"
  end
end

def extract_json_text(raw_response)
  raw = raw_response.to_s.strip
  return raw if raw.start_with?("{") && raw.end_with?("}")

  fenced = raw.match(/```(?:json)?\s*(\{.*\})\s*```/im)
  return fenced[1].strip if fenced

  first = raw.index("{")
  last = raw.rindex("}")
  return raw[first..last].strip if first && last && last > first

  raw
end

options = {
  runner: "codex",
  important_only: true,
  emotion: nil,
  field: nil,
  limit: nil,
  timeout_seconds: 240,
  model: nil,
  reasoning_effort: "medium",
  source_url: nil,
  source_notes: nil,
  source_username: nil,
  dry_run: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/fill_moods.rb [options]"

  parser.on("--runner=NAME", String, "LLM runner: codex or gemini (default: codex)") do |value|
    options[:runner] = value
  end

  parser.on("--all", "In batch mode, include non-important moods too") do
    options[:important_only] = false
  end

  parser.on("--emotion=ID", String, "Target one mood id, for example mood_abandoned") do |value|
    options[:emotion] = value
  end

  parser.on("--field=NAME", String, "Target one field: definitions, example, tarot_cards, example_reddit") do |value|
    options[:field] = value
  end

  parser.on("--limit=N", Integer, "Batch mode: process first N emotions and fill only missing fields") do |value|
    options[:limit] = value
  end

  parser.on("--timeout-seconds=N", Integer, "Max seconds for one LLM call (default: 240)") do |value|
    options[:timeout_seconds] = value
  end

  parser.on("--model=NAME", String, "Model for the selected runner") do |value|
    options[:model] = value
  end

  parser.on("--reasoning-effort=LEVEL", String, "Codex reasoning effort: low, medium, high") do |value|
    options[:reasoning_effort] = value
  end

  parser.on("--source-url=URL", String, "Source URL for reddit_example generation") do |value|
    options[:source_url] = value
  end

  parser.on("--source-notes=TEXT", String, "Source notes for reddit_example generation") do |value|
    options[:source_notes] = value
  end

  parser.on("--source-username=NAME", String, "Source username for reddit_example generation, format u/name") do |value|
    options[:source_username] = value
  end

  parser.on("--dry-run", "Print the next target and prompt, but do not call Codex") do
    options[:dry_run] = true
  end
end.parse!

def normalize_field(field_value)
  return nil if blank?(field_value.to_s.strip)

  FIELD_ALIASES.fetch(field_value, field_value)
end

def run_fill_for_field(catalog:, item:, field:, instructions:, options:)
  field_label = field == "reddit_example" ? "example_reddit" : field

  if field == "reddit_example"
    explicit_url = options[:source_url].to_s.strip
    explicit_notes = options[:source_notes].to_s.strip
    explicit_username = options[:source_username].to_s.strip

    if !blank?(explicit_url) && !blank?(explicit_notes) && !blank?(explicit_username)
      item["reddit_source_url"] = explicit_url
      item["reddit_source_notes"] = explicit_notes
      item["reddit_source_username"] = explicit_username
    end
  end

  prompt = prompt_for(field, item, instructions)

  timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
  slug = "#{timestamp}-#{item.fetch('id')}-#{field}"
  FileUtils.mkdir_p(LOG_DIR)

  prompt_path = File.join(LOG_DIR, "#{slug}.prompt.txt")
  stdout_path = File.join(LOG_DIR, "#{slug}.stdout.txt")
  stderr_path = File.join(LOG_DIR, "#{slug}.stderr.txt")
  response_path = File.join(LOG_DIR, "#{slug}.response.json")

  File.write(prompt_path, prompt)

  if options[:dry_run]
    puts "Target: #{item.fetch('id')} -> #{field_label}"
    puts
    puts prompt
    return :ok
  end

  stdout, stderr, status = Open3.capture3(*llm_command(options, response_path), stdin_data: prompt, chdir: ROOT)
  File.write(stdout_path, stdout)
  File.write(stderr_path, stderr)

  unless status.success?
    if status.exitstatus == 124
      warn "#{options[:runner].capitalize} exec timed out after #{options[:timeout_seconds]}s for #{item.fetch('id')} -> #{field_label}"
    end
    warn "#{options[:runner].capitalize} exec failed for #{item.fetch('id')} -> #{field_label}"
    warn "See #{stderr_path} and #{stdout_path}"
    return :error
  end

  raw_response =
    if options[:runner] == "codex"
      if File.exist?(response_path)
        File.read(response_path).to_s.strip
      else
        stdout.to_s.strip
      end
    else
      stdout.to_s.strip
    end

  File.write(response_path, raw_response + "\n") unless options[:runner] == "codex"

  begin
    payload = JSON.parse(extract_json_text(raw_response))
    validated = validate_payload(field, payload)
  rescue StandardError => error
    warn "Response validation failed for #{item.fetch('id')} -> #{field_label}: #{error.message}"
    warn "Raw response saved at #{response_path}"
    return :error
  end

  validated.each do |key, value|
    item[key] = value
  end

  write_catalog(catalog)

  puts "Updated #{item.fetch('id')} -> #{field_label}"
  puts "Prompt: #{prompt_path}"
  puts "Response: #{response_path}"
  :ok
ensure
  item.delete("reddit_source_url")
  item.delete("reddit_source_notes")
  item.delete("reddit_source_username")
end

normalized_field = normalize_field(options[:field])
options[:runner] = options[:runner].to_s.strip.downcase

unless %w[codex gemini].include?(options[:runner])
  warn "Unsupported --runner: #{options[:runner]}. Allowed: codex, gemini"
  exit 1
end

options[:model] = default_model_for(options[:runner]) if blank?(options[:model].to_s.strip)

if !blank?(normalized_field) && !ALLOWED_FIELDS.include?(normalized_field)
  warn "Unsupported field: #{options[:field]}. Allowed: #{(ALLOWED_FIELDS + FIELD_ALIASES.keys).join(', ')}"
  exit 1
end

if options[:limit] && options[:limit] <= 0
  warn "--limit must be greater than 0."
  exit 1
end

if options[:timeout_seconds] <= 0
  warn "--timeout-seconds must be greater than 0."
  exit 1
end

single_mode = !blank?(options[:emotion].to_s.strip) && !blank?(normalized_field)
batch_mode = options[:limit] && blank?(options[:emotion].to_s.strip) && blank?(normalized_field)

unless single_mode || batch_mode
  warn "Use either single mode (--emotion + --field) or batch mode (--limit)."
  exit 1
end

catalog = load_catalog
instructions = File.read(INSTRUCTION_PATH).strip

if single_mode
  item = find_item_by_id(catalog.fetch("items"), options[:emotion])
  if item.nil?
    warn "Could not find mood id: #{options[:emotion]}"
    exit 1
  end

  exit(run_fill_for_field(catalog: catalog, item: item, field: normalized_field, instructions: instructions, options: options) == :ok ? 0 : 1)
end

items = if options[:important_only]
  catalog.fetch("items").select { |item| important_item?(item) }.first(options[:limit])
else
  catalog.fetch("items").first(options[:limit])
end
errors = []
updates = 0
skipped_emotions = 0

items.each do |item|
  if emotion_filled?(item)
    skipped_emotions += 1
    next
  end

  FIELD_ORDER.each do |field|
    next if field_filled?(item, field)

    result = run_fill_for_field(catalog: catalog, item: item, field: field, instructions: instructions, options: options)
    if result == :ok
      updates += 1
      next
    end

    errors << "#{item.fetch('id')} -> #{field}"
    break
  end
end

puts "Batch summary: updated #{updates} field(s), skipped #{skipped_emotions} already-complete emotion(s), errors #{errors.length}."
errors.each { |entry| puts "Error: #{entry}" }
exit(errors.empty? ? 0 : 1)
