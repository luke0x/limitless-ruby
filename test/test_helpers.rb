require 'minitest/autorun'
ENV['LIMITLESS_API_KEY'] ||= 'test'
require_relative '../limitless'

class HelperFunctionsTest < Minitest::Test
  def test_plural
    assert_equal '1 file', plural(1, 'file')
    assert_equal '2 files', plural(2, 'file')
  end

  def test_build_sync_parser
    opts = {}
    parser = build_sync_parser(opts)
    parser.parse!(%w[--dir tmp --since 2023-01-01 --until 2023-12-31 --poll 5])
    assert_equal 'tmp', opts[:dir]
    assert_equal '2023-01-01', opts[:since]
    assert_equal '2023-12-31', opts[:until]
    assert_equal 5, opts[:poll]
  end

  def test_build_sync_parser_default_poll
    opts = {}
    parser = build_sync_parser(opts)
    parser.parse!(%w[--poll])
    assert_equal 3, opts[:poll]
  end

  def test_build_convert_parser
    opts = {}
    parser = build_convert_parser(opts)
    parser.parse!(%w[--outdir out --type txt])
    assert_equal 'out', opts[:outdir]
    assert_equal 'txt', opts[:type]
  end
end
