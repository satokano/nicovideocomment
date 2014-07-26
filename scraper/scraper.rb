# -*- coding: utf-8 -*-
# 
# = ニコニコ生放送 ユーザ生（recent）のRSSを読み込んで内容を表示、RabbitMQにpublishする
# Author:: Satoshi OKANO
# Copyright:: Copyright 2011-2014 Satoshi OKANO
# License:: MIT

require 'rubygems'
require 'mechanize'
require 'bunny'

class RssScraper
  def initialize()
    load_config()

    #### Mechanizeを作成して、通信を開始する。
    # Chrome 33.0.1750.154m Windows7 64bitのUser Agentは以下
    # Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/33.0.1750.154 Safari/537.36
    @agent = Mechanize.new
    @agent.user_agent = "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/33.0.1750.154 Safari/537.36"
    @agent.keep_alive = false # 間欠的にAPIリクエストするだけなので無効の方がよいのではないか
    # agent.idle_timeout = 5 # defaultのまま
    @agent.open_timeout = 5
    @agent.read_timeout = 5

    if @bunny_enabled then
      @bunnyconn = Bunny.new(:host => @bunny_ip)
      @bunnyconn.start
      @bunnychannel = @bunnyconn.create_channel
      @bunnyexchange = @bunnychannel.default_exchange
    end
  end

  def load_config()
    puts "[init] loading config..."
    config = YAML.load_file("config.yaml")
    @login_mail = config["login_mail"]
    @login_password = config["login_password"]
    @bunny_enabled = config["bunny_enabled"]
    @bunny_ip = config["bunny_ip"]
    @bunny_routing_key = config["bunny_routing_key"]
  end

  def xpathtext(xmlnode, path)
    @temp = xmlnode.xpath(path)
    if @temp.nil?
      ""
    else
      @temp.text
    end
  end

  def doScrape()
    #### Cookie準備。RSSはログインしなくても取れるようだが。。。
    print "[cookie_get] https login secure.nicolive.jp\n"
    begin
      @agent.post('https://secure.nicovideo.jp/secure/login?site=nicolive', {:next_url => "", :mail => @login_mail, :password => @login_password})
    rescue Mechanize::ResponseCodeError => rce
      puts "ログインエラー: #{rce.response_code}\n"
      p @agent.page
      abort
    rescue => ex
      puts "ログインエラー: #{ex.to_s}\n"
      puts ex.backtrace
      abort
    end

    begin
      @agent.get("http://live.nicovideo.jp/recent/rss")
    rescue Mechanize::ResponseCodeError => rce
      puts "RSS取得エラー: #{rce.response_code}\n"
      p @agent.page
      abort
    rescue => ex
      puts "RSS取得エラー: #{ex.to_s}\n"
      puts ex.backtrace
      abort
    end

    if !(@agent.page.at("//rss/channel/nicolive:total_count").text) then
      puts "RSS取得エラー（放送中の全枠数が取得できませんでした）\n"
      p @agent.page
      abort
    end

    @total_count = @agent.page.at("//rss/channel/nicolive:total_count").text.to_i
    # puts "現在放送中 #{total_count}\n"
    @itemsperpage = @agent.page.search("//rss/channel/item").length.to_i
    @pages = (@total_count.quo(@itemsperpage)).ceil
    @member_only_count = 0
    @total_count_actual = 0

    @pages.downto(1) {|num|
      @agent.get("http://live.nicovideo.jp/recent/rss?p=#{num}")
      @agent.page.search("//rss/channel/item").each {|item|
        owner_name = xpathtext(item, ".//nicolive:owner_name")
        community_name = xpathtext(item, ".//nicolive:community_name")
        title = xpathtext(item, ".//title")
        member_only = (xpathtext(item, ".//nicolive:member_only") == "true")
        if member_only then
          @member_only_count += 1
        end
        guid = xpathtext(item, ".//guid")
        puts "#{guid} #{owner_name} #{community_name} #{title} #{member_only}\n"
        @total_count_actual += 1
        if @bunny_enabled then
          @bunnyexchange.publish("#{guid}", :routing_key => @bunny_routing_key)
        end
      }
    }

    puts "合計件数(RSS情報): #{@total_count}\n"
    puts "合計件数(実績): #{@total_count_actual} / コミュ限: #{@member_only_count} / 公開: #{@total_count_actual - @member_only_count}\n"

    if @bunny_enabled then
      @bunnyconn.close
    end
  end

end

# Windows JRuby用。-E Windows-31J:UTF-8 が効いてないという問題があるので、回避。
# https://groups.google.com/forum/#!topic/jruby-users-jp/qe9CFSmoKHA
if (defined? JRUBY_VERSION) and (RbConfig::CONFIG['host_os'] =~ /win/) then
  $stdout.set_encoding("Windows-31J", "UTF-8", :undef=>:replace, :invalid=>:replace, :replace=>"■")
end

scr = RssScraper.new
scr.doScrape
