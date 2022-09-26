require 'helper'

require "fluent/test/helpers"
require "fluent/test/driver/output"

require 'fluent/plugin/out_norikra'

class NorikraOutputTest < Test::Unit::TestCase
  CONFIG = %[
    target_map_tag yes
  ]

  def create_driver(conf=CONFIG)
    Fluent::Test::Driver::Output.new(Fluent::Plugin::NorikraOutput).configure(conf)
  end

  def setup
    Fluent::Test.setup
  end

  def test_init
    create_driver
  end
end
