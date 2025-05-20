# frozen_string_literal: true
require 'minitest/autorun'
ENV['LIMITLESS_API_KEY'] ||= 'test'
require_relative '../limitless'

class MsToTimestampTest < Minitest::Test
  def test_conversion
    assert_equal '01:02:03.000', ms_to_timestamp(3_723_000)
  end
end
