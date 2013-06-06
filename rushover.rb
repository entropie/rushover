# -*- coding: utf-8 -*-
#
#
# Author:  Michael 'entropie' Trommer <mictro@gmail.com>
#

require "net/https"
require "json"
require "timeout"
require "pp"
require "yaml"

module RushOver

  class Api

    creds = YAML::load_file(File.expand_path("~/.rushover.yaml"))

    PUSHOVER_USER_TOKEN = creds[:pushover_user_token]
    PUSHOVER_APP_TOKEN  = creds[:pushover_app_token]


    class Receipt < Struct.new(:request, :result)
      RECEIPT_ENDPOINT = "http://api.pushover.net/1/receipts/%s.json?token=#{PUSHOVER_APP_TOKEN}"
    end

    def self.receipts
      @@receipts = []
    end


    ENDPOINT_URL        = URI.parse("http://api.pushover.net/1/messages.json")

    DATA_FIELDS         = [ :result, :message, :url, :title,
                            :url_title, :priority, :timestamp,
                            :device, :expire, :retry, :device,
                            :sound
                          ]

    attr_accessor *DATA_FIELDS

    def initialize(message = nil, &blk)
      @message = message
      yield self if block_given?
    end

    def data(hash = { })
      request = Net::HTTP::Post.new(ENDPOINT_URL.path)
      data = {
        :token   => PUSHOVER_APP_TOKEN,
        :user    => PUSHOVER_USER_TOKEN,
        :message => message
      }

      DATA_FIELDS.each do |m|
        next if m == :message and not message.nil?
        value = instance_variable_get("@#{m}")
        data.merge!(m => value) if value
      end
      log data.reject{ |d,v| [:token, :user].include?(d) }
      request.set_form_data(data)
      request
    end

    def log(*args)
      t = Time.now
      args.each do |a|
        Kernel.puts(">>> Submitting(%s-%s): %s" %
                    [t.strftime("%F"),
                     t.strftime("%T"),
                     PP.pp(a, '').gsub("\n", "").strip]
                    )
      end
    end

    def submit
      res = Net::HTTP.start(ENDPOINT_URL.host, ENDPOINT_URL.port) {|http|
        http.request(data)
      }

      if priority == 2
        @result = JSON.parse(res.body).map
        Api.receipts << Receipt.new(self, @result)
      end
    end
  end

  class Watcher

    def hostname
      @hostname ||= `hostname -f`.strip
    end

    TIMEOUT = 3
    DELAY   = 60

    DEFAULT_PRIORITY = 0

    attr_reader :api
    attr_accessor :title, :message, :timeout, :delay, :priority, :last_state, :expire, :retry, :custom, :sound

    def last_state
      @last_state
    end

    def self.watcher
      @watcher ||= []
    end

    def self.inherited(o)
      watcher << o
    end

    def self.spooler
      @spooler ||= []
    end

    def self.add(watcher, arg)
      spooler << watcher.new(arg)
    end

    def timeout
      @timeout || TIMEOUT
    end

    def delay
      @delay || DELAY
    end

    def expire
      @expire || 3600*24
    end

    def retry
      @retry || 30*60
    end

    def initialize(args)
      args.each do |k, v|
        self.send("#{k}=", v)
      end
      @last_state = true
    end

    def test
      str = proc { "testing #{title} ... %s" }
      state = false
      status = Timeout::timeout(timeout) {
        state = run_test
      }
      state
      raise message unless state
    rescue Timeout::Error
      puts str.call % "failed; [#{to_msg}]"
      false
    rescue
      puts str.call % "!!! failed; [#{$!}]"
      false
    else
      puts str.call % "passed; waiting #{delay} seconds"
      true
    ensure
    end

    def to_s
      a = self.instance_variables.inject({ }) do |r, iv|
        r[iv] = instance_variable_get(iv)
        r
      end
      "#{PP.pp(a, '').strip}"
    end

    PUSHOVER_VALID_KEYS = [:priority, :url, :url_title, :expire, :retry, :sound]

    def pushover_hash
      def_hash = { }
      def_hash.merge!(:retry => self.send(:retry), :expire => expire)
      a = self.instance_variables.inject( def_hash ) do |r, iv|
        k = iv[1..-1].to_sym
        if PUSHOVER_VALID_KEYS.include?(k)
          r[k] = instance_variable_get(iv.to_s)
        end
        r
      end
      a
    end

    def message(type = :warn)
      case type
      when nil
      else
        super
      end
    end

    def to_msg
      "[%s]: %s" % [hostname, message]
    end

    def self.send_message(msghsh)
      api = Api.new(msghsh.delete(:title))
      msghsh.each do |k, v|
        api.send("#{k}=", v)
      end
      api.submit
    end

    def self.run
      @runner = []
      spooler.each do |s|

        puts "register: #{PP.pp(s, '').gsub("\n", "")}"

        @runner << Thread.new do
          while true
            hsh = { }

            if not s.test
              if s.last_state
                send_message(s.pushover_hash.merge(:title => s.title, :message => s.to_msg))
              else
                puts "not sending message, already done"
              end
              s.last_state = false
            else
              s.last_state = true
            end
            sleep s.delay
          end
        end
      end

      puts "", ">>> Running <<<", ""

      @runner.each { |r| r.join }
    end
  end

  class HTTPWatch < Watcher
    attr_accessor :url, :url_title

    def run_test
      Net::HTTP.start(url) do |http|
        http.head('/')
      end
      true
    end

    def title
      "HTTPWatch(#{url_title || url})"
    end

    def message
      "%s did not respond in %s seconds" % [url, timeout]
    end
  end

  class Custom < Watcher

    attr_accessor :maxMem, :maxSwap, :data

    def initialize(*args)
      @data = {}
      super(*args)
    end

    def run_test
      @custom.call(self)
    end

    def message
      "memory value exceeded threshold [#{maxMem}/#{maxSwap} -- %s Mem / %s Swap" % [data[:mem], data[:swap]]
    end
  end


  #STDOUT.sync = true

