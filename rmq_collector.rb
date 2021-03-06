# -*- coding: utf-8 -*-

#
# = ニコニコ生放送のコメントを収集する
# Author:: Satoshi OKANO
# Copyright:: Copyright 2011-2016 Satoshi OKANO
# License:: MIT
#

require 'rubygems'
require 'mechanize'
require 'kconv'
require 'logger'
require 'json'
#require 'socket'
#require 'thread'
require 'yaml'
require 'march_hare'
require 'celluloid/current'
require 'celluloid/io'
require 'readline'

# - キューの中身が空の場合にも、subscribeのまま待ち続けて欲しいが、抜けてしまっている。
#   - 正確には、抜けると言うより、subscribeはメッセージが到着したときにそれをハンドルするメソッドを登録するだけで
#     ハンドルする処理自体は非同期に呼ばれる。キューが空の時も実は接続は生きている。プログラム本体が終わらないようにしておけばよいだけ。
#   - Consumers last as long as the channel that they were declared on, or until the client cancels them (unsubscribes).
#     と書いてるので、キャンセルしない限り待ち続けるはず。
#   - March_Hareのマニュアルにあるとおり、subscribeの:blockをtrueにしたときとfalseにしたときで動きが違う。
# - Signal.trap(:INT)でトラップしたあとexitまで行ってるはずなのに、終わってくれない。何かスレッドの内部終了処理みたいなので引っかかってる？
#   - たぶんこれは解決。JRuby固有のシグナル処理の問題。throw Interruptしないといけなかった。
# - set_encodingってもっとキレイな対応策はないのか？
class RmqCollector

  def xpathtext(xmlnode, path)
    @temp = xmlnode.xpath(path)
    if @temp.nil?
      ""
    else
      @temp.text
    end
  end

  def load_config()
    puts "[load_config] loading config..."
    @config = YAML.load_file("config.yaml")

    @mycommlist = @config["mycommlist"]

    @alert_log = "./log/alert.log"
    @comment_log = "./log/comment.log"
    @debug_log = "./log/debug.log"
    @gc_log = "./log/gc.log"
    @gc_log_interval = 1 # second
    @rmq_ip = @config["rmq_ip"]
    @rmq_port = @config["rmq_port"]
    @rmq_routing_key = @config["rmq_routing_key"]
    @children = @config["children"] || 50
    puts "[load_config] done"
  end

  def setup_logger()
    #### ログ出力 4種類
    # alert.log (alog): アラートサーバから配信される、枠開始情報を記録＋collector.rbの稼働確認用ログ
    # comment.log (clog): 収集したコメントを記録するログ
    # debug.log (dlog): デバッグ用詳細情報。稼働確認を越えた詳細情報を知りたいときにこっちに出すことにする。
    # gc.log (gclog): GC情報。Ruby 1.9.3のGC.statの内容を1秒ごとに出力。
    @alog = Logger.new(@alert_log, 2)
    @alog.level = Logger::INFO
    @clog = Logger.new(@comment_log, 100)
    @clog.level = Logger::INFO
    @dlog = Logger.new(@debug_log, 2)
    @dlog.level = Logger::DEBUG
    gclog = Logger.new(@gc_log, 10)
    gclog.level = Logger::DEBUG

    ### GC log start
    if @config["gc_log_enabled"] then
      Thread.new() do ||
        while true
          gclog.info(GC.stat)
          sleep gc_log_interval
        end
      end
    end
  end

  def initialize()
    @comment_threads = Hash.new()
  end

  def setup_mechanize()
    #### Mechanizeを作成して、通信を開始する。
    # Chrome 39.0.2171.95 m Windows7 64bitのUser Agentは以下
    # Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/39.0.2171.95 Safari/537.36
    @agent = Mechanize.new
    @agent.user_agent = "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/39.0.2171.95 Safari/537.36"
    @agent.keep_alive = false # 間欠的にAPIリクエストするだけなので無効の方がよいのではないか
    # agent.idle_timeout = 5 # defaultのまま
    @agent.open_timeout = 10 # 5でエラー出てたので
    @agent.read_timeout = 30 #5でエラー出たので

    #### Cookie準備
    puts "[setup_mechanize] https login secure.nicolive.jp\n"
    begin
      @agent.post('https://secure.nicovideo.jp/secure/login?site=nicolive', {:next_url => "", :mail => @config["login_mail"], :password => @config["login_password"]})
    rescue Mechanize::ResponseCodeError => rce
      puts "ログインエラー: #{rce.response_code}\n"
      p @agent.page.body
      abort
    rescue => ex
      puts "ログインエラー:\n"
      puts ex.to_s
      abort
    end

    puts "[setup_mechanize] end\n"

  end


  def doCollect_child(liveid)
    inlude Celluloid::IO
    puts "[doCollect_child] start: #{liveid}\n"

    #### getplayerstatusでコメントサーバのIP,port,threadidを取ってくる
    begin
      @agent.get("http://live.nicovideo.jp/api/getplayerstatus?v=#{liveid}") # liveidの先頭に lv を含んでいる
    rescue Mechanize::ResponseCodeError => rce
      puts "responsecodeerror\n"
      @alog.error("getplayerstatus error(005)(#{liveid})(http #{rce.response_code})")
      abort
      #next
    rescue => ex
      puts "[doCollect_child] other error\n"
      puts ex.message
      puts "Backtrace: \n\t"
      temp = ex.backtrace.join("\n\t")
      puts "#{temp}\n"
      @alog.error("getplayerstatus error(007)(#{liveid}): #{ex}")
      @dlog.debug(ex.backtrace.join("\n"))
      abort
      #next
    end

    begin
      if @agent.page.at("//getplayerstatus/attribute::status").text !~ /ok/ then
        # コミュ限とか
        # <?xml version="1.0" encoding="utf-8"?>
        # <getplayerstatus status="fail" time="1313947751"><error><code>require_community_member</code></error></getplayerstatus>
        # require_community_member, closed, notlogin, deletedbyuser, unknown
        # TODO: notloginのときは抜けるようにするか？
        gps_error_code = @agent.page.at("//getplayerstatus/error/code").text
        case gps_error_code
        when "require_community_member", "closed", "deletedbyuser"
          puts "require community member, closed, deletedbyuser: #{gps_error_code}\n"
          # このへんはまあ気にせずともよかろう
          @alog.warn "getplayerstatus error(006)(#{liveid}): #{gps_error_code}"
        else
          # unknownとかは気にしたい
          puts "unknown error: #{gps_error_code}"
          @alog.error "getplayerstatus error(008)(#{liveid}): #{gps_error_code}"
        end

        next # アラートサーバからの次回の受信、つまり sock.each("\0") do |line| の次回に進む
      end
    rescue => exp
      puts "at(\"//getplayerstatus/attribute::status\") error, xmldoc: #{xmldoc}, Exception: #{exp}\n"
      @alog.error("at(\"//getplayerstatus/attribute::status\") error, xmldoc: #{xmldoc}, Exception: #{exp}")
      @dlog.debug(exp.backtrace.join("\n"))
      next
    end

    puts "[doCollect_child] #{liveid}: will connect to commentserver...\n"

    #### コメントサーバへ接続
    commentserver = @agent.page.at("/getplayerstatus/ms/addr").text
    commentport = @agent.page.at("/getplayerstatus/ms/port").text
    commentthread = @agent.page.at("/getplayerstatus/ms/thread").text

    begin
      # TODO: このソケットを集約したい
      sock2 = TCPSocket.open(commentserver, commentport) # :external_encoding => "UTF-8"
      sock2.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
      # sock2.setsockopt(Socket::Option.linger(true, 1)) # close時1秒待ちとするlinger動作
    rescue => exception
      sock2.close if sock2
      #comment_threads.delete(lid)
      @alog.error "comment server socket open error : #{commentserver} #{commentport} #{exception}"
      @dlog.debug(exception.backtrace.join("\n"))
      return #break # その受信待ちスレッドはあきらめて異常終了扱い、Thread.newを抜ける。breakじゃおかしい？
    end

    puts "[doCollect_child] #{liveid}: connected to commentserver\n"
    @alog.info("connected to: #{commentserver}:#{commentport} thread=#{commentthread}")

    begin
      #### 最初にこの合図を送信してやる scoresはNG共有のスコアを受け取るため
      sock2.print "<thread thread=\"#{commentthread}\" version=\"20061206\" res_from=\"-1000\" scores=\"1\"/>\0"
    rescue => exception
      sock2.close if sock2
      #comment_threads.delete(lid)
      puts "**** comment server socket print error : #{commentserver} #{commentport} #{exception}\n"
      @alog.error "comment server socket print error : #{commentserver} #{commentport} #{exception}"
      @dlog.debug(exception.backtrace.join("\n"))
      return #break # その受信待ちスレッドはあきらめて異常終了扱い、Thread.newを抜ける。
    end

    begin
      #### 受信待ち
      sock2.each("\0") do |line2|
        if line2.index("\0") == (line2.length - 1) then
          line2 = line2[0..-2]
        end

        line2.force_encoding("UTF-8")

        @clog.info line2

        if line2 =~ /chat/ then
          xdoc = Nokogiri::XML::Document.parse line2

          message = Hash.new
          message["text"] = xpathtext(xdoc, "//chat")
          message["thread"] = xpathtext(xdoc, "//chat/attribute::thread")
          message["no"] = xpathtext(xdoc, "//chat/attribute::no")
          #message["vpos"] = xpathvalue(xdoc, "//chat/attribute::vpos")
          #message["date"] = xpathvalue(xdoc, "//chat/attribute::date")
          #message["date_usec"] = xpathvalue(xdoc, "//chat/attribute::date_usec")
          #message["mail"] = xpathvalue(xdoc, "//chat/attribute::mail")
          message["user_id"] = xpathtext(xdoc, "//chat/attribute::user_id")
          #message["premium"] = xpathvalue(xdoc, "//chat/attribute::premium")
          #message["anonymity"] = xpathvalue(xdoc, "//chat/attribute::anonymity")
          #message["locale"] = xpathvalue(xdoc, "//chat/attribute::locale")
          #message["score"] = xpathvalue(xdoc, "//chat/attribute::score")
          puts "[" + message["thread"] + "] [" + message["no"] + "] [" + message["user_id"] + "] "+ message["text"] + "\n"
          
        end

        if line2 =~ /\/disconnect/ then
          puts "**** DISCONNECT: #{lid} ****\n"
          @alog.info("disconnect: #{lid}")

          sock2.close if sock2
          sock2 = nil # ？？
          #comment_threads.delete(lid)
          return #break # その受信待ちスレッドは終了でよいから、sock2.eachを抜けて、Thread.newも抜ける。break
        end
      end # of sock2.each
    rescue => exception
      puts "**** comment server socket read(each) error : #{commentserver} #{commentport} #{exception}\n"
      puts "Backtrace: \n\t"
      puts exception.backtrace.join("\n\t")
      @alog.error "comment server socket read(each) error : #{commentserver} #{commentport} #{exception}"

      sock2.close if sock2
      #comment_threads.delete(lid)
    end
  end

  def doCollect()
    load_config
    setup_logger
    setup_mechanize

    puts "[doCollect] setup_mechanize done.\n"

    begin
      @rmqconn = MarchHare.connect(:host => @rmq_ip, :port => @rmq_port)
    rescue MarchHare::ConnectionRefused => cre
      puts "RabbitMQへのコネクション確立エラー: #{cre.to_s}\n"
      puts cre.backtrace
      abort
    end
    # MarchHareではstartは意味ないらしい
    # http://reference.rubymarchhare.info/MarchHare/Session.html#start-instance_method
    #@rmqconn.start
    puts "[doCollect] rmq connection started\n"

    # prefetchのデフォルトは0。ackまたはrejectする前に、prefetch個のメッセージをconsumerに渡すらしい。
    # explicit acknowledgementsを使っていないときは、prefetchの設定は無視されると書いてある。1にしておく。
    # http://rubymarchhare.info/articles/queues.html
    @rmqchannel = @rmqconn.create_channel
    puts "rmqchannel.prefetch: #{@rmqchannel.prefetch}"
    @rmqchannel.prefetch = 1
    puts "rmqchannel.prefetch: #{@rmqchannel.prefetch}"

    rmqqueue = @rmqchannel.queue("#{@rmq_routing_key}", :durable => true)
    puts "[doCollect] rmq queue #{@rmq_routing_key} created\n"
    puts "queue count: #{rmqqueue.message_count}\n"

    begin
      # bunny/march_hareのデフォルトでは、subscribeを呼ぶ側と、subscribeの内側は別のスレッドで動くらしい。
      # :block => trueを渡すとsubscribe内部をブロックする動作となる。
      # subscribeからの戻りは delivery_info, properties, bodyの3つなのか、metadata, bodyの2つなのか？
      # どうも2つで十分で、metadataから全部取れるっぽい。
      # http://rubybunny.info/articles/queues.html#blocking_or_nonblocking_behavior
      # prefetch=1、かつ、:manual_ack => trueにしてackを返すようにすると、1個ずつ消費しているように見える
      @count = 0
      @rmqconsumer = rmqqueue.subscribe(:manual_ack => true) do |metadata, body|
        puts "queue count: #{rmqqueue.message_count}\n"
        @count = @count + 1
        puts "subscribe #{@count}\n"
        if !(body.nil?) then
          puts "[doCollect] body: #{body}\n"
          #supervisor = RmqCollector_Cell.supervise_as(body.to_sym(), body)
          #Celluloid::Actor[body.to_sym()].run
          #doCollect_child body
        else
          puts "[doCollect] subscribe loop ..... nil? #{body}\n"
        end
        @rmqchannel.acknowledge(metadata.delivery_tag, false)
      end
    rescue => exception
      puts "[doCollect] subscribe error: #{exception}\n"
    end

    puts "#{rmqqueue.message_count}\n"
    puts "[doCollect] RabbitMQ queue #{@rmq_routing_key} subscribe(main thread) end.\n"
  end

  def closeChannel()
    cancel_ok = @rmqconsumer.cancel
    puts "consumer cancel: #{cancel_ok}\n"
    @rmqchannel.close
    @rmqconn.close
  end
