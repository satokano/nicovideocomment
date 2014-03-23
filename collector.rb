# -*- coding: utf-8 -*-

#
# = ニコニコ生放送のコメントを収集する
# Author:: Satoshi OKANO
# Copyright:: Copyright 2011-2014 Satoshi OKANO
# License:: MIT
#

require 'rubygems'
require 'cgi'
require 'mechanize'
require 'kconv'
require 'logger'
require 'rexml/document'
require 'psych'
require 'json'
require 'socket'
require 'thread'
require 'yaml'
require 'ffi-rzmq'

def xpathvalue(xmldoc, path)
  temp = REXML::XPath.first(xmldoc, path)
  if temp.nil?
    ""
  else
    temp.value
  end
end

puts "[init] loading config..."
config = YAML.load_file("config.yaml")
# === configure
mycommlist = config["mycommlist"]
login_mail = config["login_mail"]
login_password = config["login_password"]
alert_log = "./log/alert.log"
comment_log = "./log/comment.log"
debug_log = "./log/debug.log"
gc_log = "./log/gc.log"
gc_log_enabled = config["gc_log_enabled"] || false
gc_log_interval = 1 # second
children = config["children"] || 50
zmq_enabled = config["zmq_enabled"]
# === configure end


#### ログ出力 4種類
# alert.log (alog): アラートサーバから配信される、枠開始情報を記録＋collector.rbの稼働確認用ログ
# comment.log (clog): 収集したコメントを記録するログ
# debug.log (dlog): デバッグ用詳細情報。稼働確認を越えた詳細情報を知りたいときにこっちに出すことにする。
# gc.log (gclog): GC情報。Ruby 1.9.3のGC.statの内容を1秒ごとに出力。
alog = Logger.new(alert_log, 2)
alog.level = Logger::INFO
clog = Logger.new(comment_log, 100)
clog.level = Logger::INFO
dlog = Logger.new(debug_log, 2)
dlog.level = Logger::DEBUG
gclog = Logger.new(gc_log, 10)
gclog.level = Logger::DEBUG

### GC log start
if gc_log_enabled then
  gclog_thread = Thread.new() do ||
    while true
      gclog.info(GC.stat)
      sleep gc_log_interval
    end
  end
end

#### ZeroMQ Context作成。これはプロセス単位で1個だけ。
# Context自体はthread-safeである。
# http://api.zeromq.org/2-2:zmq-init
# 
# socketは、thread-safe"ではない"。
# http://api.zeromq.org/2-2:zmq-socket
#
# なので（？）zmq_sockのまわりで同期化して使うことにするけど・・・遅いか？
if zmq_enabled then
  begin
    zmq_context = ZMQ::Context.new
    zmq_sock = zmq_context.socket(ZMQ::PUB)
    zmq_sock.bind("tcp://127.0.0.1:5000")
    
    # zmq_sockの操作の前後で使う
    zmq_semaphore = Mutex.new
  rescue => exception
    puts "**** ZMQ new/bind error: #{exception}\n"
    alog.error "ZMQ new/bind error: #{exception}"
    zmq_context = nil
  end
end

comment_threads = Hash.new()


#### Mechanizeを作成して、通信を開始する。
# Chrome 33.0.1750.154m Windows7 64bitのUser Agentは以下
# Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/33.0.1750.154 Safari/537.36
agent = Mechanize.new
agent.user_agent = "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/33.0.1750.154 Safari/537.36"
agent.keep_alive = false # 間欠的にAPIリクエストするだけなので無効の方がよいのではないか
# agent.idle_timeout = 5 # defaultのまま
agent.open_timeout = 5
agent.read_timeout = 5

#### Cookie準備
print "[cookie_get] https login secure.nicolive.jp\n"
begin
  agent.post('https://secure.nicovideo.jp/secure/login?site=nicolive', {:next_url => "", :mail => login_mail, :password => login_password})
rescue Mechanize::ResponseCodeError => rce
  puts "ログインエラー: #{rce.response_code}\n"
  p agent.page.body
  abort
rescue => ex
  puts "ログインエラー:\n"
  puts ex.to_s
  abort
end

#### ログインしてticket取得
puts "[login] nicolive_antenna"
begin
  agent.post('https://secure.nicovideo.jp/secure/login?site=nicolive_antenna', {:mail => login_mail, :password => login_password})
rescue Mechanize::ResponseCodeError => rce
  abort "ログインエラー: #{rce.response_code}\n"
rescue => ex
  puts "ログインエラー:\n"
  puts ex.to_s
  abort
end

agent.cookie_jar.save_as('mech_cookie.yaml')

xmldoc = REXML::Document.new agent.page.body

if REXML::XPath.first(xmldoc, "//nicovideo_user_response/attribute::status").value !~ /ok/ then
  abort "ログインエラー(002)\n"
