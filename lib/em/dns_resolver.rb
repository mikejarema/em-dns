require 'eventmachine'
require 'resolv'

module EventMachine
  module DnsResolver
    ##
    # Global interface
    ##

    def self.resolve(hostname, options = {})
      Request.new(socket, hostname, options)
    end

    def self.socket
      unless defined?(@socket)
        @socket = DnsSocket.open
      end
      @socket
    end

    #
    # IMPORTANT NOTE ON THE NAMESERVER API BELOW:
    # ===========================================
    # As the nameservers are set on the DnsResolver module, the variable
    # value is the same across all threads. em-dns is a great fit for parallel
    # programming, but beware that this nameserver API is NOT safe for parallel
    # DNS resolution tasks. Consider passing in {:nameservers => [...]} to the
    # DnsResolver.resolve method.
    #

    def self.nameserver=(ns)
      @nameservers = [ns]
    end
    def self.nameserver
      self.nameservers[rand(self.nameservers.size)] # Randomly select a nameserver
    end

    def self.nameservers=(ns)
      @nameservers = ns
    end
    def self.nameservers
      unless defined?(@nameservers)
        @nameservers = []
        IO::readlines('/etc/resolv.conf').each do |line|
          if line =~ /^nameserver (.+)$/
            @nameservers << $1.split(/\s+/).first
          end
        end
      end
      @nameservers
    end

    ##
    # Socket stuff
    ##

    class RequestIdAlreadyUsed < RuntimeError
    end

    class DnsSocket < EM::Connection
      def self.open
        EM::open_datagram_socket('0.0.0.0', 0, self)
      end
      def post_init
        @requests = {}
        EM.add_periodic_timer(0.1, &method(:tick))
      end
      # Periodically called each second to fire request retries
      def tick
        @requests.each do |id,req|
          req.tick
        end
      end
      def register_request(id, req)
        if @requests.has_key?(id)
          raise RequestIdAlreadyUsed
        else
          @requests[id] = req
        end
      end
      def send_packet(pkt, nameservers = nil)
        # Random nameserver, if nameservers passed
        nameserver = nameservers ? nameservers[rand(nameservers.length)] : DnsResolver.nameserver
        send_datagram(pkt, nameserver, 53)
      end
      # Decodes the packet, looks for the request and passes the
      # response over to the requester
      def receive_data(data)
        msg = nil
        begin
          msg = Resolv::DNS::Message.decode data
        rescue
        else
          req = @requests[msg.id]
          if req
            @requests.delete(msg.id)
            req.receive_answer(msg)
          end
        end
      end
    end

    ##
    # Request
    ##

    class Request
      include Deferrable
      attr_accessor :retry_interval
      attr_accessor :max_tries
      def initialize(socket, hostname, options = {})
        @socket = socket
        @hostname = hostname
        @tries = 0
        @last_send = Time.at(0)
        @retry_interval = 3
        @max_tries = 10

        # options parameters (all optional, defaults explicitly listed)
        @resource =    options[:resource]     ||  Resolv::DNS::Resource::IN::A
        @nameservers = options[:nameservers]  ||  nil

        EM.next_tick { tick }
      end
      def tick
        # Break early if nothing to do, retry interval is somewhat randomized
        # to avoid stacking a ton of simultaneous retries.
        return if @last_send + @retry_interval * rand > Time.now

        if @tries < @max_tries
          send
        else
          fail 'retries exceeded'
        end
      end
      # Called by DnsSocket#receive_data
      def receive_answer(msg)
        addrs = []
        msg.each_answer do |name,ttl,data|
          if @resource.nil?
            if data.kind_of?(Resolv::DNS::Resource::IN::A) ||
                data.kind_of?(Resolv::DNS::Resource::IN::AAAA)
              addrs << data.address.to_s
            end
          elsif data.kind_of?(@resource)
            addrs << data
          end
        end
        if addrs.empty?
          fail "rcode=#{msg.rcode}"
        else
          succeed addrs
        end
      end
      private
      def send
        @socket.send_packet(packet.encode, @nameservers)
        @tries += 1
        @last_send = Time.now
      end
      def id
        begin
          @id = rand(65535)
          @socket.register_request(@id, self)
        rescue RequestIdAlreadyUsed
          retry
        end unless defined?(@id)

        @id
      end
      def packet
        msg = Resolv::DNS::Message.new
        msg.id = id
        msg.rd = 1
        msg.add_question @hostname, @resource
        msg
      end
    end
  end
end
