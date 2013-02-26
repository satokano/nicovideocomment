# -*- coding: utf-8 -*-

#
# = ニコニコ生放送のコメントを、collector.rbからZeroMQ経由で受け取り（さらにバックエンドに投入する）
# Author:: Satoshi OKANO
# Copyright:: Copyright 2011-2012 Satoshi OKANO
# License:: MIT
#

require 'rubygems'
require 'json'
require 'logger'
require 'mongo'
require 'zmq'

Signal.trap(:INT) {
  return
}

begin
  zmq_context = ZMQ::Context.new
  zmq_sock = zmq_context.socket(ZMQ::SUB)
  zmq_sock.connect("tcp://127.0.0.1:5000")
  zmq_sock.setsockopt(ZMQ::SUBSCRIBE, "") # 全部受ける
  
  # zmq_sockの操作の前後で使う
  #zmq_semaphore = Mutex.new
rescue => exception
  puts "**** ZMQ new/bind error: #{exception}\n"
  alog.error "ZMQ new/bind error: #{exception}"
  # zmq_context = nil
  return -1
end

begin
  mg_connection = Mongo::Connection.new("localhost", 27017)
rescue => exception
  puts "*** Mongo connection.new error: #{exception}\n"
  alog.error "Mongo connection.new error: #{exception}"
  # mg_connection = nil
  return -1
end

begin
  mg_db = mg_connection.db("niconico_comment")
  mg_collection = mg_db.collection("ph0")
rescue => exception
  puts "*** Mongo open DB or Collection error: #{exception}\n"
  alog.error "Mongo open DB or Collection error: #{exception}"
  return -1
end

while tag_message = zmq_sock.recv
  # tag_message.force_encoding("UTF-8") # 不要？
  message_json = tag_message.scan(/allmsg (.+)/).first.first
  message_flat = JSON.parse(message_json)
  id = mg_collection.insert(message_flat)
  #puts message_flat["text"]
end

# TODO: Close ZeroMQ / Mongo