end


if __FILE__ == $0

  include RushOver

  Thread.abort_on_exception = true

  Watcher::add(HTTPWatch, :url => "dogitright.de",  :timeout => 10, :priority => 2, :url_title => "DIR", :timeout => 0.01)
  #Watcher::add(HTTPWatch, :url => "mogulcloud.com", :timeout => 10, :priority => 2, :url_title => "mogulcloud", :timeout => 1, :sound => :spacealarm)

  # check memory of host
  # Watcher::add(Custom,    :maxSwap => 20, :maxMem => 1, :delay => 60, :priority => 2, :title => "Mem", :custom =>
  #              proc { |c|
  #                interesting_fields = %w'MemFree MemTotal SwapTotal SwapFree'
  #                meminfo = Hash[*File.open("/proc/meminfo").readlines.map{|line| line.gsub(/ kB$/, '').split(":").map{|w| w.strip} }.flatten]
  #                mf, mt = meminfo['MemFree'].to_i, meminfo['MemTotal'].to_i
  #                sf, st = meminfo['Swapree'].to_i, meminfo['SwapTotal'].to_i

  #                perc = proc{|a,b| (((a.to_f + 0.01)/(b + 0.01))*100).round }
  #                c.data[:mem], c.data[:swap] = perc.call(mf,mt), perc.call(sf,st)

  #                if c.data[:mem] > c.maxMem or (c.data[:swap] > c.maxSwap && s < 100)
  #                  c.message = "Mem: %s%%  Swap: %s%%" % [ c.data[:mem], c.data[:swap] ]
  #                  false
  #                else
  #                  true
  #                end
  #              })
  

  Watcher.run
  
end




=begin
Local Variables:
  mode:ruby
  fill-column:70
  indent-tabs-mode:nil
  ruby-indent-level:2
End:
=end
