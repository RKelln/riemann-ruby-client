require 'monitor'
require 'riemann/client/tcp_socket'

module Riemann
  class Client
    class TCP < Client
      attr_accessor :host, :port, :socket

      # Public: Set a socket factory -- an object responding
      # to #call(options) that returns a Socket object
      def self.socket_factory=(factory)
        @socket_factory = factory
      end

      # Public: Return a socket factory
      def self.socket_factory
        @socket_factory || proc { |options| TcpSocket.connect(options) }
      end

      def initialize(options = {})
        @options = options
        @locket  = Monitor.new
      end

      def socket
        @locket.synchronize do
          if @pid && @pid != Process.pid
            close
          end

          if @socket and not @socket.closed?
            return @socket
          end

          @socket = self.class.socket_factory.call(@options)
          @pid    = Process.pid

          return @socket
        end
      end

      def close
        @locket.synchronize do
          if @socket && !@socket.closed?
            @socket.close
          end
          @socket = nil
        end
      end

      def connected?
        !@socket && @socket.closed?
      end

      # Read a message from a stream
      def read_message(s)
        if buffer = s.read(4) and buffer.size == 4
          length = buffer.unpack('N').first
          begin
            str = s.read length
            message = Riemann::Message.decode str
          rescue => e
            puts "Message was #{str.inspect}"
            raise
          end
          
          unless message.ok
            puts "Failed"
            raise ServerError, message.error
          end
          
          message
        else
          raise InvalidResponse, "unexpected EOF"
        end
      end

      def send_recv(message)
        with_connection do |s|
          s.write(message.encode_with_length)
          read_message(s)
        end
      end

      alias send_maybe_recv send_recv

      # Yields a connection in the block.
      def with_connection
        tries = 0
        
        @locket.synchronize do
          begin
            tries += 1
            yield(socket)
          rescue IOError, Errno::EPIPE, Errno::ECONNREFUSED, InvalidResponse, Timeout::Error, Riemann::Client::TcpSocket::Error
            close
            raise if tries > 3
            retry
          rescue Exception
            close
            raise
          end
        end
      end
    end
  end
end
