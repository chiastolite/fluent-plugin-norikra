module Fluent
  class NorikraFilterOutput < Fluent::BufferedOutput
    Fluent::Plugin.register_output('norikra_filter', self)

    config_set_default :flush_interval, 1 # 1sec

    config_param :norikra, :string, :default => 'localhost:26571'

    config_param :connect_timeout, :integer, :default => nil
    config_param :send_timeout, :integer, :default => nil
    config_param :receive_timeout, :integer, :default => nil

    #<server>
    attr_reader :execute_server, :execute_server_path

    config_param :remove_tag_prefix, :string, :default => nil

    config_param :target_map_tag, :bool, :default => false
    config_param :target_map_key, :string, :default => nil
    config_param :target_string, :string, :default => nil

    # <default>
    # <target TARGET>

    # <events>
    attr_reader :event_method, :event_tag_generator, :event_sweep_interval

    <<HOGE
<fetch>
  method event
  target QUERY_NAME
  interval 5s
  tag    query_name
  # tag    field FIELDNAME
  # tag    string FIXED_STRING
  tag_prefix norikra.event     # actual tag: norikra.event.QUERYNAME
</fetch>
<fetch>
  method sweep
  target QUERY_GROUP # or unspecified => default
  interval 60s
  tag field group_by_key
  tag_prefix norikra.query
