#!/usr/bin/env ruby

require 'eventmachine'
$: << File.dirname(__FILE__) + '/../lib'
require 'em/dns_resolver'

if ARGV.size == 0
  puts "Usage: #{$0} <resource type> <domain> [domain] [domain] [domain] [...]"
  exit
end

resource = ARGV[0]
hosts = ARGV[1..-1]
pending = hosts.size

EM.run {
  hosts.each do |host|
    df = EM::DnsResolver.resolve(host, eval("Resolv::DNS::Resource::IN::#{resource.upcase}"))
    df.callback { |a|
      p host => a
      pending -= 1
      EM.stop if pending == 0
    }
    df.errback { |*a|
      puts "Cannot resolve #{host}: #{a.inspect}"
      pending -= 1
      EM.stop if pending == 0
    }
  end
}
