# frozen_string_literal: true

require "json"

module Honker
  # Fired on each scheduler tick that enqueued a job.
  ScheduledFire = Struct.new(:name, :queue, :fire_at, :job_id) do
    def self.from_row(row)
      new(row["name"], row["queue"], row["fire_at"], row["job_id"])
    end
  end

  # Cron-style scheduler. Register tasks with `add`; `tick` fires all
  # boundaries that have elapsed since the last tick and enqueues the
  # resulting jobs. `run(owner:, stop:)` drives the loop under a
  # leader-elected advisory lock.
  class Scheduler
    # Lock name used for leader election in `run`. Constant so all
    # processes contending for leader share a single lock row.
    LEADER_LOCK = "honker-scheduler"

    # TTL on the leader lock. Refreshed from `run` every HEARTBEAT_S;
    # a leader whose refresh fails drops out of the loop so a standby
    # can pick up without waiting the full TTL.
    LOCK_TTL_S = 60

    # Refresh cadence. Balance: too small and every tick is a lock
    # write; too large and a standby waits longer than necessary after
    # a crash. Matches the Rust binding.
    HEARTBEAT_S = 20

    def initialize(db)
      @db = db
    end

    # Register a cron-scheduled task. Idempotent by `name`; registering
    # the same name twice replaces the previous row.
    def add(name:, queue:, cron:, payload:, priority: 0, expires_s: nil)
      @db.db.get_first_row(
        "SELECT honker_scheduler_register(?, ?, ?, ?, ?, ?)",
        [name, queue, cron, JSON.dump(payload), priority, expires_s],
      )
      nil
    end

    # Remove a registered task by name. Returns the count deleted
    # (0 or 1).
    def remove(name)
      @db.db.get_first_row(
        "SELECT honker_scheduler_unregister(?)",
        [name],
      )[0]
    end

    # Fire all due boundaries at `now`. Returns an array of
    # ScheduledFire — one per enqueued job.
    def tick(now = Time.now.to_i)
      rows_json = @db.db.get_first_row(
        "SELECT honker_scheduler_tick(?)",
        [now],
      )[0]
      JSON.parse(rows_json).map { |r| ScheduledFire.from_row(r) }
    end

    # Soonest `next_fire_at` across all tasks, or 0 if no tasks.
    def soonest
      @db.db.get_first_row("SELECT honker_scheduler_soonest()")[0]
    end

    # Run the scheduler loop with leader election. Blocks until `stop`
    # signals. `stop` is any object that responds to `call` (returning
    # truthy to stop) — a common choice is a lambda backed by a Mutex-
    # guarded flag, or an `AtomicBoolean`-like wrapper.
    #
    # Only the process holding the `"honker-scheduler"` advisory lock
    # fires. Standbys sleep 5s and retry. The leader heartbeats every
    # 20s; if the refresh fails (returns 0), we break out of the leader
    # loop immediately so we don't double-fire alongside a new leader
    # that acquired the lock after our TTL elapsed.
    #
    # `owner` distinguishes processes — typically a hostname + pid.
    # On tick error, the lock is released before re-raising so a
    # standby can pick up without waiting the full TTL.
    def run(owner:, stop:)
      stop_fn = normalize_stop(stop)
      until stop_fn.call
        acquired = lock_try_acquire(LEADER_LOCK, owner, LOCK_TTL_S)
        unless acquired
          sleep_with_stop(5, stop_fn)
          next
        end

        begin
          leader_loop(owner, stop_fn)
        ensure
          lock_release(LEADER_LOCK, owner)
        end
      end
      nil
    end

    private

    # Convert a user-supplied stop arg into a zero-arg callable. Accept
    # a proc/lambda, anything with `#call`, a `Queue` (drained = stop),
    # or a mutex-guarded flag object with `#stop?`.
    def normalize_stop(stop)
      return stop if stop.respond_to?(:call) && stop.arity.zero?
      return -> { stop.call } if stop.respond_to?(:call)
      return -> { stop.stop? } if stop.respond_to?(:stop?)

      raise ArgumentError,
            "stop must be callable (proc/lambda) or respond to :stop?"
    end

    # Break sleeps into 1s increments so `stop` is honored promptly
    # without busy-waiting.
    def sleep_with_stop(total_s, stop_fn)
      elapsed = 0
      while elapsed < total_s && !stop_fn.call
        sleep(1)
        elapsed += 1
      end
    end

    def leader_loop(owner, stop_fn)
      last_heartbeat = monotonic_now
      until stop_fn.call
        # tick errors escape up to `run`, which releases the lock in
        # its `ensure` before re-raising.
        tick
        if monotonic_now - last_heartbeat >= HEARTBEAT_S
          still_ours = lock_try_acquire(LEADER_LOCK, owner, LOCK_TTL_S)
          # IMPORTANT: if refresh failed, a new leader has the lock.
          # Break out of the leader loop so we don't double-fire. This
          # is the bug the Rust binding fixed; don't reintroduce it.
          return unless still_ours

          last_heartbeat = monotonic_now
        end
        sleep(1)
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def lock_try_acquire(name, owner, ttl_s)
      @db.db.get_first_row(
        "SELECT honker_lock_acquire(?, ?, ?)",
        [name, owner, ttl_s],
      )[0] == 1
    end

    def lock_release(name, owner)
      @db.db.get_first_row(
        "SELECT honker_lock_release(?, ?)",
        [name, owner],
      )[0] == 1
    end
  end
end
