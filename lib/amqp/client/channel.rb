# frozen_string_literal: true

require_relative "./message"

module AMQP
  # AMQP Channel
  class Channel
    def initialize(connection, id)
      @rpc = Queue.new
      @connection = connection
      @id = id
      @consumers = {}
      @closed = nil
    end

    attr_reader :id, :consumers

    def open
      write_bytes FrameBytes.channel_open(@id)
      expect(:channel_open_ok)
      self
    end

    def close(reason = "", code = 200)
      write_bytes FrameBytes.channel_close(@id, reason, code)
      expect :channel_close_ok
      @closed = [code, reason]
    end

    def closed!(code, reason, classid, methodid)
      write_bytes FrameBytes.channel_close_ok(@id)
      @closed = [code, reason, classid, methodid]
      @rpc.close
      @consumers.each(&:close)
      @consumers.clear
    end

    def queue_declare(name = "", passive: false, durable: true, exclusive: false, auto_delete: false, **args)
      durable = false if name.empty?
      exclusive = true if name.empty?
      auto_delete = true if name.empty?

      write_bytes FrameBytes.queue_declare(@id, name, passive, durable, exclusive, auto_delete, args)
      name, message_count, consumer_count = expect(:queue_declare_ok)
      {
        queue_name: name,
        message_count: message_count,
        consumer_count: consumer_count
      }
    end

    def queue_delete(name, if_unused: false, if_empty: false, no_wait: false)
      write_bytes FrameBytes.queue_delete(@id, name, if_unused, if_empty, no_wait)
      message_count, = expect :queue_delete
      message_count
    end

    def basic_get(queue_name, no_ack: true)
      write_bytes FrameBytes.basic_get(@id, queue_name, no_ack)
      frame, rest = @rpc.shift
      case frame
      when :basic_get_ok
        delivery_tag, exchange_name, routing_key, redelivered = rest
        body_size, properties = expect(:header)
        pos = 0
        body = String.new("", capacity: body_size)
        while pos < body_size
          body_part = expect(:body)
          body += body_part
          pos += body_part.bytesize
        end
        Message.new(delivery_tag, exchange_name, routing_key, properties, body, redelivered)
      when :basic_get_empty then nil
      when nil              then raise AMQP::Client::ChannelClosedError.new(@id, *@closed)
      else raise AMQP::Client::UnexpectedFrame.new(%i[basic_get_ok basic_get_empty], frame)
      end
    end

    def basic_publish(body, exchange, routing_key, properties = {})
      write_bytes FrameBytes.basic_publish(@id, exchange, routing_key),
                  FrameBytes.header(@id, body.bytesize, properties)

      # body frames, splitted on frame size
      pos = 0
      while pos < body.bytesize
        len = [4096, body.bytesize - pos].min
        body_part = body.byteslice(pos, len)
        write_bytes FrameBytes.body(@id, body_part)
        pos += len
      end
    end

    def basic_consume(queue, tag: "", no_ack: true, exclusive: false, arguments: {},
                      thread_count: 1, &blk)
      write_bytes FrameBytes.basic_consume(@id, queue, tag, no_ack, exclusive, arguments)
      tag, = expect(:basic_consume_ok)
      q = @consumers[tag] = Queue.new
      msgs = Queue.new
      Thread.new { recv_deliveries(tag, q, msgs) }
      if thread_count.zero?
        while (msg = msgs.shift)
          yield msg
        end
      else
        threads = Array.new(thread_count) do
          Thread.new do
            while (msg = msgs.shift)
              blk.call(msg)
            end
          end
        end
        [tag, threads]
      end
    end

    def basic_cancel(consumer_tag)
      write_bytes FrameBytes.basic_cancel(@id, consumer_tag)
    end

    def push(*args)
      @rpc.push(*args)
    end

    private

    def recv_deliveries(consumer_tag, deliver_queue, msgs)
      loop do
        _, delivery_tag, redelivered, exchange, routing_key = deliver_queue.shift || raise(ClosedQueueError)
        body_size, properties = expect(:header)
        body = String.new("", capacity: body_size)
        while body.bytesize < body_size
          body_part = expect(:body)
          body += body_part
        end
        msgs.push Message.new(delivery_tag, exchange, routing_key, properties, body,
                              redelivered, consumer_tag)
      end
    ensure
      msgs.close
    end

    def write_bytes(*bytes)
      raise AMQP::Client::ChannelClosedError, @id, *@closed if @closed

      @connection.write_bytes(*bytes)
    end

    def expect(expected_frame_type)
      frame_type, args = @rpc.shift
      raise AMQP::Client::ChannelClosedError.new(@id, *@closed) if frame_type.nil?
      raise UnexpectedFrame.new(expected_frame_type, frame_type) if frame_type != expected_frame_type

      args
    end
  end
end
