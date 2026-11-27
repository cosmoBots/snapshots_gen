# frozen_string_literal: true

module SnapshotsGen
  module Importer
    # Nobody must be notified of a migration. While an import runs, and only
    # in this process: Redmine sees no notified events (so it does not even
    # look for recipients), any mail that would still be sent is discarded
    # before it is queued, and every job queued is counted and reported. No
    # setting of the instance is written, so there is nothing to restore if
    # the process dies.
    module Silence
      JOB_EVENTS = /\Aenqueue(_at|_all)?\.active_job\z/.freeze

      module NoNotifiedEvents
        def notified_events
          Silence.active? ? [] : super
        end
      end

      module NoDeliveries
        %i[deliver_later deliver_later! deliver_now deliver_now!].each do |name|
          define_method(name) do |*args, **options|
            return super(*args, **options) unless Silence.active?

            Silence.discarded += 1
            nil
          end
        end
      end

      class << self
        attr_accessor :discarded

        def active?
          @active == true
        end

        def run
          install!
          jobs = Hash.new(0)
          self.discarded = 0
          deliveries = ActionMailer::Base.perform_deliveries
          ActionMailer::Base.perform_deliveries = false
          subscriber = ActiveSupport::Notifications.subscribe(JOB_EVENTS) do |*, payload|
            Array(payload[:job] || payload[:jobs]).each { |job| jobs[job.class.name] += 1 }
          end
          @active = true
          yield
        ensure
          @active = false
          ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
          ActionMailer::Base.perform_deliveries = deliveries unless deliveries.nil?
          report(jobs) if jobs
        end

        private

        def install!
          Setting.singleton_class.prepend(NoNotifiedEvents) unless Setting.singleton_class.include?(NoNotifiedEvents)
          ActionMailer::MessageDelivery.prepend(NoDeliveries) unless ActionMailer::MessageDelivery.include?(NoDeliveries)
        end

        def report(jobs)
          puts "Mails discarded before being queued: #{discarded}" if discarded.positive?
          if jobs.empty?
            puts 'Jobs queued: none (no notification was sent or queued).'
          else
            puts "WARNING: jobs queued during the import: #{jobs.sort.map { |name, count| "#{name} #{count}" }.join(', ')}"
          end
        end
      end
    end
  end
end
