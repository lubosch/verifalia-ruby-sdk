# frozen_string_literal: true

require 'net/http'
require_relative 'job'
require_relative 'overview'
require_relative 'entry'
require_relative 'wait_options'
require_relative 'request'
require_relative 'request_entry'
require_relative 'completion_callback'

module Verifalia
  module EmailValidations
    # Allows to verify email addresses and manage email verification jobs using the Verifalia service.
    class Client
      def initialize(rest_client)
        @rest_client = rest_client
      end

      # Submits a new email validation for processing.
      #
      # By default, this method waits for the completion of the email validation job: pass a +WaitOptions+ to request
      # a different waiting behavior.
      #
      # @param data The input data to verify.
      # @param [nil] quality The desired results quality for this email validation.
      # @param [nil] priority
      # @param [nil] deduplication An optional string with the name of the algorithm our engine will use to scrub the list of email addresses and remove its duplicates. The following values are currently supported: +Off+ does not mark duplicated email addresses, +Safe+ mark duplicated email addresses with an algorithm which guarantees no false duplicates are returned, +Relaxed+ mark duplicated email addresses using a set of relaxed rules which assume the target email service providers are configured with modern settings only. If not specified, Verifalia will not mark duplicated email addresses.
      # @param [nil] name An optional user-defined name for the validation job, for your own reference.
      # @param [nil] retention An optional string with the desired data retention period to observe for the validation job, expressed in the format +dd.hh:mm:ss+ (where +dd.+ days, +hh:+ hours, +mm:+ minutes, +ss:+ seconds); the initial +dd.+ part is added only for periods of more than 24 hours. The value has a minimum of 5 minutes (+0:5:0+) and a maximum of 30 days (+30.0:0:0+): Verifalia will delete the job and its data once its data retention period is over, starting to count when it gets completed. If not specified, Verifalia falls back to the configured data retention period of the submitting user / browser app and, should it be unset, to the configured data retention period of the Verifalia account, with a default of 30 days.
      # @param [nil] completion_callback An optional hash describing the desired completion callback behavior, with the following keys: +url+ A string with the URL Verifalia will invoke once the job results are ready. See how to handle completion callbacks. +version+ An optional string which defines the callback schema our dispatcher must obey when invoking the provided callback URL. Valid values are: +1.0+ the callback includes the completed job ID. +1.1+ everything included with +1.0+ plus the job name. If not specified, Verifalia will use the most recent schema available at the time the used API version was released. +skipServerCertificateValidation+ An optional boolean which allows to skip the server certificate validation for the external callback server, useful for testing purposes at development time when the callback server is using a self-signed certificate.
      # @param [nil] wait_options The options which rule out how to wait for the completion of the email validation.
      # @return [Verifalia::EmailValidations::Job] The submitted validation job (or +nil+ if expired / deleted while waiting for its completion).
      def submit(data,
                 quality: nil,
                 priority: nil,
                 deduplication: nil,
                 name: nil,
                 retention: nil,
                 completion_callback: nil,
                 wait_options: nil)
        # Determine how to handle the submission, based on the type of the argument

        if data.nil?
          raise "data can't be nil."
        elsif data.is_a?(String)
          data = Request.new [(RequestEntry.new data)],
                             quality: quality
        elsif data.is_a? Enumerable
          entries = data.map do |entry|
            case entry
            when String
              # data is an Array[String]
              RequestEntry.new entry.to_s
            when RequestEntry
              # data is an Array[RequestEntry]
              entry
            when Hash
              # data is an Array[{ :inputData, :custom }]

              raise 'Input hash must have an :inputData key.' unless entry.key?(:input_data)

              RequestEntry.new entry[:input_data], entry[:custom]
            else
              raise 'Cannot map input data.'
            end
          end

          data = Request.new entries,
                             quality: quality
        elsif data.is_a?(RequestEntry)
          data = Request.new data,
                             quality: quality
        elsif !data.is_a?(Request)
          raise "Unsupported data type #{data.class}"
        end

        # Completion callback

        if completion_callback.is_a?(Hash)
          completion_callback = Verifalia::EmailValidations::CompletionCallback.new(completion_callback['url'],
                                                                                    completion_callback['version'],
                                                                                    completion_callback['skip_server_certificate_validation'])
        end

        # Send the request to the Verifalia API

        wait_options_or_default = wait_options.nil? ? WaitOptions.default : wait_options

        payload = {
          entries: data.entries.map do |entry|
            {
              inputData: entry.input_data,
              custom: entry.custom
            }
          end,
          quality: quality,
          priority: priority,
          deduplication: deduplication,
          name: name,
          retention: retention,
          callback: (
            unless completion_callback.nil?
              {
                url: completion_callback&.url,
                version: completion_callback&.version,
                skipServerCertificateValidation: completion_callback&.skip_server_certificate_validation
              }
            end
          )
        }.compact.to_json

        response = @rest_client.invoke 'post',
                                       "email-validations?waitTime=#{wait_options_or_default.submission_wait_time}",
                                       {
                                         body: payload,
                                         headers:
                                           {
                                             'Content-Type': 'application/json',
                                             'Accept': 'application/json'
                                           }
                                       }

        if response.status == 202 || response.status == 200
          job = Job.from_json(JSON.parse(response.body))

          return job if wait_options_or_default == WaitOptions.no_wait || job.overview.status == 'Completed'

          return wait_for_completion(job, wait_options_or_default)
        end

        raise "Unexpected HTTP response: #{response.status} #{response.body}"
      end

      # Returns an email validation job previously submitted for processing.
      #
      # By default, this method waits for the completion of the email validation job: pass a +WaitOptions+ to request
      # a different waiting behavior.
      # @param [String] id The ID of the email validation job to retrieve.
      # @param [nil] wait_options The options which rule out how to wait for the completion of the email validation.
      # @return [Verifalia::EmailValidations::Job] The fetched validation job (or +nil+ if not found).
      def get(id, wait_options: nil)
        wait_options_or_default = wait_options.nil? ? WaitOptions.default : wait_options

        response = @rest_client.invoke 'get',
                                       "email-validations/#{id}?waitTime=#{wait_options_or_default.poll_wait_time}"

        return nil if response.status == 404 || response.status == 410

        if response.status == 202 || response.status == 200
          job = Job.from_json(JSON.parse(response.body))

          return job if wait_options_or_default == WaitOptions.no_wait || job.overview.status == 'Completed'

          return wait_for_completion(job, wait_options_or_default)
        end

        raise "Unexpected HTTP response: #{response.status} #{response.body}"
      end

      # Exports the validated entries for a given validation job using the specified output format.
      #
      # Supported formats:
      # - +text/csv+: Comma-Separated Values (CSV)
      # - +application/vnd.openxmlformats-officedocument.spreadsheetml.sheet+: Microsoft Excel (.xlsx)
      # - +application/vnd.ms-excel+: Microsoft Excel 97-2003 (.xls)
      #
      # @param [String] id The ID of the email validation job to retrieve.
      # @param [String] format The MIME content type of the desired output file format.
      # @return [String] The exported data.
      def export(id, format)
        response = @rest_client.invoke 'get',
                                       "email-validations/#{id}/entries",
                                       {
                                         headers:
                                           {
                                             'Accept': format
                                           }
                                       }

        return nil if response.status == 404 || response.status == 410
        return response.body if response.status == 200

        raise "Unexpected HTTP response: #{response.status} #{response.body}"
      end

      # Deletes an email validation job previously submitted for processing.
      # @param [String] id The ID of the email validation job to delete.
      def delete(id)
        response = @rest_client.invoke 'delete',
                                       "email-validations/#{id}"

        return if response.status == 200 || response.status == 410

        raise "Unexpected HTTP response: #{response.status} #{response.body}"
      end

      private

      def wait_for_completion(job, wait_options)
        loop do
          # Fires a progress, since we are not yet completed

          wait_options.progress&.call(job.overview)

          # Wait for the next polling schedule

          wait_options.wait_for_next_poll(job)

          job = get(job.overview.id, wait_options: wait_options)

          return nil if job.nil?
          return job unless job.overview.status == 'InProgress'
        end
      end
    end
  end
end