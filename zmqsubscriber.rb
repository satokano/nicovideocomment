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
require 'zmq'

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
  zmq_context = nil
end

while tag_message = zmq_sock.recv
  # tag_message.force_encoding("UTF-8") # 不要？
  message = tag_message.scan(/allmsg (.+)/).first.first
  flat = JSON.parse(message)
  puts flat["text"]
end