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

config = YAML.load_file("config.yaml")
# === configure
mycommlist = ["co1247938", "co1063186", "co1268500", "co1004464", "co1233486", "co1219623", "co555044", "co1234033", "co387509", "co521674", "co1198302",
  "co1116209", "co625201", "co1157798", "co1379188", "co1190806", "co1329172", "co1356736", "co1171944", "co1258342", "co1395104", "co1251188", "co1136133", "co1362710", "co1389548", "co444979", "co1378074", "co351386", "co1419168", "co478298", "co1334900", "co1295356", "co1329481"]
login_mail = config["login_mail"]
login_password = config["login_password"]
usebrowsercookie = config["usebrowsercookie"] 
dbfile = config["dbfile"] # Chrome
alert_log = "alert.log"
comment_log = "comment.log"
children = 30
# === configure end

browsercookie = ""
# ischildthread = false
agent = Mechanize.new

# FreeBSD8ではSSLエラーがでた。
# デフォルトで/etc/ssl/cert.pemが使われるので、そこからシンボリックリンクを張って回避
# agent.ca_file = "/usr/local/share/certs/ca-root-nss.crt"

alog = Logger.new(alert_log, 5)
alog.level = Logger::INFO
clog = Logger.new(comment_log, 10)
clog.level = Logger::INFO
comment_threads = []

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
	puts "[cookie_get] " + browsercookie
  end
end

if usebrowsercookie then
  print "[cookie_set] usebrowsercookie "
  nicovideo_jp_uri = URI.parse("https://secure.nicovideo.jp/") # 完全なURLを入れておく
  Mechanize::Cookie.parse(nicovideo_jp_uri, browsercookie) {|c|
	agent.cookie_jar.add(nicovideo_jp_uri, c)
  }
else
  print "[cookie_get] https login secure.nicolive.jp"
  agent.post('https://secure.nicovideo.jp/secure/login?site=nicolive', {:next_url => "", :mail => login_mail, :password => login_password})

  if agent.page.code != "200" then
	puts "ログイン失敗(001)".tosjis
	p agent.page.body.tosjis
	abort
  end
end

puts agent.cookie_jar.jar

puts "[login] nicolive_antenna"
agent.post('https://secure.nicovideo.jp/secure/login?site=nicolive_antenna', {:mail => login_mail, :password => login_password})

if agent.page.code != "200" then
  abort "ログイン失敗(001)".tosjis
end
agent.cookie_jar.save_as('mech_cookie.yaml')

xmldoc = REXML::Document.new agent.page.body

if REXML::XPath.first(xmldoc, "//nicovideo_user_response/attribute::status").value !~ /ok/ then
  abort "ログイン失敗(002)".tosjis
end
ticketstr = REXML::XPath.first(xmldoc, "//ticket").text

agent.post('http://live.nicovideo.jp/api/getalertstatus', {:ticket => ticketstr})
if agent.page.code != "200" then
  abort "getalertstatus失敗(003)".tosjis
end

xmldoc = REXML::Document.new agent.page.body
if REXML::XPath.first(xmldoc, "//getalertstatus/attribute::status").value !~ /ok/ then
  p agent.page.body.tosjis
  abort "getalertstatus失敗(004)".tosjis
end

REXML::XPath.each(xmldoc, "//community_id") {|ele|
  mycommlist.push ele.text
}

print "[getalertstatus] OK\n"
commserver = REXML::XPath.first(xmldoc, "/getalertstatus/ms/addr").text
commport = REXML::XPath.first(xmldoc, "/getalertstatus/ms/port").text
commthread = REXML::XPath.first(xmldoc, "/getalertstatus/ms/thread").text
print("[getalertstatus] connect to: ", commserver, ":", commport, " , thread=", commthread, "\n")

sock = TCPSocket.open(commserver, commport)
sock.print "<thread thread=\"#{commthread}\" version=\"20061206\" res_from=\"-1\">\0"
sock.each("\0") do |line|
  liveid = ""
  communityid = ""
  ownerid = ""
  
  if line.index("\0") == (line.length - 1) then
	line = line[0..-2]
  end
  
  if line =~ /<chat [^>]+>(\w+),(\w+),(\w+)<\/chat>/ then
    liveid = $1
    communityid = $2
    ownerid = $3
  end
  alog.info(line)
  
  if mycommlist.include?(communityid) then
	puts "★ #{communityid}".tosjis
  end
  
  if comment_threads.size < children && line =~ /<chat/ then
    ag = agent
    lid = liveid
    comment_threads << Thread.new(agent, liveid) do |ag, lid|
      ag.get("http://live.nicovideo.jp/api/getplayerstatus?v=lv#{lid}")
      if ag.page.code != "200" then
        abort "getplayerstatus失敗(005)(lv#{lid})".tosjis
      end
      xmldoc = REXML::Document.new ag.page.body

      if REXML::XPath.first(xmldoc, "//getplayerstatus/attribute::status").value !~ /ok/ then
		# コミュ限とか
		# <?xml version="1.0" encoding="utf-8"?>
		# <getplayerstatus status="fail" time="1313947751"><error><code>require_community_member</code></error></getplayerstatus>
        puts "getplayerstatus失敗(006)(lv#{lid})".tosjis
        puts ag.page.body.tosjis
        return # Thread.newのdoブロックのみ抜けたい。。。returnで正しいか？
      end

      comm2server = REXML::XPath.first(xmldoc, "/getplayerstatus/ms/addr").text
      comm2port = REXML::XPath.first(xmldoc, "/getplayerstatus/ms/port").text
      comm2thread = REXML::XPath.first(xmldoc, "/getplayerstatus/ms/thread").text
      print("connect to: ", comm2server, ":", comm2port, " , thread=", comm2thread, "\n")
      sock2 = TCPSocket.open(comm2server, comm2port)
      sock2.print "<thread thread=\"#{comm2thread}\" version=\"20061206\" res_from=\"-100\"/>\0"
      sock2.each("\0") do |line|
		if line.index("\0") == (line.length - 1) then
		  line = line[0..-2]
		end
		clog.info line.tosjis
        puts "> #{line}".tosjis
        if line =~ /\/disconnect/ then
          puts "**** DISCONNECT ****\n"
          break
        end
      end # of sock2.each
    end # of Thread.new() do || ...
  end # of 
  
end
