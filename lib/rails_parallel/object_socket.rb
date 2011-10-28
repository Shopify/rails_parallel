require 'rubygems'
require 'socket'

class ObjectSocket
  BLOCK_SIZE = 4096

  attr_reader :socket

  def self.pair
    Socket.pair(Socket::AF_UNIX, Socket::SOCK_STREAM, 0).map { |s| new(s) }
  end

  def initialize(socket)
    @socket = socket
    @buffer = ''
  end

  def nonblock=(val)
    @nonblock = val
  end

  def close
    @socket.close
  end

  def nonblocking(&block)
    with_nonblock(true, &block)
  end
  def blocking(&block)
    with_nonblock(false, &block)
  end

  def each_object(&block)
    first = true
    loop do
      process_buffer(&block) if first
      first = false

      @buffer += @nonblock ? @socket.read_nonblock(BLOCK_SIZE) : @socket.readpartial(BLOCK_SIZE)
      process_buffer(&block)
    end
  rescue Errno::EAGAIN
    # end of nonblocking data
  end

  def next_object
    each_object { |o| return o }
    nil # no pending data in nonblock mode
  end

  def <<(obj)
    flush_stdio
    data = Marshal.dump(obj)
    @socket.syswrite [data.size, data].pack('Na*')
    self # chainable
  end

  private

  def process_buffer
    while @buffer.size >= 4
      size = 4 + @buffer.unpack('N').first
      break unless @buffer.size >= size

      packet = @buffer.slice!(0, size)
      yield Marshal.load(packet[4..-1])
    end
  end

  def with_nonblock(value)
    old_value = @nonblock
    @nonblock = value
    return yield
  ensure
    @nonblock = old_value
  end

  def flush_stdio
    [$stdout, $stderr].each { |fh| fh.flush } # 1.9 stdio buffering
  end
end
