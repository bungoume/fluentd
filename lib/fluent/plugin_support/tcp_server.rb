#
# Fluentd
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#

require 'fluent/plugin_support/event_loop'
require 'fluent/plugin_support/timer'

require 'socket'
require 'cool.io'

module Fluent
  module PluginSupport
    module TCPServer
      include Fluent::PluginSupport::EventLoop
      include Fluent::PluginSupport::Timer

      TCP_SERVER_KEEPALIVE_CHECK_INTERVAL = 1

      def initialize
        super
        @_tcp_server_listen_socks = []
        @_tcp_server_connections = {}
      end

      def configure(conf)
        super
      end

      # keepalive: seconds, (default: nil [inf])
      def tcp_server_listen(port: nil, bind: '0.0.0.0', keepalive: nil, backlog: nil, &block)
        raise "BUG: specify port for tcp_server_listen" unless port

        bind_sock = ::TCPServer.new(bind, port)

        if self.respond_to?(:detach_multi_process)
          detach_multi_process do
            tcp_server_listen_impl(bind_sock, keepalive, backlog, &block)
          end
        elsif self.respond_to?(:detach_process)
          detach_process do
            tcp_server_listen_impl(bind_sock, keepalive, backlog, &block)
          end
        else
          tcp_server_listen_impl(bind_sock, keepalive, backlog, &block)
        end
      end

      def shutdown
        super
        @_tcp_server_connections.keys.each do |sock|
          sock.close unless sock.closed?
        end
        @_tcp_server_listen_socks.each{|s| s.close }
      end

      def tcp_server_listen_impl(bind_sock, keepalive, backlog, &block)
        register_new_connection = ->(sock){ @_tcp_server_connections[sock] = sock }
        sock = Coolio::TCPServer.new(bind_sock, nil, Handler, register_new_connection, block)
        if backlog
          sock.listen(backlog)
        end
        @_tcp_server_listen_socks << sock
        event_loop_attach( sock )

        timer_execute(interval: TCP_SERVER_KEEPALIVE_CHECK_INTERVAL, repeat: true) do
          # copy keys at first (to delete it in loop)
          @_tcp_server_connections.keys.each do |sock|
            if !sock.writing && keepalive && sock.idle > keepalive
              @_tcp_server_connections.delete(sock)
              sock.close
            elsif sock.closed?
              @_tcp_server_connections.delete(sock)
            else
              sock.idle += TCP_SERVER_KEEPALIVE_CHECK_INTERVAL
            end
          end
        end
      end

      class Handler < Coolio::Socket
        attr_accessor :idle, :closing
        attr_reader :remote_port, :remote_addr

        def initialize(io, register, on_connect_callback)
          super(io)

          register.call(self)
          @on_connect_callback = on_connect_callback
          @on_read_callback = nil

          @buffer = nil # for on_data with delimiter

          @idle = 0
          @closing = false
          @writing = false

          ### TODO: address/name, socket option
          #
          # PEERADDR_FAILED = ["?", "?", "name resolusion failed", "?"]
          # @addr = (io.peeraddr rescue PEERADDR_FAILED)
          # opt = [1, @timeout.to_i].pack('I!I!')  # { int l_onoff; int l_linger; }
          # io.setsockopt(Socket::SOL_SOCKET, Socket::SO_LINGER, opt)

          @remote_port, @remote_addr = *Socket.unpack_sockaddr_in(io.getpeername) rescue nil
        end

        def on_connect
          @on_connect_callback.call(self)
        end

        # API to register callback for data arrival
        def on_data(delimiter: nil, &callback)
          if delimiter.nil?
            @on_read_callback = callback
          else
            @buffer = "".force_encoding("ASCII-8BIT")
            @on_read_callback = ->(data) {
              @buffer << data
              pos = 0
              while i = @buffer.index(delimiter, pos)
                msg = @buffer[pos...i]
                callback.call(msg)
                pos = i + delimiter.length
              end
              @buffer.slice!(0, pos) if pos > 0
            }
          end
        end

        def on_read(data)
          @idle = 0
          @on_read_callback.call(data)
        rescue => e
          close
        end

        def write(data)
          @writing = true
          super
        end

        def on_write_complete
          @writing = false
          if @closing
            close
          end
        end
      end
    end
  end
end