end
ticketstr = REXML::XPath.first(xmldoc, "//ticket").text

#### getalertstatus まずはアラートサーバのIP、ポートをもらってくる
begin
  agent.post('http://live.nicovideo.jp/api/getalertstatus', {:ticket => ticketstr})
rescue Mechanize::ResponseCodeError => rce
  abort "getalertstatusエラー: #{rce.response_code}\n"
rescue => ex
  puts "getalertstatusエラー:\n"
  puts ex.to_s
  abort
end

xmldoc = REXML::Document.new agent.page.body
if REXML::XPath.first(xmldoc, "//getalertstatus/attribute::status").value !~ /ok/ then
  p agent.page.body
  abort "getalertstatusエラー(004)\n"
end

REXML::XPath.each(xmldoc, "//community_id") {|ele|
  mycommlist.push ele.text
}

print "[getalertstatus] OK\n"
alertserver = REXML::XPath.first(xmldoc, "/getalertstatus/ms/addr").text
alertport = REXML::XPath.first(xmldoc, "/getalertstatus/ms/port").text
alertthread = REXML::XPath.first(xmldoc, "/getalertstatus/ms/thread").text
print("[getalertstatus] connect to: #{alertserver}:#{alertport} thread=#{alertthread}\n")
alog.info("getalertstatus alertserver=#{alertserver} alertport=#{alertport} alertthread=#{alertthread}");

#### アラートサーバへの接続
begin
  sock = TCPSocket.open(alertserver, alertport)
  sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
  # sock.setsockopt(Socket::Option.linger(true, 1)) # close時1秒待ちとするlinger動作
rescue => ex
  sock.close if sock
  alog.error("alertserver TCPSocket open error: #{ex}")
  abort "alertserver TCPSocket open error"
end

