require 'singleton'

class ConnectionFactory
  include Singleton

  def initialize
    @pool = Hash.new
  end

  def getconnection(ip, port)
  	@ipport = ip << port
  	if @pool[@ipport] and @pool[@ipport].instanceof? TCPSocket
      @pool[@ipport]
    else
      @sock = TCPSocket.open(ip, port)
      @pool[@ipport] = @sock
      @pool[@ipport]
  	end
  end

  def releaseconnection(ip, port)
    @ipport = ip << port
    @pool.delete(@ipport)
  end
end
