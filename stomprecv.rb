require 'rubygems'
require 'stomp'
require 'json'
require 'redis'

zkey = "nicolive01"

con = Stomp::Connection.new("guest", "guest", "localhost", 61613)
con.subscribe "/queue/nicolive01"

redis = Redis.new(:host => "localhost", :port => 6379)

while true
  msg = con.receive
  h = JSON.parse(msg.body)
  puts h["text"]
  redis.zincrby(zkey, "1", h["user_id"])
end

