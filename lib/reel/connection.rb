module Reel
  # A connection to the HTTP server
  class Connection
    class StateError < RuntimeError; end # wrong state for a given operation

    attr_reader :request, :socket, :parser

    # Attempt to read this much data
    BUFFER_SIZE = 4096

    def initialize(socket)
      @socket = socket
      @keepalive = true
      @parser = Request::Parser.new
      reset_request

      @response_state = :header
      @body_remaining = nil
    end

    # Is the connection still active?
    def alive?; @keepalive; end

    # Reset the current request state
    def reset_request(state = :header)
      @request_state = state
      @request = nil
      @header_buffer = "" # Buffer headers in case of an upgrade request
      @parser.reset
    end

    def peer_address
      @socket.peeraddr(false)
    end

    def local_address
      @socket.addr(false)
    end

    # Read a request object from the connection
    def request
      @request ||= begin
        Request.read(self).tap do |request|
          case request
          when Request
            @request_state = :body
            @keepalive = false if request['Connection'] == 'close' || request.version == "1.0"
            @body_remaining = Integer(request['Content-Length']) if request['Content-Length']
          when WebSocket
            @request_state = @response_state = :websocket
            @body_remaining = nil
            @socket = nil
          else raise "unexpected request type: #{request.class}"
          end
        end
      end

    rescue IOError, Errno::ECONNRESET, Errno::EPIPE
      # The client is disconnected
      @keepalive = false
    end

    # Read a chunk from the request
    def readpartial(size = BUFFER_SIZE)
      raise StateError, "can't read in the `#{@request_state}' state" unless @request_state == :body

      if @body_remaining and @body_remaining > 0
        chunk = @parser.chunk
        unless chunk
          @parser << @socket.readpartial(size)
          chunk = @parser.chunk
          return unless chunk
        end

        @body_remaining -= chunk.length
        @body_remaining = nil if @body_remaining < 1

        chunk
      end
    end

    # Send a response back to the client
    # Response can be a symbol indicating the status code or a Reel::Response
    def respond(response, headers_or_body = {}, body = nil)
      raise StateError "not in header state" if @response_state != :header

      if headers_or_body.is_a? Hash
        headers = headers_or_body
      else
        headers = {}
        body = headers_or_body
      end

      if @keepalive
        headers['Connection'] = 'Keep-Alive'
      else
        headers['Connection'] = 'close'
      end

      case response
      when Symbol
        response = Response.new(response, headers, body)
      when Response
      else raise TypeError, "invalid response: #{response.inspect}"
      end

      response.render(@socket)

      # Enable streaming mode
      if response.headers['Transfer-Encoding'] == "chunked" and response.body.nil?
        @response_state = :chunked_body
      end
    rescue IOError, Errno::ECONNRESET, Errno::EPIPE
      # The client disconnected early
      @keepalive = false
    ensure
      if @keepalive
        reset_request(:header)
      else
        @socket.close unless @socket.closed?
        reset_request(:closed)
      end
    end

    # Write body chunks directly to the connection
    def write(chunk)
      raise StateError, "not in chunked body mode" unless @response_state == :chunked_body
      chunk_header = chunk.bytesize.to_s(16) + Response::CRLF
      @socket << chunk_header
      @socket << chunk
    end
    alias_method :<<, :write

    # Finish the response and reset the response state to header
    def finish_response
      raise StateError, "not in body state" if @response_state != :chunked_body
      @socket << "0" << Response::CRLF * 2
      @response_state = :header
    end

    # Close the connection
    def close
      @keepalive = false
      @socket.close
    end
  end
end
