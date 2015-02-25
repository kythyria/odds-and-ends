#!/usr/bin/env ruby
# encoding: UTF-8

# (c) 2015 Kythyria Tieran
#
# Unlimited redistribution and modification of this document is allowed
# provided that the above copyright notice and this permission notice
# remains in tact.

# You need the 'eventmachine' and 'yajl-ruby' gems.

HELPTEXT = <<HELP
Trivial IRC proxy and JSON converter.

This uses the STARTJSON command to signal that the remainder of the stream in
that direction is JSON. No capability negotiation is done to determine if this
will work.

Subcommands:

  parser <to> <from>
    Convert between serialisations. "rfc1459" and "json" are the valid values
    of the arguments.

  simple <listenhost> <listenport> <connecthost> <connectport>
    Be a simple IRC proxy. Listen on the host and port given by the first two
    arguments. Any connections are relayed to the host and port given by the
    last two. If STARTJSON is used, respond in kind.
    
  startjson <listenhost> <listenport> <connecthost> <connectport>
    Like simple, except start the connection to upstream with STARTJSON.

Both simple and startjson print to stderr the strings read and written. "<<"
for a write, ">>" for a read. C for clientwards, S for serverwards.
HELP

require 'yajl'
require 'eventmachine'
#require 'pry'

# Represents a message regardless of wire format.
# The command is an integer for numerics, a lowercase Symbol otherwise.
# The tags are a hash of symbol => string.
# The args are an array of string.
class IrcMessage
  
  # Hash arguments get merged, coerced to symbol=>string, and used as the tags. The remainder is a sequence
  # of strings, first is sender if it starts with colon. After that is the verb, which is turned to an integer
  # or a lowercase symbol.
  def initialize(*args)
    tags = args.select{|i| i.is_a? Hash}.reduce({}){|m,v| m.merge! v}
    @tags = tags.map{|k,v| [k.to_s.to_sym, v.to_s]}.to_h
    
    argv = args.reject{|i| i.is_a? Hash}
    
    senderstr = argv.shift
    if senderstr && (senderstr.start_with? ":" || /[!@\.]/ === senderstr)
      this.sender = senderstr[1..-1]
    else
      argv.unshift senderstr
    end
    
    verb = argv.shift
    if verb
      command = verb
    end
    
    args = argv
  end
  
  def command
    return @command
  end
  
  def command=(value)
    @command = value.to_s.downcase
    if value.respond_to? :to_i
      numeric = value.to_i
      if numeric < 1000 && numeric > 0
        @command = numeric
      end
    end
    if @command.respond_to? :to_sym
      @command = @command.to_sym
    end
  end
  
  def args
    return @args
  end
  
  def args=(value)
    unless value.is_a? Array
      value = value.to_a
    end
    
    @args = value.map{|i| i.to_s}
  end
  
  def tags
    return @tags
  end
  
  def tags=(value)
    unless value
      @tags = {}
    end
    @tags = value.to_h.map{|k,v| [k.to_s.to_sym, v.to_s]}.to_h
  end
  
  def sender
    return @sender
  end
  
  def sender=(value)
    @sender = value.to_s
  end
end

class Rfc1459Parser
  attr_accessor :on_message
  
  def initialize
    @buffer = ""
    @lines = []
  end
  
  def add_data(text)
    @buffer << text
    while i = @buffer.slice!(/([^\r\n])*\r?\n/)
      @lines << i
    end
    
    until @lines.empty?
      i = @lines.shift
      on_message.call(parse(i))
    end
  end
  
  def buffer
    @buffer
  end
  
  def parse(line)
    origline = line
    line = line.dup
    
    msg = IrcMessage.new
    
    if line.end_with? "\n"
      line = line[0..-2]
    end
    
    if line.end_with? "\r"
      line = line[0..-2]
    end
    
    if tagstr = line.slice!(/^ *@[^ ]* /)
      tagstr[1..-2].split(";").each do |i|
        m = /^([^=]*)(?:=(.*))?$/.match(i)
        msg.tags[m[1].downcase.to_sym] = m[2] ? m[2] : true
      end
    end
    
    if sender = line.slice!(/^ *:[^ ]* +/)
      if sender.length >=3
        msg.sender = sender[1..-2]
      end
    end
    
    parts = line.split(" :",2)
    argv = parts.shift.split(" ")
    argv << parts.pop unless parts.empty?
    
    msg.command = argv.shift
    msg.args = argv
    
    return msg
  end
  
  # TODO: Deal correctly with too-long messsages.
  def serialize(message)
    buf = ""
    tags = ""
    if message.tags.count > 0
      tags = "@" + message.tags.map{|k,v| "#{k}=#{v}"}.join(";") + " "
    end
    
    if message.sender && message.sender.length > 0
      buf << ":" << message.sender << " "
    end
    
    commandstr = message.command.to_s
    if commandstr.start_with? "ctcp_"
      buf << commandstr[5..-1].upcase
    else
      buf << commandstr.upcase
    end
    
    arglist = message.args.dup
    
    last = arglist.pop
    if (last && (last != "")) && last.include?(" ")
      last = ":" + last
    end
    arglist.push(last)
    
    buf << " " << arglist.join(" ")
    tags + buf + "\r\n"
  end
