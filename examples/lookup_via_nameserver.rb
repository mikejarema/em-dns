#!/usr/bin/env ruby

require 'eventmachine'
$: << File.dirname(__FILE__) + '/../lib'
require 'em/dns_resolver'

if ARGV.size == 0
  puts "Usage: #{$0} <host> @<nameserver>"
  exit
end

host =       ARGV[0]
nameserver = ARGV[1].gsub(/^@/, '')

EM.run {
  df = EM::DnsResolver.resolve(host, :nameservers => [nameserver])
  df.callback { |a|
    p host => a
    EM.stop
  }
  df.errback { |*a|
    puts "Cannot resolve #{host} via #{nameserver}: #{a.inspect}"
    EM.stop
  }
}
