# -*- coding: utf-8 -*-
#
#
# Author:  Michael 'entropie' Trommer <mictro@gmail.com>
#

require "rubygems"
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


    class Receipt < Struct.new(:request, :watcher)

      RECEIPT_ENDPOINT = "https://api.pushover.net/1/receipts/%s.json?token=#{PUSHOVER_APP_TOKEN}"

      def url
        URI.parse(RECEIPT_ENDPOINT % request.result["receipt"])
      end

      def get
        r = ''

        res = Net::HTTP.new(url.host, url.port)
        res.use_ssl = true
        res.verify_mode = OpenSSL::SSL::VERIFY_NONE
        res.start{|http|
          r = JSON.parse(http.request( Net::HTTP::Get.new(url.request_uri) ).body)
        }
        r
      end

      def acknowledged?
        get["acknowledged"] == 1
      end
    end

    def self.receipts
      @@receipts ||= []
    end

    def self.receipts_include?(req)
      not Api.receipts.select{|r| r.watcher == req }.empty?
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
                     message]

                    )
      end
    end

    def submit(cls)
      if Api.receipts_include?(cls)
        puts "    - not sending message because acknowledgment is pending"
        return false
      end

      res = Net::HTTP.start(ENDPOINT_URL.host, ENDPOINT_URL.port) {|http|
        http.request(data)
      }
      if priority == 2
        @result = JSON.parse(res.body)
        Api.receipts << Receipt.new(self, cls)
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
    attr_accessor :title, :message, :timeout, :delay, :priority, :expire, :retry, :custom, :sound

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

    def priority
      @priority || DEFAULT_PRIORITY
    end

    def retry
      @retry || 5*60
    end

    def initialize(args)
      args.each do |k, v|
        self.send("#{k}=", v)
      end
    end

    def test
      str = proc { "  > testing #{title} ... %s" }
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
      puts str.call % "!!! failed; [#{$!} #{caller}]"
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

    PUSHOVER_VALID_KEYS = [:priority, :url, :url_title, :expire, :retry, :sound, :priority]

    def pushover_hash
      def_hash = { }
      def_hash.merge!(:retry => self.send(:retry), :expire => expire, :priority => priority)
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

    def self.send_message(cls, msghsh)
      api = Api.new(msghsh.delete(:title))
      msghsh.each do |k, v|
        api.send("#{k}=", v)
      end
      api.submit(cls)
    end

    def self.run
      @runner = []
      spooler.each do |s|

        puts "register: #{PP.pp(s, '').gsub("\n", "")}"

        @runner << Thread.new do
          while true
            hsh = { }
            if not s.test
              send_message(s, s.pushover_hash.merge(:title => s.title, :message => s.to_msg))
            end
            sleep s.delay
          end
        end
      end

      puts "", ">>> Running <<<", ""

      @runner.each { |r| r.join }
    end
  end

  class Receipt < Watcher
    def receipts
      Api.receipts
    end

    def run_test
      receipts.reject! do |rec|
        if rec.acknowledged?
          puts "  > deleting #{rec}"
          true
        end
      end
      true
    end

    def message
      "uh #{$!}"
    end

    def title
      "Rcpt(#{receipts.size})"
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
      "#{@message}"
    end
  end


  #STDOUT.sync = true

end


if __FILE__ == $0

  include RushOver

  Thread.abort_on_exception = true

  Watcher::add(Receipt, :delay => 50)
  
  Watcher::add(HTTPWatch, :url => "dogitright.de",  :timeout => 10, :url_title => "TOFU", :timeout => 5, :priority => 2, :delay => 60, :retry => 60*5)
  Watcher::add(HTTPWatch, :url => "mogulcloud.com", :timeout => 10, :priority => 2, :url_title => "MC", :timeout => 10, :sound => :spacealarm, :retry => 60*5)
  Watcher::add(HTTPWatch, :url => "gasthof-albrechtshain.de", :timeout => 10, :priority => 2, :url_title => "MIKE", :timeout => 5, :sound => :spacealarm, :retry => 60*5)

  # check memory of host
  Watcher::add(Custom,    :maxSwap => 20, :maxMem => 60, :delay => 60, :priority => 2, :title => "Mem", :custom =>
               proc { |c|
                 interesting_fields = %w'MemFree MemTotal SwapTotal SwapFree'
                 meminfo = Hash[*File.open("/proc/meminfo").readlines.map{|line| line.gsub(/ kB$/, '').split(":").map{|w| w.strip} }.flatten]
                 mf, mt = meminfo['MemFree'].to_i, meminfo['MemTotal'].to_i
                 sf, st = meminfo['Swapree'].to_i, meminfo['SwapTotal'].to_i

                 perc = proc{|a,b| (((a.to_f + 0.01)/(b + 0.01))*100).round }
                 c.data[:mem], c.data[:swap] = perc.call(mf,mt), perc.call(sf,st)

                 if c.data[:mem] > c.maxMem or (c.data[:swap] > c.maxSwap && c.data[:swap] < 100)
                   c.message = "memory value exceeded threshold [#{c.maxMem}/#{c.maxSwap} -- %s Mem / %s Swap" % [c.data[:mem], c.data[:swap]]
                   false
                 else
                   #c.message = "lala"
                   true
                 end
               })

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
