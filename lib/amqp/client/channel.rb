# frozen_string_literal: true

require_relative "./message"

module AMQP
  class Client
    class Connection
      # AMQP Channel
      class Channel
        def initialize(connection, id)
          @connection = connection
          @id = id
          @replies = ::Queue.new
          @consumers = {}
          @closed = nil
          @open = false
          @on_return = nil
          @confirm = nil
          @unconfirmed = ::Queue.new
          @unconfirmed_empty = ::Queue.new
          @basic_gets = ::Queue.new
        end

        def inspect
          "#<#{self.class} @id=#{@id} @open=#{@open} @closed=#{@closed} confirm_selected=#{!@confirm.nil?}"\
            " consumer_count=#{@consumers.size} replies_count=#{@replies.size} unconfirmed_count=#{@unconfirmed.size}>"
        end

        # Channel ID
        # @return [Integer]
        attr_reader :id

        # Open the channel (called from Connection)
        # @return [Channel] self
        def open
          return self if @open

          @open = true
          write_bytes FrameBytes.channel_open(@id)
          expect(:channel_open_ok)
          self
        end

        # Gracefully close a connection
        # @return [void]
        def close(reason: "", code: 200)
          return if @closed

          write_bytes FrameBytes.channel_close(@id, reason, code)
          @closed = [code, reason]
          expect :channel_close_ok
          @replies.close
          @basic_gets.close
          @unconfirmed_empty.close
          @consumers.each_value(&:close)
        end

        # Called when channel is closed by server
        # @return [void]
        def closed!(code, reason, classid, methodid)
          @closed = [code, reason, classid, methodid]
          @replies.close
          @basic_gets.close
          @unconfirmed_empty.close
          @consumers.each_value(&:close)
        end

        # Declare an exchange
        # @return [void]
        def exchange_declare(name, type, passive: false, durable: true, auto_delete: false, internal: false, arguments: {})
          write_bytes FrameBytes.exchange_declare(@id, name, type, passive, durable, auto_delete, internal, arguments)
          expect :exchange_declare_ok
        end

        # Delete an exchange
        # @return [void]
        def exchange_delete(name, if_unused: false, no_wait: false)
          write_bytes FrameBytes.exchange_delete(@id, name, if_unused, no_wait)
          expect :exchange_delete_ok
        end

        # Bind an exchange to another exchange
        # @return [void]
        def exchange_bind(destination, source, binding_key, arguments: {})
          write_bytes FrameBytes.exchange_bind(@id, destination, source, binding_key, false, arguments)
          expect :exchange_bind_ok
        end

        # Unbind an exchange from another exchange
        # @return [void]
        def exchange_unbind(destination, source, binding_key, arguments: {})
          write_bytes FrameBytes.exchange_unbind(@id, destination, source, binding_key, false, arguments)
          expect :exchange_unbind_ok
        end

        # Response from declaring a Queue
        QueueOk = Struct.new(:queue_name, :message_count, :consumer_count)

        # Create a queue (operation is idempotent)
        # @return [QueueOk]
        def queue_declare(name = "", passive: false, durable: true, exclusive: false, auto_delete: false, arguments: {})
          durable = false if name.empty?
          exclusive = true if name.empty?
          auto_delete = true if name.empty?

          write_bytes FrameBytes.queue_declare(@id, name, passive, durable, exclusive, auto_delete, arguments)
          name, message_count, consumer_count = expect(:queue_declare_ok)

          QueueOk.new(name, message_count, consumer_count)
        end

        # Delete a queue
        # @return [Integer] Number of messages in queue when deleted
        def queue_delete(name, if_unused: false, if_empty: false, no_wait: false)
          write_bytes FrameBytes.queue_delete(@id, name, if_unused, if_empty, no_wait)
          message_count, = expect :queue_delete
          message_count
        end

        # Bind a queue to an exchange
        # @return [void]
        def queue_bind(name, exchange, binding_key, arguments: {})
          write_bytes FrameBytes.queue_bind(@id, name, exchange, binding_key, false, arguments)
          expect :queue_bind_ok
        end

        # Purge a queue
        # @return [void]
        def queue_purge(name, no_wait: false)
          write_bytes FrameBytes.queue_purge(@id, name, no_wait)
          expect :queue_purge_ok unless no_wait
        end

        # Unbind a queue from an exchange
        # @return [void]
        def queue_unbind(name, exchange, binding_key, arguments: {})
          write_bytes FrameBytes.queue_unbind(@id, name, exchange, binding_key, arguments)
          expect :queue_unbind_ok
        end

        # Get a message from a queue (by polling)
        # @param queue_name [String]
        # @param no_ack [Boolean] When false the message have to be manually acknowledged
        # @return [Message] If the queue had a message
        # @return [nil] If the queue doesn't have any messages
        def basic_get(queue_name, no_ack: true)
          write_bytes FrameBytes.basic_get(@id, queue_name, no_ack)
          case (msg = @basic_gets.pop)
          when Message then msg
          when :basic_get_empty then nil
          when nil              then raise AMQP::Client::Error::ChannelClosed.new(@id, *@closed)
          end
        end

        # Publishes a message to an exchange
        # @param body [String]
        # @param exchange [String]
        # @param routing_key [String]
        # @return [nil]
        def basic_publish(body, exchange, routing_key, **properties)
          frame_max = @connection.frame_max - 8
          id = @id
          mandatory = properties.delete(:mandatory) || false
          case properties.delete(:persistent)
          when true then properties[:delivery_mode] = 2
          when false then properties[:delivery_mode] = 1
          end

          if body.bytesize.between?(1, frame_max)
            write_bytes FrameBytes.basic_publish(id, exchange, routing_key, mandatory),
                        FrameBytes.header(id, body.bytesize, properties),
                        FrameBytes.body(id, body)
            @unconfirmed.push @confirm += 1 if @confirm
            return
          end

          write_bytes FrameBytes.basic_publish(id, exchange, routing_key, mandatory),
                      FrameBytes.header(id, body.bytesize, properties)
          pos = 0
          while pos < body.bytesize # split body into multiple frame_max frames
            len = [frame_max, body.bytesize - pos].min
            body_part = body.byteslice(pos, len)
            write_bytes FrameBytes.body(id, body_part)
            pos += len
          end
          @unconfirmed.push @confirm += 1 if @confirm
          nil
        end

        # Publish a message and block until the message has confirmed it has received it
        # @param body [String]
        # @param exchange [String]
        # @param routing_key [String]
        # @return [Boolean] True if the message was successfully published
        def basic_publish_confirm(body, exchange, routing_key, **properties)
          confirm_select(no_wait: true)
          basic_publish(body, exchange, routing_key, **properties)
          wait_for_confirms
        end

        # Consume messages from a queue
        # @param queue [String] Name of the queue to subscribe to
        # @param tag [String] Custom consumer tag, will be auto assigned by the server if empty
        # @param no_ack [Boolean] When false messages have to be manually acknowledged (or rejected)
        # @param exclusive [Boolean] When true only a single consumer can consume from the queue at a time
        # @param arguments [Hash] Custom arguments to the consumer
        # @param worker_threads [Integer] Number of threads processing messages, 0 means that the thread calling this method will be blocked
        # @yield [Message] Delivered message from the queue
        # @return [Array<(String, Array<Thread>)>] Returns consumer_tag and an array of worker threads
        # @return [nil] When worker_threas is 0 the method will return when the consumer is cancelled
        def basic_consume(queue, tag: "", no_ack: true, exclusive: false, arguments: {}, worker_threads: 1)
          write_bytes FrameBytes.basic_consume(@id, queue, tag, no_ack, exclusive, arguments)
          tag, = expect(:basic_consume_ok)
          q = @consumers[tag] = ::Queue.new
          if worker_threads.zero?
            loop do
              yield (q.pop || break)
            end
            nil
          else
            threads = Array.new(worker_threads) do
              Thread.new do
                loop do
                  yield (q.pop || break)
                end
              end
            end
            [tag, threads]
          end
        end

        # Cancel/abort/stop a consumer
        # @param consumer_tag [String] Tag of the consumer to cancel
        # @param no_wait [Boolean] Will wait for a confirmation from the server that the consumer is cancelled
        # @return [nil]
        def basic_cancel(consumer_tag, no_wait: false)
          consumer = @consumers.fetch(consumer_tag)
          return if consumer.closed?

          write_bytes FrameBytes.basic_cancel(@id, consumer_tag)
          expect(:basic_cancel_ok) unless no_wait
          consumer.close
          nil
        end

        # Specify how many messages to prefetch for consumers with `no_ack: false`
        # @param prefetch_count [Integer] Number of messages to maxium have in flight
        # @return [void]
        def basic_qos(prefetch_count, prefetch_size: 0, global: false)
          write_bytes FrameBytes.basic_qos(@id, prefetch_size, prefetch_count, global)
          expect :basic_qos_ok
        end

        # Acknowledge a message
        # @param delivery_tag [Integer] The delivery tag of the message to acknowledge
        # @return [void]
        def basic_ack(delivery_tag, multiple: false)
          write_bytes FrameBytes.basic_ack(@id, delivery_tag, multiple)
        end

        # Negatively acknowledge a message
        # @param delivery_tag [Integer] The delivery tag of the message to acknowledge
        # @param multiple [Boolean] Nack all messages up to this message
        # @param requeue [Boolean] Requeue the message
        # @return [void]
        def basic_nack(delivery_tag, multiple: false, requeue: false)
          write_bytes FrameBytes.basic_nack(@id, delivery_tag, multiple, requeue)
        end

        # Reject a message
        # @param delivery_tag [Integer] The delivery tag of the message to acknowledge
        # @param requeue [Boolean] Requeue the message into the queue again
        # @return [void]
        def basic_reject(delivery_tag, requeue: false)
          write_bytes FrameBytes.basic_reject(@id, delivery_tag, requeue)
        end

        def basic_recover(requeue: false)
          write_bytes FrameBytes.basic_recover(@id, requeue: requeue)
          expect :basic_recover_ok
        end

        # Put the channel in confirm mode, each published message will then be confirmed by the server
        # @param no_wait [Boolean] If false the method will block until the server has confirmed the request
        # @return [nil]
        def confirm_select(no_wait: false)
          return if @confirm

          write_bytes FrameBytes.confirm_select(@id, no_wait)
          expect :confirm_select_ok unless no_wait
          @confirm = 0
          nil
        end

        # Block until all publishes messages are confirmed
        # @return [Boolean] True if all message where positivly acknowledged, false if not
        def wait_for_confirms
          return true if @unconfirmed.empty?

          case @unconfirmed_empty.pop
          when true then true
          when false then false
          else raise AMQP::Client::Error::ChannelClosed.new(@id, *@closed)
          end
        end

        # Called by Connection when received ack/nack from server
        # @api private
        def confirm(args)
          ack_or_nack, delivery_tag, multiple = *args
          loop do
            tag = @unconfirmed.pop(true)
            break if tag == delivery_tag
            next if multiple && tag < delivery_tag

            @unconfirmed << tag # requeue
          rescue ThreadError
            break
          end
          return unless @unconfirmed.empty?

          @unconfirmed_empty.num_waiting.times do
            @unconfirmed_empty << (ack_or_nack == :ack)
          end
        end

        # Put the channel in transaction mode
        # @return [nil]
        def tx_select
          write_bytes FrameBytes.tx_select(@id)
          expect :tx_select_ok
        end

        # Commit a transaction
        # @return [nil]
        def tx_commit
          write_bytes FrameBytes.tx_commit(@id)
          expect :tx_commit_ok
        end

        # Rollback a transaction
        # @return [nil]
        def tx_rollback
          write_bytes FrameBytes.tx_rollback(@id)
          expect :tx_rollback_ok
        end

        # @yield [ReturnMessage] Messages returned by the server when a publish has failed
        def on_return(&block)
          @on_return = block
        end

        # @api private
        def reply(args)
          @replies.push(args)
        end

        # @api private
        def message_returned(reply_code, reply_text, exchange, routing_key)
          @next_msg = ReturnMessage.new(reply_code, reply_text, exchange, routing_key, nil, "")
        end

        # @api private
        def message_delivered(consumer_tag, delivery_tag, redelivered, exchange, routing_key)
          @next_msg = Message.new(self, delivery_tag, exchange, routing_key, nil, "", redelivered, consumer_tag)
        end

        # @api private
        def basic_get_empty
          @basic_gets.push :basic_get_empty
        end

        # @api private
        def header_delivered(body_size, properties)
          @next_msg.properties = properties
          if body_size.zero?
            next_message_finished!
          else
            @next_body = StringIO.new(String.new(capacity: body_size))
            @next_body_size = body_size
          end
        end

        # @api private
        def body_delivered(body_part)
          @next_body.write(body_part)
          return unless @next_body.pos == @next_body_size

          @next_msg.body = @next_body.string
          next_message_finished!
        end

        # @api private
        def close_consumer(tag)
          @consumers.fetch(tag).close
        end

        private

        def next_message_finished!
          next_msg = @next_msg
          if next_msg.is_a? ReturnMessage
            if @on_return
              Thread.new { @on_return.call(next_msg) }
            else
              warn "AMQP-Client message returned: #{msg.inspect}"
            end
          elsif next_msg.consumer_tag.nil?
            @basic_gets.push next_msg
          else
            Thread.pass until (consumer = @consumers[next_msg.consumer_tag])
            consumer.push next_msg
          end
        ensure
          @next_msg = @next_body = @next_body_size = nil
        end

        def write_bytes(*bytes)
          raise AMQP::Client::Error::ChannelClosed.new(@id, *@closed) if @closed

          @connection.write_bytes(*bytes)
        end

        def expect(expected_frame_type)
          frame_type, *args = @replies.pop
          raise AMQP::Client::Error::ChannelClosed.new(@id, *@closed) if frame_type.nil?
          raise AMQP::Client::Error::UnexpectedFrame.new(expected_frame_type, frame_type) unless frame_type == expected_frame_type

          args
        end
      end
    end
  end
end
