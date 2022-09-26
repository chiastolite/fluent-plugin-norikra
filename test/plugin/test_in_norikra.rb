require 'helper'

require "fluent/test/helpers"
require "fluent/test/driver/input"

require 'fluent/plugin/in_norikra'

class NorikraInputTest < Test::Unit::TestCase
  CONFIG = %[
  ]

  def create_driver(conf=CONFIG)
    Fluent::Test::Driver::Input.new(Fluent::Plugin::NorikraInput).configure(conf)
  end

  def setup
    Fluent::Test.setup
  end

  def test_init
    create_driver
  end
end
