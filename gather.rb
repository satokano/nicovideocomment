# -*- coding: utf-8 -*-

require 'rubygems'
require 'mechanize'
require 'kconv'
require 'logger'
require 'rexml/document'
require 'socket'
require 'sqlite3'
require 'psych'
require 'yaml'
require 'stomp'
require 'json'

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
usebrowsercookie = config["usebrowsercookie"] 
dbfile = config["dbfile"] # Chrome
alert_log = "alert.log"
comment_log = "comment.log"
debug_log = "debug.log"
children = config["children"] || 50
stomp_user = "guest"
stomp_password = "guest"
stomp_host = "localhost"
stomp_port = 61613
stomp_dst = "/queue/nicolive01"
# === configure end

browsercookie = ""
agent = Mechanize.new

# FreeBSD8ではSSLエラーがでた。
# デフォルトで/etc/ssl/cert.pemが使われるので、そこからシンボリックリンクを張って回避
# agent.ca_file = "/usr/local/share/certs/ca-root-nss.crt"

alog = Logger.new(alert_log, 5)
alog.level = Logger::INFO
clog = Logger.new(comment_log, 600)
clog.level = Logger::INFO
dlog = Logger.new(debug_log, 3)
dlog.level = Logger::DEBUG

comment_threads = Hash.new()

#### Cookie準備
if usebrowsercookie then
  # Chrome
  sql = "select * from cookies where host_key like '%nicovideo.jp' and name = 'user_session';"
  db = SQLite3::Database.new(dbfile)
  db.results_as_hash = true
  db.execute(sql) do |row|
	# Looks like it's using 1601-01-01 00:00:00 UTC as the epoc
    exptime_utc = Time.at(Time.utc(1601, 1, 1, 0, 0, 0, 0), row['expires_utc']).utc

    # CREATE TABLE cookies 
    # (creation_utc INTEGER NOT NULL UNIQUE PRIMARY KEY,
    # host_key TEXT NOT NULL,
    # name TEXT NOT NULL,
    # value TEXT NOT NULL,
    # path TEXT NOT NULL,
    # expires_utc INTEGER NOT NULL,
    # secure INTEGER NOT NULL,
    # httponly INTEGER NOT NULL,
    # last_access_utc INTEGER NOT NULL);

    # [12957760714289143, ".nicovideo.jp", "user_session", "user_session_1925160_454899025913333356", "/", 12960352716000000, 0, 0, 12957978849585587]
	browsercookie = row['name'] + "=" + row['value']+ "; expires=" + exptime_utc.strftime("%a, %d-%b-%Y %H:%M:%S GMT") + "; path=" + row['path'] + "; domain=" + row['host_key'] + ";"
	puts "[cookie_get] #{browsercookie}\n"
  end
end

if usebrowsercookie then
  print "[cookie_set] usebrowsercookie \n"
  nicovideo_jp_uri = URI.parse("https://secure.nicovideo.jp/") # 完全なURLを入れておく
  Mechanize::Cookie.parse(nicovideo_jp_uri, browsercookie) {|c|
	agent.cookie_jar.add(nicovideo_jp_uri, c)
  }
else
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
sock = TCPSocket.open(alertserver, alertport)
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
	  alog.error("getplayerstatusエラー(005)(lv#{liveid})(http #{rce.response_code})\n")
	  next
	rescue => ex
	  alog.error("getplayerstatusエラー(lv#{liveid}) \n")
	  alog.error(ex.to_s)
	  next
	end
	  
    xmldoc = REXML::Document.new agent.page.body

    if REXML::XPath.first(xmldoc, "//getplayerstatus/attribute::status").value !~ /ok/ then
      # コミュ限とか
      # <?xml version="1.0" encoding="utf-8"?>
      # <getplayerstatus status="fail" time="1313947751"><error><code>require_community_member</code></error></getplayerstatus>
      # notloginのときは抜けるようにするか？
      alog.error("getplayerstatusエラー(006)(lv#{liveid}) エラーコード: #{REXML::XPath.first(xmldoc, "//getplayerstatus/error/code").text}")
      next # sock.each("\0") do |line| の次回に進む
    end
	
    #### コメントサーバへ接続
    commentserver = REXML::XPath.first(xmldoc, "/getplayerstatus/ms/addr").text
    commentport = REXML::XPath.first(xmldoc, "/getplayerstatus/ms/port").text
    commentthread = REXML::XPath.first(xmldoc, "/getplayerstatus/ms/thread").text

    comment_threads[liveid] = Thread.new(agent, liveid, commentserver, commentport, commentthread) do |ag, lid, cserv, cport, cth|
      dlog.debug("#{comment_threads.size}: #{comment_threads.keys.sort}")

      begin
        sock2 = TCPSocket.open(cserv, cport) # :external_encoding => "UTF-8"
        alog.info("connect to: #{cserv}:#{cport} thread=#{cth}")

        #### stomp
        stomp_con = Stomp::Connection.new(stomp_user, stomp_password, stomp_host, stomp_port)

        #### 最初にこの合図を送信してやる
        sock2.print "<thread thread=\"#{cth}\" version=\"20061206\" res_from=\"-100\"/>\0"

        #### 受信待ち
        sock2.each("\0") do |line|
          if line.index("\0") == (line.length - 1) then
            line = line[0..-2]
          end

          line.force_encoding("UTF-8")

          clog.info line

          if line =~ /chat/ then
            xdoc = REXML::Document.new line
            message = Hash.new
            message["text"] = REXML::XPath.first(xdoc, "//chat").text
            message["thread"] = xpathvalue(xdoc, "//chat/attribute::thread")
            message["no"] = xpathvalue(xdoc, "//chat/attribute::no")
            message["vpos"] = xpathvalue(xdoc, "//chat/attribute::vpos")
            message["date"] = xpathvalue(xdoc, "//chat/attribute::date")
            message["mail"] = xpathvalue(xdoc, "//chat/attribute::mail")
            message["user_id"] = xpathvalue(xdoc, "//chat/attribute::user_id")
            message["premium"] = xpathvalue(xdoc, "//chat/attribute::premium")
            message["anonymity"] = xpathvalue(xdoc, "//chat/attribute::anonymity")
            message["locale"] = xpathvalue(xdoc, "//chat/attribute::locale")
            puts "[" + message["thread"] + "] ["+ message["user_id"] + "] "+ message["text"] + "\n"
            stomp_con.publish stomp_dst, message.to_json
          end

          if line =~ /\/disconnect/ then
            puts "**** DISCONNECT: #{lid} ****\n"
            alog.info("disconnect: #{lid}")
            sock2.close
            comment_threads.delete(lid)
            # next
          end
        end # of sock2.each
      rescue => exception
        puts "**** comment server socket open or read(each) error (threads#{comment_threads.size}): #{cserv} #{cport} #{exception}\n"
        dlog.error "comment server socket open or read(each) error (threads#{comment_threads.size}): #{cserv} #{cport} #{exception}"
        #sock2.close
        comment_threads.delete(lid)
      end

    end # of Thread.new() do || ...

  end # of if comment_threads.size < children ...
end
