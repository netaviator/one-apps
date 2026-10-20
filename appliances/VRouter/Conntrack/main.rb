# frozen_string_literal: true

require 'erb'
require_relative '../vrouter.rb'
require_relative 'settings.rb'

module Service
module Conntrack
    extend self

    DEPENDS_ON = %w[Service::Failover]

    CONF_PATH  = '/etc/conntrackd/conntrackd.conf'
    HOOK_NAME  = '20-conntrack'
    RC_LOG     = '/var/log/one-appliance/conntrackd-rc.log'
    SYSCTL     = '97-conntrack-sync.conf'
    MODULES    = %w[nf_conntrack nfnetlink nf_conntrack_netlink].freeze

    FAILOVER_STATE = '/run/one-failover.state'
    ENV_FILE       = '/run/one-context/one_env'
    SYSCTL_LIBERAL = 'net.netfilter.nf_conntrack_tcp_be_liberal'
    SYSCTL_CONTENT = "#{SYSCTL_LIBERAL} = 1\n".freeze

    # One-failover kills a hook after 30 s (and for `down` the stock services
    # are only stopped after the hooks). Every conntrackd call runs under
    # `timeout -k KILL_GRACE` (TERM after N s, KILL KILL_GRACE s later) and no
    # step is started once HOOK_BUDGET seconds, counted from the start of the
    # Ruby code, are used up, so the steps end at HOOK_BUDGET + KILL_GRACE at
    # the latest. HOOK_CAP is a hard limit around the whole hook process, it
    # also covers the start-up of Ruby, which the budget does not count.
    # Worst case: HOOK_CAP + KILL_GRACE = 22 s.
    HOOK_BUDGET   = 18
    HOOK_CAP      = 21
    KILL_GRACE    = 1
    STEP_TIMEOUT  = 3
    START_TIMEOUT = 8

    # Steps of the official primary-backup.sh from conntrack-tools.
    UP_FLAGS   = %w[c f R B].freeze # commit external cache, flush caches, resync internal, bulk update
    DOWN_FLAGS = %w[t n].freeze     # shorten kernel timers, request resync from the peer

    TEMPLATE = <<~CONF
        # Managed by the VRouter appliance (Service::Conntrack), do not edit.
        Sync {
        <%- if s.mode == 'FTFW' -%>
            Mode FTFW {
                ResendQueueSize 131072
                CommitTimeout 180
                PurgeTimeout 5
                ACKWindowSize 300
                DisableExternalCache Off
            }
        <%- else -%>
            Mode NOTRACK {
                DisableExternalCache Off
            }
        <%- end -%>
        <%- if s.peer.nil? -%>
            Multicast {
                IPv4_address <%= s.group %>
                Group <%= s.port %>
                IPv4_interface <%= s.local_ip %>
                Interface <%= s.interface %>
                SndSocketBuffer 1249280
                RcvSocketBuffer 1249280
                Checksum on
            }
        <%- else -%>
            UDP {
                IPv4_address <%= s.local_ip %>
                IPv4_Destination_Address <%= s.peer %>
                Port <%= s.port %>
                Interface <%= s.interface %>
                SndSocketBuffer 1249280
                RcvSocketBuffer 1249280
                Checksum on
            }
        <%- end -%>
        }
        General {
            HashSize <%= s.hash_size %>
            HashLimit <%= s.hash_limit %>
            LogFile /var/log/one-appliance/conntrackd.log
            LockFile /var/lock/conntrack.lock
            UNIX {
                Path /var/run/conntrackd.ctl
            }
            NetlinkBufferSize 262142
            NetlinkBufferSizeMaxGrowth 655355
            Filter From Userspace {
                Protocol Accept {
        <%- s.protocols.each do |protocol| -%>
                    <%= protocol == 'ICMP' ? 'icmp' : protocol %>
        <%- end -%>
                }
                Address Ignore {
        <%- s.ignore.each do |address| -%>
                    IPv4_address <%= address %>
        <%- end -%>
                }
            }
        }
    CONF

    def enabled?
        env :ONEAPP_VNF_CONNTRACK_SYNC_ENABLED, 'NO'
    end

    def settings
        Parser.parse
    end

    def render_conf(settings)
        ERB.new(TEMPLATE, trim_mode: '-').result_with_hash(s: settings)
    end

    # The context is deliberately not sourced by the shell (a $(...) or a
    # backtick in a context value would run as root): run_hook loads it in Ruby.
    def hook_script(ruby: '/usr/bin/ruby', helpers: '/etc/one-appliance/lib/helpers.rb', env_file: ENV_FILE)
        <<~HOOK
            #!/bin/sh
            # Called by one-failover with "up" (MASTER) or "down" (BACKUP).
            exec timeout -k #{KILL_GRACE} #{HOOK_CAP} #{ruby} -r #{helpers} -r #{__FILE__} -e 'exit(Service::Conntrack.run_hook(ARGV[0], #{env_file.dump}) ? 0 : 1)' "$1"
        HOOK
    end

    # Entry point of the hook script. one-failover loads the context only on
    # `up`, so on `down` the environment may be empty: load it here (parsed,
    # never evaluated by a shell).
    def run_hook(direction, env_file = ENV_FILE)
        load_env env_file if File.readable?(env_file)
        ha_transition direction
    rescue StandardError => e
        msg :error, "Conntrack::run_hook(#{direction}): #{e.class}: #{e.message}"
        false
    end

    def install(initdir: '/etc/init.d', hooks_dir: '/etc/one-appliance/ha-hooks.d')
        msg :info, 'Conntrack::install'

        puts bash 'apk --no-cache add conntrack-tools conntrack-tools-openrc ruby'

        # The hook is a no-op while the feature is off, so it is always installed.
        file "#{hooks_dir}/#{HOOK_NAME}", hook_script, mode: 'u=rwx,go=rx', overwrite: true

        toggle [:disable, :update, :stop]
    end

    def configure(conf_dir: File.dirname(CONF_PATH), sysctl_dir: '/etc/sysctl.d', modules_file: '/etc/modules',
                  state_path: FAILOVER_STATE)
        msg :info, 'Conntrack::configure'

        warn_unknown_boolean
        return stop_sync(sysctl_dir) unless enabled?

        apply_config conf_dir, sysctl_dir, modules_file, state_path
    rescue ConfigError => e
        # An invalid optional feature must never take the router down.
        msg :error, "Conntrack::configure: #{e.message}; the synchronisation stays off"
        stop_sync sysctl_dir
    rescue StandardError => e
        # Nor may an unexpected error stop service.rb (Keepalived, the other modules).
        msg :error, "Conntrack::configure: #{e.class}: #{e.message}; the synchronisation stays off"
        stop_sync sysctl_dir
    end

    def bootstrap
        msg :info, 'Conntrack::bootstrap'
    end

    # Called by /etc/one-appliance/ha-hooks.d/20-conntrack with "up" (MASTER) or
    # "down" (BACKUP). Never raises; returns false if any step failed so that
    # one-failover logs it.
    def ha_transition(direction)
        direction = direction.to_s
        unless %w[up down].include?(direction)
            msg :error, "Conntrack::ha_transition: unknown direction #{direction.inspect}"
            return false
        end
        return true unless active?

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HOOK_BUDGET
        direction == 'up' ? master_steps(deadline) : backup_steps(deadline)
    rescue StandardError => e
        msg :error, "Conntrack::ha_transition(#{direction}): #{e.class}: #{e.message}"
        false
    end

    private

    def active?
        return false unless enabled?

        settings
        true
    rescue ConfigError => e
        msg :warn, "Conntrack::ha_transition: #{e.message}; nothing to do"
        false
    end

    # Commit the external cache (flows of the former master) into the kernel,
    # then rebuild the caches and send a bulk update to the new backup. A dead
    # daemon is started first (the control calls would fail fast otherwise).
    def master_steps(deadline)
        [ensure_running(deadline), *UP_FLAGS.map { |flag| ctl flag, deadline }].all?
    end

    def backup_steps(deadline)
        [ensure_running(deadline), *DOWN_FLAGS.map { |flag| ctl flag, deadline }].all?
    end

    def ensure_running(deadline)
        ctl('s', deadline) || start_daemon(deadline)
    end

    def ctl(flag, deadline)
        step "conntrackd -C #{CONF_PATH} -#{flag}", STEP_TIMEOUT, deadline
    end

    def start_daemon(deadline)
        # `&&`: a failed start must fail the step, not the status of sleep.
        # The sleep gives the daemon time to create its control socket.
        start = "rc-service conntrackd start </dev/null >>#{RC_LOG} 2>&1 && sleep 1"
        step "sh -c '#{start}'", START_TIMEOUT, deadline, label: 'rc-service conntrackd start'
    end

    def step(command, limit, deadline, label: command)
        left = (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).floor
        if left < 1
            msg :error, "Conntrack::ha_transition: hook budget used up, skipping #{label}"
            return false
        end

        bash "timeout -k #{KILL_GRACE} #{[limit, left].min} #{command}", terminate: false
        true
    rescue StandardError => e
        msg :error, "Conntrack::ha_transition: #{label} failed: #{e.message.lines.first&.strip}"
        false
    end

    # A restarted daemon has empty caches. A BACKUP asks the peer for a full
    # resync, a MASTER rebuilds its internal cache from the kernel table and
    # sends a bulk update. The role is the one Failover last saved; unknown
    # (boot, before the first VRRP event) means the hook will do it later.
    def resync_after_start(state_path)
        flags = { 'BACKUP' => %w[n], 'MASTER' => %w[R B] }.fetch(saved_role(state_path), [])
        return if flags.empty?

        safely 'sleep 1' # control socket
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HOOK_BUDGET
        ok = flags.map { |flag| ctl flag, deadline }.all?
        msg :error, 'Conntrack::configure: resync request after the (re)start failed' unless ok
    end

    def saved_role(state_path)
        JSON.parse(File.read(state_path))['state'].to_s.upcase
    rescue SystemCallError, JSON::ParserError, NoMethodError, TypeError
        'UNKNOWN'
    end

    def apply_config(conf_dir, sysctl_dir, modules_file, state_path)
        conf     = settings
        rendered = render_conf(conf)
        changed  = conf_changed?(File.join(conf_dir, File.basename(CONF_PATH)), rendered)

        write_files rendered, conf_dir, sysctl_dir, modules_file
        prepare_kernel
        # A restart empties the caches (on a BACKUP: the replicated flows), so
        # only restart for a changed configuration; otherwise just make sure it runs.
        started = safe_toggle [:enable, changed ? :restart : :start]
        resync_after_start state_path if started && changed
    end

    def conf_changed?(path, rendered)
        !File.file?(path) || File.read(path) != rendered
    end

    # Synchronisation off (disabled or invalid): stop it and undo what this
    # module changed in the kernel. /etc/modules entries are harmless and stay.
    def stop_sync(sysctl_dir)
        safe_toggle %i[stop disable]
        cleanup_sysctl sysctl_dir
    rescue StandardError => e
        msg :error, "Conntrack: cleanup failed (#{e.class}): #{e.message.lines.first&.strip}"
    end

    # Relaxed TCP window checking is only needed by conntrackd. Reset it to the
    # kernel default, but only if the sysctl file is ours (not someone else's value).
    def cleanup_sysctl(sysctl_dir)
        path = File.join(sysctl_dir, SYSCTL)
        return unless File.file?(path) && File.read(path) == SYSCTL_CONTENT

        File.delete path
        safely "sysctl -w #{SYSCTL_LIBERAL}=0"
    end

    # Only a literal YES/1 enables (helpers.rb `env`); say so for other spellings.
    def warn_unknown_boolean
        raw = ENV.fetch('ONEAPP_VNF_CONNTRACK_SYNC_ENABLED', '')
        return if raw.empty? || %w[YES NO 1 0].include?(raw.upcase)

        msg :warn, "Conntrack::configure: ONEAPP_VNF_CONNTRACK_SYNC_ENABLED=#{raw.inspect} is not YES/NO/1/0, treated as NO"
    end

    def write_files(rendered, conf_dir, sysctl_dir, modules_file)
        file File.join(conf_dir, File.basename(CONF_PATH)), rendered, mode: 'u=rw,go=r', overwrite: true
        file File.join(sysctl_dir, SYSCTL), SYSCTL_CONTENT, mode: 'u=rw,go=r', overwrite: true
        persist_modules modules_file
    end

    # Alpine loads /etc/modules at boot (openrc "modules" service).
    def persist_modules(path)
        present = File.exist?(path) ? File.read(path).lines.map(&:strip) : []
        missing = MODULES - present
        return if missing.empty?

        existing = File.exist?(path) ? File.read(path) : ''
        existing += "\n" unless existing.empty? || existing.end_with?("\n")
        file path, existing + missing.map { |m| "#{m}\n" }.join, mode: 'u=rw,go=r', overwrite: true
    end

    # conntrackd's init script refuses to start without the conntrack sysctls
    # (they exist only with nf_conntrack loaded) and with TCP window tracking on.
    def prepare_kernel
        MODULES.each { |mod| safely("modprobe #{mod}") }
        safely "sysctl -w #{SYSCTL_LIBERAL}=1"
    end

    def safely(command)
        bash command, terminate: false
    rescue StandardError => e
        msg :error, "Conntrack: '#{command}' failed: #{e.message.lines.first&.strip}"
    end

    def safe_toggle(operations)
        toggle operations
        true
    rescue StandardError => e
        msg :error, "Conntrack: service change failed (#{e.class}): #{e.message.lines.first&.strip}"
        false
    end

    public

    def toggle(operations)
        operations.each do |op|
            msg :info, "Conntrack::toggle([:#{op}])"
            case op
            when :enable  then puts bash 'rc-update add conntrackd default'
            when :disable then puts bash 'rc-update del conntrackd default ||:'
            when :update  then puts bash 'rc-update -u'
            when :stop    then puts bash "rc-service conntrackd stop </dev/null >>#{RC_LOG} 2>&1 ||:"
            else puts bash "rc-service conntrackd #{op} </dev/null >>#{RC_LOG} 2>&1"
            end
        end
    end
end
end