end

class RmqCollector_Cell
  include Celluloid
  include Celluloid::Logger

  def initialize(liveid)
    @liveid = liveid
  end

  def run
    debug @liveid
  end
end

# Windows JRuby用。-E Windows-31J:UTF-8 が効いてないという問題があるので、回避。
# https://groups.google.com/forum/#!topic/jruby-users-jp/qe9CFSmoKHA
if (defined? JRUBY_VERSION) and (RbConfig::CONFIG['host_os'] =~ /win/) then
  $stdout.set_encoding("Windows-31J", "UTF-8", :undef=>:replace, :invalid=>:replace, :replace=>"■")
end

# rubyのシグナルハンドラでは、特にsignal-safeのような定義はない
# http://comments.gmane.org/gmane.comp.lang.ruby.japanese/8076
# http://stackoverflow.com/questions/2089421/capturing-ctrl-c-in-ruby
# http://qiita.com/kasei-san/items/75ad2bb384fdb7e05941
# JRuby固有の事情
# https://gist.github.com/hiremaga/320008
Signal.trap(:INT) {
  #puts Thread.list.join("\n")

  response = Readline.readline("[rmq_collector] > shutdown?: [y/n] ")
  if response =~ /y/i then
    puts "[rmq_collector] > raise Interrupt...\n"
    raise Interrupt
  end
  puts "[rmq_collector] > continue...\n"
}

rcol = RmqCollector.new
begin
  puts "[main] start doCollect\n"
  rcol.doCollect
  puts "[main] end doCollect\n"
  puts "[main] waiting for new RabbitMQ Message...\n"
  sleep
rescue Interrupt
  puts "interrupted. (after signal handler)\n"
ensure
  puts "[main] ensure clause. closeChannel...\n"
  rcol.closeChannel
end

puts "[main] EXIT\n"
