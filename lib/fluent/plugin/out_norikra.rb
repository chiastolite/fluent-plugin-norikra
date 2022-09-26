require 'fluent/plugin/output'

require 'norikra-client'

require_relative 'norikra/config_section'
require_relative 'norikra/query'
require_relative 'norikra/query_generator'
require_relative 'norikra/record_filter'
require_relative 'norikra/target'

require_relative 'norikra/fetch_request'

module Fluent::Plugin
  class NorikraOutput < Fluent::Plugin::Output
    Fluent::Plugin.register_output('norikra', self)

    config_set_default :flush_interval, 1 # 1sec

    config_param :norikra, :string, default: 'localhost:26571'

    config_param :connect_timeout, :integer, default: nil
    config_param :send_timeout, :integer, default: nil
    config_param :receive_timeout, :integer, default: nil

    config_param :remove_tag_prefix, :string, default: nil
    config_param :target_map_tag, :bool, default: false
    config_param :target_map_key, :string, default: nil
    config_param :target_string, :string, default: nil
    config_param :drop_error_record, :bool, default: true
    config_param :drop_server_error_record, :bool, default: false
    config_param :drop_when_shutoff, :bool, default: false

    # <default>
    # <target TARGET>

    def configure(conf)
      super

      @host,@port = @norikra.split(':', 2)
      @port = @port.to_i

      if !@target_map_tag && @target_map_key.nil? && @target_string.nil?
        raise Fluent::ConfigError, 'target naming not specified (target_map_tag/target_map_key/target_string)'
      end

      setup_output(conf, false) # <query> disabled in <default> and <target TARGET>
    end

    def setup_output(conf, enable_auto_query)
      @enable_auto_query = enable_auto_query

      @target_generator = case
                          when @target_string
                            lambda {|tag,record| @target_string}
                          when @target_map_key
                            lambda {|tag,record| record[@target_map_key]}
                          when @target_map_tag
                            lambda {|tag,record| tag.gsub(/^#{@remove_tag_prefix}(\.)?/, '')}
                          else
                            raise Fluent::ConfigError, "no one way specified to decide target"
                          end

      # target map already prepared (opened, and related queries registered)
      @target_map = {} # 'target' => instance of Fluent::NorikraPlugin::Target

      # for conversion from query_name to tag
      @query_map = {} # 'query_name' => instance of Fluent::NorikraPlugin::Query

      @default_target = Fluent::NorikraPlugin::ConfigSection.new(Fluent::Config::Element.new('default', nil, {}, []), @enable_auto_query)
      @config_targets = {}

      conf.elements.each do |element|
        case element.name
        when 'default'
          @default_target = Fluent::NorikraPlugin::ConfigSection.new(element, @enable_auto_query)
        when 'target'
          c = Fluent::NorikraPlugin::ConfigSection.new(element, @enable_auto_query)
          @config_targets[c.target] = c
        end
      end

      @target_mutex = Mutex.new
      @client = Norikra::Client.new(@host, @port, connect_timeout: @connect_timeout, send_timeout: @send_timeout, receive_timeout: @receive_timeout)
    end

    def start
      super
      @register_worker_running = true
      @register_queue = []
      @registered_targets = {}
      @register_thread = Thread.new(&method(:register_worker))
    end

    def shutdown
      @register_worker_running = false
      # @register_thread.kill
      @register_thread.join
      super
    end

    def prepared?(target_names)
      target_names.reduce(true){|r,t| r && @target_map.values.any?{|target| target.escaped_name == t}}
    end

    def fetch_event_registration(query)
      return if query.tag.nil? || query.tag.empty?
      req = FetchRequest.new(:event, query.name, query.interval, 'string', query.tag, nil)
      insert_fetch_queue(req)
    end

    def register_worker
      while sleep(0.25)
        break unless @register_worker_running
        next unless fetchable?

        c = client()

        targets = @register_queue.shift(10)
        targets.each do |t|
          next if @target_map[t.name]

          log.debug "Preparing norikra target #{t.name} on #{@host}:#{@port}"
          if prepare_target(c, t)
            log.debug "success to prepare target #{t.name} on #{@host}:#{@port}"

            if @enable_auto_query
              raise "bug" unless self.respond_to?(:insert_fetch_queue)

              t.queries.each do |query|
                @query_map[query.name] = query
                fetch_event_registration(query)
              end
            end
            @target_map[t.name] = t
            @registered_targets.delete(t.name)
          else
            log.error "Failed to prepare norikra data for target:#{t.name}"
            @register_queue.push(t)
          end
        end
      end
    end

    def prepare_target(client, target)
      # target open and reserve fields
      log.debug "Going to prepare about target"
      begin
        unless client.targets.include?(target.escaped_name)
          log.debug "opening target #{target.escaped_name}"
          client.open(target.escaped_name, target.reserve_fields, target.auto_field)
          log.debug "opening target #{target.escaped_name}, done."
        end

        reserving = target.reserve_fields
        reserved = []
        client.fields(target.escaped_name).each do |field|
          if reserving[field['name']]
            reserved.push(field['name'])
            if reserving[field['name']] != field['type']
              log.warn "field type mismatch, reserving:#{reserving[field['name']]} but reserved:#{field['type']}"
            end
          end
        end

        reserving.each do |fieldname,type|
          client.reserve(target.escaped_name, fieldname, type) unless reserved.include?(fieldname)
        end
      rescue => e
        log.error "failed to prepare target:#{target.escaped_name}", :norikra => "#{@host}:#{@port}", :error => e.class, :message => e.message
        return false
      end

      # query registration
      begin
        registered = Hash[client.queries.map{|q| [q['name'], q['expression']]}]
        target.queries.each do |query|
          if registered.has_key?(query.name) # query already registered
            if registered[query.name] != query.expression
              log.warn "query name and expression mismatch, check norikra server status. target query name:#{query.name}"
            end
            next
          end
          client.register(query.name, query.group, query.expression)

          @query_map[query.name] = query
          fetch_event_registration(query)
        end
      rescue => e
        log.warn "failed to register query", :norikra => "#{@host}:#{@port}", :error => e.class, :message => e.message
      end
    end

    def format_stream(tag, es)
      tobe_registered_target_names = []

      out = ''

      es.each do |time,record|
        target = @target_generator.call(tag, record)

        tgt = @target_mutex.synchronize do
          t = @target_map[target]
          unless t
            unless tobe_registered_target_names.include?(target)
              conf = @config_targets[target]
              unless conf
                @config_targets.values.each do |c|
                  if c.target_matcher.match(target)
                    conf = c
                    break
                  end
                end
              end
              t = Target.new(target, @default_target + conf)
              @registered_targets[target] = t
              @register_queue.push(t)
              tobe_registered_target_names.push(target)
            end
            t = @registered_targets[target]
          end
          t
        end

        event = tgt.filter(time, record)

        out << [tgt.escaped_name,event].to_msgpack
      end

      out
    end

    def write(chunk)
      events_map = {} # target => [event]
      chunk.msgpack_each do |target, event|
        events_map[target] ||= []
        events_map[target].push(event)
      end

      unless prepared?(events_map.keys)
        raise RuntimeError, "norikra server is not ready for this targets: #{events_map.keys.join(',')}"
      end

      c = client()

      events_map.each do |target, events|
        begin
          c.send(target, events)
        rescue Norikra::RPC::ClientError => e
          raise unless @drop_error_record
          log.warn "Norikra server reports ClientError, and dropped", target: target, message: e.message
        rescue Norikra::RPC::ServerError => e
          raise unless @drop_server_error_record
          log.warn "Norikra server reports ServerError, and dropped", target: target, message: e.message
        rescue Norikra::RPC::ServiceUnavailableError => e
          raise unless @drop_when_shutoff
          log.warn "Norikra server is now in Shutoff mode, and dropped", target: target, message: e.message
        end
      end
    end
  end
end
