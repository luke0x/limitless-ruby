require 'minitest/autorun'
require 'json'
require 'tmpdir'
ENV['LIMITLESS_API_KEY'] ||= 'test'
require_relative '../limitless'

class JsonConversionTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @json_path = File.join(@tmpdir, 'sample.json')
    lifelog = {
      'data' => {
        'lifelog' => {
          'id' => 'abc123',
          'startTime' => '2023-01-01T00:00:00Z',
          'endTime' => '2023-01-01T00:01:00Z',
          'markdown' => "# Title\nBody text",
          'contents' => [
            { 'type' => 'blockquote', 'startOffsetMs' => 0,    'endOffsetMs' => 1000, 'speakerName' => 'Alice', 'content' => 'Hello' },
            { 'type' => 'blockquote', 'startOffsetMs' => 1000, 'endOffsetMs' => 2000, 'speakerName' => 'Bob',   'content' => 'Hi' }
          ]
        }
      }
    }
    File.write(@json_path, JSON.generate(lifelog))
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_json_to_vtt
    out_path = json_to_vtt(@json_path)
    assert File.exist?(out_path)
    content = File.read(out_path)
    assert_includes content, 'WEBVTT'
    assert_includes content, 'NOTE ID: abc123'
    assert_includes content, '00:00:00.000 --> 00:00:01.000'
    assert_includes content, '<v Alice> Hello'
  end

  def test_json_to_txt
    out_path = json_to_txt(@json_path)
    assert File.exist?(out_path)
    content = File.read(out_path)
    assert_includes content.lines.first, 'ID: abc123'
    assert_includes content, "Alice:\n"
    assert_includes content, 'Hello'
    assert_includes content, 'Bob:'
  end

  def test_json_to_md
    out_path = json_to_md(@json_path)
    assert File.exist?(out_path)
    content = File.read(out_path)
    assert_equal "# Title\nBody text", content
  end
end