</fetch>
HOGE

    def initialize
      super
      require_relative 'norikra_target'
      require 'norikra-client'
    end

    def configure(conf)
      super

      @host,@port = @norikra.split(':', 2)
      @port = @port.to_i

      if !@target_map_tag && @target_map_key.nil? && @target_string.nil?
        raise Fluent::ConfigError, 'target naming not specified (target_map_tag/target_map_key/target_string)'
      end
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
      @target_map = {} # 'target' => instance of Fluent::NorikraOutput::Target

      # for conversion from query_name to tag
      @query_map = {} # 'query_name' => instance of Fluent::NorikraOutput::Query

      @default_target = ConfigSection.new(Fluent::Config::Element.new('default', nil, {}, []))
      @config_targets = {}

      @execute_server = false

      event_section = nil
      conf.elements.each do |element|
        case element.name
        when 'default'
          @default_target = ConfigSection.new(element)
        when 'target'
          c = ConfigSection.new(element)
          @config_targets[c.target] = c
        when 'server'
          @execute_server = true
          @execute_jruby_path = element['jruby']
          @execute_server_path = element['path']
          @execute_server_opts = element['opts']
        when 'event', 'events'
          event_section = element
        else
          raise Fluent::ConfigError, "unknown configuration section name for this plugin: #{element.name}"
        end
      end

      @event_method = @event_tag_generator = @event_sweep_interval = nil
      if event_section
        @event_method = case event_section['method']
                        when 'sweep' then :sweep
                        when 'listen'
                          raise Fluent::ConfigError, "not implemeneted now"
                        else
                          raise Fluent::ConfigError, "unknown method #{event_section['method']}"
                        end
        unless event_section['tag']
          raise Fluent::ConfigError, "<event> section needs 'tag' configuration"
        end
        tag_prefix = if event_section.has_key?('tag_prefix')
                       event_section['tag_prefix'] + (event_section['tag_prefix'] =~ /\.$/ ? '' : '.')
                     else
                       ''
                     end
        tag_by, tag_arg = event_section['tag'].split(/ +/, 2)
        @event_tag_generator = case tag_by
                               when 'query_name' then lambda{|query_name,record| tag_prefix + query_name}
                               when 'field' then lambda{|query_name,record| tag_prefix + record[tag_arg]}
                               when 'string' then lambda{|query_name,record| tag_prefix + tag_arg}
                               else
                                 raise Fluent::ConfigError, "unknown tag configuration specified:#{event_section['tag']}"
                               end
        @event_sweep_interval = Fluent::Config.time_value(event_section['sweep_interval'] || '10s')
      end

      @mutex = Mutex.new
      @target_mutex = Mutex.new
    end

    def client(opts={})
      Norikra::Client.new(@host, @port, {
          :connect_timeout => opts[:connect_timeout] || @connect_timeout,
          :send_timeout    => opts[:send_timeout]    || @send_timeout,
          :receive_timeout => opts[:receive_timeout] || @receive_timeout,
        })
    end

    def start
      super

      @norikra_started = false

      if @execute_server
        @norikra_pid = nil
        @norikra_thread = Thread.new(&method(:server_starter))
        # @norikra_started will be set in server_starter
      else
        @norikra_pid = nil
        @norikra_thread = nil
        @norikra_started = true
      end

      # register worker thread
      @register_queue = []
      @registered_targets = {}
      @register_thread = Thread.new(&method(:register_worker))

      # fetch worker thread
      @fetch_queue = []
      @fetch_thread = Thread.new(&method(:fetch_worker))

      # for sweep
      if @event_method
        @fetch_queue.push(FetchRequest.new(nil, @event_sweep_interval))
      end
    end

    def shutdown
      @register_thread.kill
      @fetch_thread.kill
      Process.kill(:TERM, @norikra_pid) if @execute_server

      @register_thread.join
      @fetch_thread.join

      if @execute_server
        begin
          counter = 0
          while !Process.waitpid(@norikra_pid, Process::WNOHANG)
            sleep 1
            break if counter > 3
          end
        rescue Errno::ECHILD
          # norikra server process exited.
        end
      end
    end

    def server_starter
      $log.info "starting Norikra server process #{@host}:#{@port}"
      base_options = [@execute_server_path, 'start', '-H', @host, '-P', @port.to_s]
      cmd,options = if @execute_jruby_path
                      [@execute_jruby_path, [@execute_server_path, 'start', '-H', @host, '-P', @port.to_s]]
                    else
                      [@execute_server_path, ['start', '-H', @host, '-P', @port.to_s]]
                    end
      if @execute_server_opts
        options += @execute_server_opts.split(/ +/)
      end
      @norikra_pid = fork do
        ENV.keys.select{|k| k =~ /^(RUBY|GEM|BUNDLE|RBENV|RVM|rvm)/}.each {|k| ENV.delete(k)}
        exec([cmd, 'norikra(fluentd)'], *options)
      end
      connecting = true
      $log.info "trying to confirm norikra server status..."
      while connecting
        begin
          $log.debug "start to connect norikra server #{@host}:#{@port}"
          client(:connect_timeout => 1, :send_timeout => 1, :receive_timeout => 1).targets
          # discard result: no exceptions is success
          connecting = false
          next
        rescue HTTPClient::TimeoutError
          $log.debug "Norikra server test connection timeout. retrying..."
        rescue Errno::ECONNREFUSED
          $log.debug "Norikra server test connection refused. retrying..."
        rescue => e
          $log.error "unknown error in confirming norikra server, #{e.class}:#{e.message}"
        end
        sleep 3
      end
      $log.info "confirmed that norikra server #{@host}:#{@port} started."
      @norikra_started = true
    end

    # input-mixin
    def fetch_worker
      while sleep(1)
        next unless @norikra_started #TODO: purge dependency
        next if @fetch_queue.first.nil? || @fetch_queue.first.time > Time.now

        now = Time.now
        while @fetch_queue.first.time <= now
          #TODO: shift, plan to fetch/emit in background, insert_queue

          req = @fetch_queue.shift

          begin
            data = req.fetch(client()) #TODO: purge dependency
          rescue => e
            $log.error "failed to sweep", :norikra => "#{@host}:#{@port}", :error => e.class, :message => e.message
          end

          data.each do |tag, event_array|
            event_array.each do |time,event|
              begin
                Fluent::Engine.emit(tag, time, event)
              rescue => e
                $log.error "failed to emit event from norikra query", :norikra => "#{@host}:#{@port}", :error => e.class, :message => e.message, :tag => tag, :record => event
              end
            end
          end

          insert_fetch_queue(req)
        end
      end
    end

    def register_worker
      while sleep(0.25)
        next unless @norikra_started

        c = client()

        targets = @register_queue.shift(10)
        targets.each do |t|
          next if @target_map[t.name]

          $log.debug "Preparing norikra target #{t.name} on #{@host}:#{@port}"
          if prepare_target(c, t)
            $log.debug "success to prepare target #{t.name} on #{@host}:#{@port}"
            # success
            t.queries.each do |query|
              @query_map[query.name] = query
              #TODO: fix
              insert_fetch_queue(FetchRequest.new(query)) unless query.tag.empty? || @event_method
            end
            @target_map[t.name] = t
            @registered_targets.delete(t.name)
          else
            $log.error "Failed to prepare norikra data for target:#{t.name}"
            @norikra_started.push(t)
          end
        end
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

        event = tgt.filter(record)

        out << [tgt.escaped_name,event].to_msgpack
      end

      out
    end

    def prepared?(target_names)
      @norikra_started && target_names.reduce(true){|r,t| r && @target_map.values.any?{|target| target.escaped_name == t}}
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
        c.send(target, events)
      end
    end

    def prepare_target(client, target)
      # target open and reserve fields
      $log.debug "Going to prepare about target"
      begin
        unless client.targets.include?(target.escaped_name)
          $log.debug "opening target #{target.escaped_name}"
          client.open(target.escaped_name, target.reserve_fields, target.auto_field)
          $log.debug "opening target #{target.escaped_name}, done."
        end

        reserving = target.reserve_fields
        reserved = []
        client.fields(target.escaped_name).each do |field|
          if reserving[field['name']]
            reserved.push(field['name'])
            if reserving[field['name']] != field['type']
              $log.warn "field type mismatch, reserving:#{reserving[field['name']]} but reserved:#{field['type']}"
            end
          end
        end

        reserving.each do |fieldname,type|
          client.reserve(target.escaped_name, fieldname, type) unless reserved.include?(fieldname)
        end
      rescue => e
        $log.error "failed to prepare target:#{target.escaped_name}", :norikra => "#{@host}:#{@port}", :error => e.class, :message => e.message
        return false
      end

      # query registration
      begin
        registered = Hash[client.queries.map{|q| [q['name'], q['expression']]}]
        target.queries.each do |query|
          if registered.has_key?(query.name) # query already registered
            if registered[query.name] != query.expression
              $log.warn "query name and expression mismatch, check norikra server status. target query name:#{query.name}"
            end
            next
          end
          client.register(query.name, query.expression)
        end
      rescue => e
        $log.warn "failed to register query", :norikra => "#{@host}:#{@port}", :error => e.class, :message => e.message
      end
    end

    # input-mixin
    class FetchRequest
      METHODS = [:event, :sweep]
      TAG_TYPES = ['query_name', 'field', 'string']

      attr_accessor :method, :target, :interval, :tag_generator, :tag_prefix
      attr_accessor :time

      def initialize(method, target, interval, tag_type, tag_arg, tag_prefix)
        raise ArgumentError, "unknown method '#{method}'" unless METHODS.include?(method.to_sym)

        @method = method.to_sym
        @target = target
        @interval = interval.to_i

        raise ArgumentError, "unknown tag type specifier '#{tag_type}'" unless TAG_TYPES.include?(tag_type.to_s)
        raw_tag_prefix = tag_prefix.to_s
        if (! raw_tag_prefix.empty?) && (! raw_tag_prefix.end_with?('.')) # tag_prefix specified, and ends without dot
          raw_tag_prefix += '.'
        end

        @tag_generator = case tag_type.to_s
                         when 'query_name' then lambda{|query_name,record| raw_tag_prefix + query_name}
                         when 'field'      then lambda{|query_name,record| raw_tag_prefix + record[tag_arg]}
                         when 'string'     then lambda{|query_name,record| raw_tag_prefix + tag_arg}
                         else
                           raise "bug"
                         end
        @time = Time.now + 1 # should be fetched soon ( 1sec later )
      end

      def <=>(other)
        self.time <=> other.time
      end

      def next!
        @time = Time.now + @interval
      end

      # returns hash: { tag => [[time, record], ...], ... }
      def fetch(client)
        # events { query_name => [[time, record], ...], ... }
        events = case @method
                 when :event then event(client)
                 when :sweep then sweep(client)
                 else
                   raise "BUG: unknown method: #{@method}"
                 end

        output = {}

        events.keys.each do |query_name|
          events[query_name].each do |time, record|
            tag = @tag_generator.call(query_name, record)
            output[tag] ||= []
            output[tag] << [time, record]
          end
        end

        output
      end

      def event(client)
        events = client.event(@target) # [[time(int from epoch), event], ...]
        {@target => events}
      end

      def sweep(client)
        client.sweep(@target) # {query_name => event_array, ...}
      end
    end

    # input-mixin
    def insert_fetch_queue(request)
      @mutex.synchronize do
        request.next! if request.time < Time.now
        # if @fetch_queue.size > 0
        #   next_pos = @fetch_queue.bsearch{|req| req.time > request.time}
        #   @fetch_queue.insert(next_pos, request)
        # else
        #   @fetch_queue.push(request)
        # end
        @fetch_queue.push(request)
        @fetch_queue.sort!
      end
    rescue => e
      $log.error "unknown log encountered", :error_class => e.class, :message => e.message
    end
  end
end