sock.print "<thread thread=\"#{alertthread}\" version=\"20061206\" res_from=\"-1\">\0"
sock.each("\0") do |line|
  liveid = ""
  communityid = ""
  ownerid = ""
  
  if line.index("\0") == (line.length - 1) then
    line = line[0..-2]
  end
  
  line.force_encoding("UTF-8")
  
  if line =~ /<chat [^>]+>(\w+),(\w+),(\w+)<\/chat>/ then
    liveid = $1
    communityid = $2
    ownerid = $3
  end
  alog.info(line)
  
  if mycommlist && mycommlist.include?(communityid) then
    alog.warn("**** HIT MYCOMMLIST: #{communityid}")
  end

  if comment_threads.size < children && line =~ /<chat/ && !comment_threads.has_key?(liveid) then
    #### getplayerstatusでコメントサーバのIP,port,threadidを取ってくる
    begin
      agent.get("http://live.nicovideo.jp/api/getplayerstatus?v=lv#{liveid}")
    rescue Mechanize::ResponseCodeError => rce
      alog.error("getplayerstatus error(005)(lv#{liveid})(http #{rce.response_code})")
      next
    rescue => ex
      alog.error("getplayerstatus error(007)(lv#{liveid}): #{ex}")
      dlog.debug(ex.backtrace.join("\n"))
      next
    end

    begin
      xmldoc = REXML::Document.new agent.page.body
    rescue => exp
      puts "REXML::Document.new error, agent.page.body: #{agent.page.body}, Exception: #{exp}\n"
      xmldoc = REXML::Document.new CGI.escape(agent.page.body)
      # ここですでにnextするべきなのか？
    end

    begin
      if REXML::XPath.first(xmldoc, "//getplayerstatus/attribute::status").value !~ /ok/ then
        # コミュ限とか
        # <?xml version="1.0" encoding="utf-8"?>
        # <getplayerstatus status="fail" time="1313947751"><error><code>require_community_member</code></error></getplayerstatus>
        # require_community_member, closed, notlogin, deletedbyuser, unknown
        # TODO: notloginのときは抜けるようにするか？
        gps_error_code = REXML::XPath.first(xmldoc, "//getplayerstatus/error/code").text
        case gps_error_code
        when "require_community_member", "closed", "deletedbyuser"
          # このへんはまあ気にせずともよかろう
          alog.warn "getplayerstatus error(006)(lv#{liveid}): #{gps_error_code}"
        else
          # unknownとかは気にしたい
          alog.error "getplayerstatus error(008)(lv#{liveid}): #{gps_error_code}"
        end

        next # アラートサーバからの次回の受信、つまり sock.each("\0") do |line| の次回に進む
      end
    rescue => exp
      puts "REXML::XPath.first().value error, xmldoc: #{xmldoc}, Exception: #{exp}\n"
      alog.error("REXML::XPath.first().value error, xmldoc: #{xmldoc}, Exception: #{exp}")
      dlog.debug(exp.backtrace.join("\n"))
      next
    end

    #### コメントサーバへ接続
    commentserver = REXML::XPath.first(xmldoc, "/getplayerstatus/ms/addr").text
    commentport = REXML::XPath.first(xmldoc, "/getplayerstatus/ms/port").text
    commentthread = REXML::XPath.first(xmldoc, "/getplayerstatus/ms/thread").text

    # 放送枠ごとにThread生成
    comment_threads[liveid] = Thread.new(liveid, commentserver, commentport, commentthread) do |lid, cserv, cport, cth|
      dlog.debug("#{comment_threads.size}: #{comment_threads.keys.sort}")

      begin
        # TODO: このソケットを集約したい
        sock2 = TCPSocket.open(cserv, cport) # :external_encoding => "UTF-8"
        sock2.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
        # sock2.setsockopt(Socket::Option.linger(true, 1)) # close時1秒待ちとするlinger動作
      rescue => exception
        sock2.close if sock2
        comment_threads.delete(lid)
        alog.error "comment server socket open error (threads#{comment_threads.size}): #{cserv} #{cport} #{exception}"
        dlog.debug(exception.backtrace.join("\n"))
        break # その受信待ちスレッドはあきらめて異常終了扱い、Thread.newを抜ける。breakじゃおかしい？
      end

      alog.info("connect to: #{cserv}:#{cport} thread=#{cth}")

      begin
        #### 最初にこの合図を送信してやる scoresはNG共有のスコアを受け取るため
        sock2.print "<thread thread=\"#{cth}\" version=\"20061206\" res_from=\"-1000\" scores=\"1\"/>\0"
      rescue => exception
        sock2.close if sock2
        comment_threads.delete(lid)
        puts "**** comment server socket print error (threads#{comment_threads.size}): #{cserv} #{cport} #{exception}\n"
        alog.error "comment server socket print error (threads#{comment_threads.size}): #{cserv} #{cport} #{exception}"
        dlog.debug(exception.backtrace.join("\n"))
        break # その受信待ちスレッドはあきらめて異常終了扱い、Thread.newを抜ける。
      end

      begin
        #### 受信待ち
        sock2.each("\0") do |line2|
          if line2.index("\0") == (line2.length - 1) then
            line2 = line2[0..-2]
          end

          line2.force_encoding("UTF-8")

          clog.info line2

          if line2 =~ /chat/ then
            xdoc = REXML::Document.new line2
            message = Hash.new
            message["text"] = REXML::XPath.first(xdoc, "//chat").text
            message["thread"] = xpathvalue(xdoc, "//chat/attribute::thread")
            message["no"] = xpathvalue(xdoc, "//chat/attribute::no")
            #message["vpos"] = xpathvalue(xdoc, "//chat/attribute::vpos")
            #message["date"] = xpathvalue(xdoc, "//chat/attribute::date")
            #message["date_usec"] = xpathvalue(xdoc, "//chat/attribute::date_usec")
            #message["mail"] = xpathvalue(xdoc, "//chat/attribute::mail")
            message["user_id"] = xpathvalue(xdoc, "//chat/attribute::user_id")
            #message["premium"] = xpathvalue(xdoc, "//chat/attribute::premium")
            #message["anonymity"] = xpathvalue(xdoc, "//chat/attribute::anonymity")
            #message["locale"] = xpathvalue(xdoc, "//chat/attribute::locale")
            #message["score"] = xpathvalue(xdoc, "//chat/attribute::score")
            puts "[" + message["thread"] + "] [" + message["no"] + "] [" + message["user_id"] + "] "+ message["text"] + "\n"
            
            # zmq send
            if zmq_enabled then
              begin
                zmq_semaphore.synchronize do # TODO: synchronizeしてたら意味ない？？？
                  zmq_sock.send("allmsg #{message.to_json}") # TODO: jsonとするか、line2をそのまま入れるか、他の形式にするか
                end
              rescue => exception
                puts "**** ZMQ send error: #{exception}\n"
                alog.error "ZMQ send error: #{exception}"
              end
            end
            
          end

          if line2 =~ /\/disconnect/ then
            puts "**** DISCONNECT: #{lid} ****\n"
            alog.info("disconnect: #{lid}")
            # TODO: zmq_sockのclose？
            sock2.close if sock2
            sock2 = nil # ？？
            comment_threads.delete(lid)
            break # その受信待ちスレッドは終了でよいから、sock2.eachを抜けて、Thread.newも抜ける。break
          end
        end # of sock2.each
      rescue => exception
        puts "**** comment server socket read(each) error (threads#{comment_threads.size}): #{cserv} #{cport} #{exception}\n"
        alog.error "comment server socket read(each) error (threads#{comment_threads.size}): #{cserv} #{cport} #{exception}"
        # TODO: zmq_sockのclose？
        sock2.close if sock2
        comment_threads.delete(lid)
      end

    end # of Thread.new() do || ...

  end # of if comment_threads.size < children ...
end