end

#############
# This parses NEARLY DarthGandalf's proposal. Namely,
# {tags: {}, sender: ""|null, verb: "", params: ["", ...]}
# where tags is a hash, sender a string or nil, verb string or int, and args are strings.
#############
class JsonParser
  attr_accessor :on_message
  
  def initialize
    @parser = Yajl::Parser.new(:symbolize_keys => true)
    @parser.on_parse_complete = method(:parse_and_yield)
  end
  
  def add_data(text)
    @parser << text
  end
  
  def parse_and_yield(json)
    on_message.call(parse(json))
  end
  
  def parse(json)
    msg = IrcMessage.new
    msg.tags = json[:tags]
    msg.sender = json[:source]
    msg.command = json[:verb]
    msg.args = json[:params]
    msg
  end
  
  def serialize(msg)
    out = {tags: msg.tags, source: msg.sender, verb: msg.command, params: msg.args}
    Yajl::Encoder.encode(out)
  end
end

class IrcConnection < EventMachine::Connection
  attr_accessor :disconnect_handler
  
  def initialize(args={})
    super
    @send_format = :rfc1459
    @recv_format = :rfc1459
    disconnect_handler = args[:disconnect_handler]
    receive_message = args[:receive_message] || proc{|msg| }
    @want_json = args[:start_json]
  end
  
  def post_init
    @parser = Rfc1459Parser.new
    @parser.on_message = method(:receive_message_internal)
    @serialiser = Rfc1459Parser.new
    if @want_json
      enter_json_send_mode
    end
  end
  
  def receive_data(data)
    # This sanitises the data, otherwise if we do anything with it errors will be thrown.
    text = data.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
    
    @parser.add_data(text)
  end
  
  #TODO: Flood control.
  def send_message(msg)
    send_data(@serialiser.serialize(msg))
  end
  
  def on_otherside_disconnect(reason)
    msg = IrcMessage.new("")
  end
  
  def enter_json_send_mode
    return if @send_format == :json
    
    send_data("STARTJSON\r\n")
    @serialiser = JsonParser.new
    @send_format = :json
  end
  
  def enter_json_receive_mode
    return if @recv_format == :json
    
    newparse = JsonParser.new
    newparse.on_message = @parser.on_message
    newparse.add_data(@parser.buffer)
    @parser = newparse
    @recv_format = :json
    
    enter_json_send_mode
  end
  
  def receive_message_internal(msg)
    if msg.command == :startjson
      enter_json_receive_mode
      return
    end
    
    receive_message(msg)
  end
  
  def receive_message(msg)
    
  end
end

class ClientConnection < IrcConnection
  def initialize(args={})
    super(args)
    server_options = (args[:server_options] || {}).dup
    server_options[:disconnect_handler] = method(:server_disconnected)
    server_options[:downstream] = self
    server_options[:start_json] = args[:server_json]
    @upstream = EventMachine.connect(args[:server], args[:port], ServerConnection, server_options)
  end
  
  def receive_data(data)
    puts("C >> " + data.inspect)
    super(data)
  end
  
  def receive_message(msg)
    @upstream.send_message(msg)
    if msg.command == :quit
      @upstream.close_connection_after_writing
      self.close_connection_after_writing
    end
  end
  
  def send_data(data)
    puts("C << " + data.inspect)
    super(data)
  end
  
  def server_disconnected(*args)
    
  end
end

class ServerConnection < IrcConnection
  def initialize(args={})
    super(args)
    @disconnect_handler = args[:disconnect_handler]
    @downstream = args[:downstream]
  end
  
  def receive_data(data)
    puts("S >> " + data.inspect)
    super(data)
  end
  
  def send_data(data)
    puts("S << " + data.inspect)
    super(data)
  end
  
  def receive_message(msg)
    @downstream.send_message(msg)
  end
  
  def unbind
    @downstream.close_connection_after_writing
  end
end

if ARGV[0] == "parser"
  if ARGV[1] == "rfc1459"
    parser = Rfc1459Parser.new
  else
    parser = JsonParser.new
  end
  
  if ARGV[2] == "rfc1459"
    writer = Rfc1459Parser.new
  else
    writer = JsonParser.new
  end
    
  parser.on_message = proc { |msg| #binding.pry ;
                            puts writer.serialize(msg) }
  while true
    parser.add_data($stdin.gets)
  end
 
elsif ARGV[0] == "simple"
  EM.run do
    host, port = ARGV[1], ARGV[2].to_i
    EM.start_server host, port, ClientConnection, {server: ARGV[3], port: ARGV[4].to_i}
  end
elsif ARGV[0] == "startjson"
  EM.run do
    host, port = ARGV[1], ARGV[2].to_i
    EM.start_server host, port, ClientConnection, {server: ARGV[3], port: ARGV[4].to_i, server_json: true}
  end
else
  puts HELPTEXT
end
