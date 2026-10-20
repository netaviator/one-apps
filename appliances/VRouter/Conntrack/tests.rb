# frozen_string_literal: true

require 'rspec'
require 'tmpdir'
require_relative 'main.rb'

def clear_env
    ENV.delete_if do |name|
        name.start_with?('ETH') || name.include?('VROUTER_') || name.include?('_VNF_') || name.start_with?('ONEAPP_')
    end
end

RSpec.describe Service::Conntrack do
    let(:dir)       { Dir.mktmpdir }
    let(:conf_dir)  { File.join(dir, 'conntrackd') }
    let(:conf_path) { File.join(conf_dir, 'conntrackd.conf') }
    let(:sysctl_d)  { File.join(dir, 'sysctl.d') }
    let(:modules)   { File.join(dir, 'modules') }
    let(:initdir)   { File.join(dir, 'init.d') }
    let(:hooks_dir) { File.join(dir, 'ha-hooks.d') }
    let(:commands)  { [] }
    let(:errors)    { [] }
    let(:warnings)  { [] }
    let(:state_path) { File.join(dir, 'one-failover.state') }
    let(:failing)   { [] } # substrings of commands that make `bash` raise

    before do
        clear_env
        allow(described_class).to receive(:msg) do |level, text|
            errors << text if level == :error
            warnings << text if level == :warn
        end
        allow(described_class).to receive(:bash) do |cmd, **|
            commands << cmd
            raise "1: simulated failure of #{cmd}" if failing.any? { |f| cmd.include?(f) }

            ''
        end
    end

    after do
        FileUtils.remove_entry(dir)
        clear_env
    end

    # Two-NIC router, eth2 is the management NIC (own VRF).
    def router_env(extra = {})
        {
            'ONEAPP_VNF_CONNTRACK_SYNC_ENABLED' => 'YES',
            'ONEAPP_VNF_KEEPALIVED_INTERFACES' => 'eth0 eth1',
            'ETH0_IP' => '10.2.11.67', 'ETH0_MASK' => '255.255.255.0',
            'ETH1_IP' => '10.2.12.67', 'ETH1_MASK' => '255.255.255.0',
            'ETH2_IP' => '172.20.0.5', 'ETH2_MASK' => '255.255.255.0',
            'ETH2_VROUTER_MANAGEMENT' => 'YES',
            'ONEAPP_VROUTER_ETH0_VIP0' => '10.2.11.69'
        }.merge(extra).each { |k, v| ENV[k] = v }
    end

    def configure!
        described_class.configure(conf_dir: conf_dir, sysctl_dir: sysctl_d, modules_file: modules, state_path: state_path)
    end

    describe 'defaults (feature off)' do
        it 'is disabled' do
            expect(described_class.enabled?).to be false
        end

        it 'writes nothing and stops the service on configure' do
            configure!

            expect(File.exist?(conf_path)).to be false
            expect(File.exist?(modules)).to be false
            expect(Dir.exist?(sysctl_d)).to be false
            expect(commands.join("\n")).to include('rc-service conntrackd stop')
            expect(commands.join("\n")).to include('rc-update del conntrackd')
            expect(commands.join("\n")).not_to include('modprobe')
        end

        it 'makes both hook directions a no-op that does not touch conntrackd' do
            expect(described_class.ha_transition('up')).to be true
            expect(described_class.ha_transition('down')).to be true
            expect(commands).to be_empty
        end

        it 'removes its own sysctl file and resets the TCP window check when the module is disabled' do
            FileUtils.mkdir_p sysctl_d
            File.write(File.join(sysctl_d, '97-conntrack-sync.conf'), described_class::SYSCTL_CONTENT)

            configure!

            expect(File.exist?(File.join(sysctl_d, '97-conntrack-sync.conf'))).to be false
            expect(commands.join("\n")).to include('sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=0')
        end

        it 'leaves a sysctl file alone that this module did not write' do
            FileUtils.mkdir_p sysctl_d
            path = File.join(sysctl_d, '97-conntrack-sync.conf')
            File.write(path, "net.netfilter.nf_conntrack_tcp_be_liberal = 1\n# mine\n")

            configure!

            expect(File.read(path)).to include('# mine')
            expect(commands.join("\n")).not_to include('sysctl -w')
        end

        it 'also cleans up when the configuration is invalid' do
            router_env('ONEAPP_VNF_CONNTRACK_SYNC_MODE' => 'BOGUS')
            FileUtils.mkdir_p sysctl_d
            File.write(File.join(sysctl_d, '97-conntrack-sync.conf'), described_class::SYSCTL_CONTENT)

            configure!

            expect(File.exist?(File.join(sysctl_d, '97-conntrack-sync.conf'))).to be false
        end

        it 'does not break when stopping the service fails' do
            failing << 'rc-service'
            expect { configure! }.not_to raise_error
        end
    end

    describe 'install' do
        it 'installs the packages and the hook, leaves the service disabled' do
            described_class.install(initdir: initdir, hooks_dir: hooks_dir)

            expect(commands.first).to match(/apk --no-cache add .*conntrack-tools .*conntrack-tools-openrc/)
            hook = File.join(hooks_dir, '20-conntrack')
            expect(File.executable?(hook)).to be true
            expect(File.read(hook)).to eq described_class.hook_script
            expect(commands.join("\n")).to include('rc-update del conntrackd default')
        end

        it 'ships a hook that never sources the context with the shell' do
            hook = described_class.hook_script

            expect(hook).to start_with("#!/bin/sh\n")
            expect(hook).not_to match(%r{^\s*(\.|source)\s}) # a $(...) in a context value would run as root
            expect(hook).to include('Service::Conntrack.run_hook(ARGV[0]')
            expect(hook).to include('"$1"')
        end

        it 'ships a hook with a hard cap that includes the Ruby start-up' do
            expect(described_class.hook_script).to match(/exec timeout -k #{described_class::KILL_GRACE} #{described_class::HOOK_CAP} /)
        end
    end

    describe 'validation' do
        def message_for(extra)
            router_env(extra)
            described_class.settings
            nil
        rescue Service::Conntrack::ConfigError => e
            e.message
        end

        {
            'ONEAPP_VNF_CONNTRACK_SYNC_MODE' => [['ALARM', /MODE/], ['', nil]],
            'ONEAPP_VNF_CONNTRACK_SYNC_PEER' => [['nope', /PEER/], ['10.2.12.0/24', /PEER/], ['10.2.11.67', /PEER.*own/],
                                                 ['fe80::1', /PEER/], ['127.0.0.2', /PEER/], ['0.0.0.0', /PEER/],
                                                 ['224.0.0.5', /PEER/], ['255.255.255.255', /PEER/],
                                                 ['   ', nil], ['10.2.12.68', nil]],
            'ONEAPP_VNF_CONNTRACK_SYNC_PORT ' => [['  ', nil]],
            'ONEAPP_VNF_CONNTRACK_SYNC_PROTOCOLS ' => [[" \t", nil]],
            'ONEAPP_VNF_CONNTRACK_SYNC_HASH_LIMIT ' => [['  ', nil]],
            'ONEAPP_VNF_CONNTRACK_SYNC_INTERFACE' => [['eth9', /INTERFACE/], ['lo', /INTERFACE/], ['eth1', nil]],
            'ONEAPP_VNF_CONNTRACK_SYNC_PORT' => [['0', /PORT/], ['70000', /PORT/], ['abc', /PORT/], ['4000', nil]],
            'ONEAPP_VNF_CONNTRACK_SYNC_MCAST_GROUP' => [['10.0.0.1', /MCAST_GROUP/], ['x', /MCAST_GROUP/], ['225.0.0.60', nil]],
            'ONEAPP_VNF_CONNTRACK_SYNC_PROTOCOLS' => [['TCP XYZ', /PROTOCOLS/], ['tcp,udp', nil]],
            'ONEAPP_VNF_CONNTRACK_SYNC_HASH_LIMIT' => [['10', /HASH_LIMIT/], ['99999999', /HASH_LIMIT/], ['1.5', /HASH_LIMIT/], ['32768', nil]],
            'ONEAPP_VNF_CONNTRACK_SYNC_IGNORE' => [['10.1.1.0/33', /IGNORE/], ['foo', /IGNORE/], ['10.9.9.0/24, 10.8.8.8', nil]]
        }.each do |name, cases|
            cases.each do |value, pattern|
                if pattern
                    it "rejects #{name.strip}=#{value.inspect}" do
                        expect(message_for(name => value)).to match(pattern)
                    end
                else
                    it "accepts #{name.strip}=#{value.inspect}" do
                        expect(message_for(name.strip => value)).to be_nil
                    end
                end
            end
        end

        it 'fails when no interface can be derived' do
            ENV['ONEAPP_VNF_CONNTRACK_SYNC_ENABLED'] = 'YES'
            expect { described_class.settings }.to raise_error(Service::Conntrack::ConfigError, /INTERFACE/)
        end

        it 'does not raise from configure, logs, and keeps the service stopped' do
            router_env('ONEAPP_VNF_CONNTRACK_SYNC_MODE' => 'BOGUS')

            expect { configure! }.not_to raise_error

            expect(errors.join).to match(/MODE/)
            expect(File.exist?(conf_path)).to be false
            expect(commands.join("\n")).to include('rc-service conntrackd stop')
            expect(commands.join("\n")).not_to include('conntrackd restart')
        end

        it 'treats whitespace-only values as unset (multicast, defaults)' do
            router_env('ONEAPP_VNF_CONNTRACK_SYNC_PEER' => '  ', 'ONEAPP_VNF_CONNTRACK_SYNC_MODE' => ' ',
                       'ONEAPP_VNF_CONNTRACK_SYNC_IGNORE' => ' ')
            s = described_class.settings

            expect([s.peer, s.mode, s.port, s.protocols]).to eq [nil, 'FTFW', 3780, %w[TCP UDP]]
        end

        it 'warns about an unknown boolean spelling and keeps the service stopped' do
            router_env('ONEAPP_VNF_CONNTRACK_SYNC_ENABLED' => 'true')

            configure!

            expect(warnings.join).to match(/ENABLED.*"true"/)
            expect(File.exist?(conf_path)).to be false
            expect(commands.join("\n")).to include('rc-service conntrackd stop')
        end

        %w[YES yes 1 NO no 0].each do |value|
          it "does not warn for ENABLED=#{value}" do
              router_env('ONEAPP_VNF_CONNTRACK_SYNC_ENABLED' => value)
              configure!

              expect(warnings).to be_empty
          end
        end

        it 'does not warn when ENABLED is unset or empty' do
            configure!
            ENV['ONEAPP_VNF_CONNTRACK_SYNC_ENABLED'] = ''
            configure!

            expect(warnings).to be_empty
        end

        it 'survives an unexpected error (odd management address), logs class and message, keeps sync stopped' do
            router_env('ETH2_IP' => 'not-an-address')

            expect { configure! }.not_to raise_error

            expect(errors.join("\n")).to match(/Conntrack::configure: \S+Error: .*stays off/)
            expect(File.exist?(conf_path)).to be false
            expect(commands.join("\n")).to include('rc-service conntrackd stop')
            expect(commands.join("\n")).not_to match(/conntrackd (restart|start)/)
        end

        it 'survives a failing file write' do
            router_env
            allow(described_class).to receive(:file).and_raise(Errno::EACCES, 'conf')

            expect { configure! }.not_to raise_error
            expect(errors.join).to include('Errno::EACCES')
        end

        it 'turns the hook into a no-op while the configuration is invalid' do
            router_env('ONEAPP_VNF_CONNTRACK_SYNC_PORT' => '0')

            expect(described_class.ha_transition('up')).to be true
            expect(commands).to be_empty
        end
    end

    describe 'interface and peer derivation' do
        it 'picks the first Keepalived NIC that has an IP' do
            router_env
            s = described_class.settings

            expect([s.interface, s.local_ip, s.peer]).to eq ['eth0', '10.2.11.67', nil]
        end

        it 'skips management NICs even when Keepalived lists them first' do
            router_env('ONEAPP_VNF_KEEPALIVED_INTERFACES' => 'eth2 eth1')

            expect(described_class.settings.interface).to eq 'eth1'
        end

        it 'honours Keepalived exclusions' do
            router_env('ONEAPP_VNF_KEEPALIVED_INTERFACES' => '!eth0')

            expect(described_class.settings.interface).to eq 'eth1'
        end

        it 'uses an explicitly set NIC, even the management one' do
            router_env('ONEAPP_VNF_CONNTRACK_SYNC_INTERFACE' => 'eth2')
            s = described_class.settings

            expect([s.interface, s.local_ip]).to eq ['eth2', '172.20.0.5']
        end

        it 'strips a prefix length from the NIC address' do
            router_env('ETH0_IP' => '10.2.11.67/24')

            expect(described_class.settings.local_ip).to eq '10.2.11.67'
        end

        it 'uses multicast without a peer and unicast UDP with one' do
            router_env
            expect(described_class.render_conf(described_class.settings)).to include('Multicast {')

            router_env('ONEAPP_VNF_CONNTRACK_SYNC_PEER' => '10.2.11.68')
            conf = described_class.render_conf(described_class.settings)
            expect(conf).to include('UDP {')
            expect(conf).to include('IPv4_Destination_Address 10.2.11.68')
        end
    end

    describe 'ignore list' do
        it 'only lists IPv4 subnets of the management NICs' do
            router_env
            allow(described_class).to receive(:nics_to_subnets).and_return('eth2' => ['172.20.0.0/24', 'fd00:1::/64'])

            expect(described_class.settings.ignore).to eq ['127.0.0.1', '172.20.0.0/24', '225.0.0.50']
        end
    end

    describe 'conntrackd.conf' do
        let(:golden_multicast) { <<~CONF }
            # Managed by the VRouter appliance (Service::Conntrack), do not edit.
            Sync {
                Mode FTFW {
                    ResendQueueSize 131072
                    CommitTimeout 180
                    PurgeTimeout 5
                    ACKWindowSize 300
                    DisableExternalCache Off
                }
                Multicast {
                    IPv4_address 225.0.0.50
                    Group 3780
                    IPv4_interface 10.2.11.67
                    Interface eth0
                    SndSocketBuffer 1249280
                    RcvSocketBuffer 1249280
                    Checksum on
                }
            }
            General {
                HashSize 8192
                HashLimit 65536
                LogFile /var/log/one-appliance/conntrackd.log
                LockFile /var/lock/conntrack.lock
                UNIX {
                    Path /var/run/conntrackd.ctl
                }
                NetlinkBufferSize 262142
                NetlinkBufferSizeMaxGrowth 655355
                Filter From Userspace {
                    Protocol Accept {
                        TCP
                        UDP
                    }
                    Address Ignore {
                        IPv4_address 127.0.0.1
                        IPv4_address 172.20.0.0/24
                        IPv4_address 225.0.0.50
                    }
                }
            }
        CONF

        let(:golden_udp_notrack) { <<~CONF }
            # Managed by the VRouter appliance (Service::Conntrack), do not edit.
            Sync {
                Mode NOTRACK {
                    DisableExternalCache Off
                }
                UDP {
                    IPv4_address 10.2.12.67
                    IPv4_Destination_Address 10.2.12.68
                    Port 4000
                    Interface eth1
                    SndSocketBuffer 1249280
                    RcvSocketBuffer 1249280
                    Checksum on
                }
            }
            General {
                HashSize 4096
                HashLimit 32768
                LogFile /var/log/one-appliance/conntrackd.log
                LockFile /var/lock/conntrack.lock
                UNIX {
                    Path /var/run/conntrackd.ctl
                }
                NetlinkBufferSize 262142
                NetlinkBufferSizeMaxGrowth 655355
                Filter From Userspace {
                    Protocol Accept {
                        TCP
                        UDP
                        icmp
                    }
                    Address Ignore {
                        IPv4_address 127.0.0.1
                        IPv4_address 172.20.0.0/24
                        IPv4_address 10.2.12.68
                        IPv4_address 10.9.9.0/24
                    }
                }
            }
        CONF

        it 'renders the default FTFW multicast configuration' do
            router_env

            expect(described_class.render_conf(described_class.settings)).to eq golden_multicast
        end

        it 'renders NOTRACK over unicast UDP with custom limits and filters' do
            router_env('ONEAPP_VNF_CONNTRACK_SYNC_MODE' => 'notrack',
                       'ONEAPP_VNF_CONNTRACK_SYNC_INTERFACE' => 'eth1',
                       'ONEAPP_VNF_CONNTRACK_SYNC_PEER' => '10.2.12.68',
                       'ONEAPP_VNF_CONNTRACK_SYNC_PORT' => '4000',
                       'ONEAPP_VNF_CONNTRACK_SYNC_PROTOCOLS' => 'tcp, udp icmp',
                       'ONEAPP_VNF_CONNTRACK_SYNC_HASH_LIMIT' => '32768',
                       'ONEAPP_VNF_CONNTRACK_SYNC_IGNORE' => '10.9.9.0/24')

            expect(described_class.render_conf(described_class.settings)).to eq golden_udp_notrack
        end

        it 'sizes HashSize as an eighth of HashLimit' do
            router_env('ONEAPP_VNF_CONNTRACK_SYNC_HASH_LIMIT' => '16384')

            expect(described_class.render_conf(described_class.settings)).to include("HashSize 2048\n    HashLimit 16384")
        end
    end

    describe 'configure (enabled)' do
        before { router_env }

        it 'writes the config, the sysctl file and the module list' do
            configure!

            expect(File.read(conf_path)).to eq described_class.render_conf(described_class.settings)
            expect(File.read(File.join(sysctl_d, '97-conntrack-sync.conf')))
                .to include('net.netfilter.nf_conntrack_tcp_be_liberal = 1')
            expect(File.read(modules).lines.map(&:strip)).to include('nf_conntrack', 'nfnetlink', 'nf_conntrack_netlink')
        end

        it 'loads the modules and sets the sysctl before it (re)starts the service' do
            configure!

            idx = ->(s) { commands.index { |c| c.include?(s) } }
            expect(idx.('modprobe nf_conntrack_netlink')).to be < idx.('sysctl -w net.netfilter.nf_conntrack_tcp_be_liberal=1')
            expect(idx.('sysctl -w')).to be < idx.('rc-service conntrackd restart')
            expect(commands.join("\n")).not_to match(/conntrackd -C .* -n/) # no role known
            expect(commands.join("\n")).to include('rc-update add conntrackd default')
        end

        it 'does not duplicate module entries or keep unrelated ones out' do
            File.write(modules, "dummy\nnf_conntrack\n")

            2.times { configure! }

            lines = File.read(modules).lines.map(&:strip)
            expect(lines.count('nf_conntrack')).to eq 1
            expect(lines).to include('dummy')
            expect(lines.uniq).to eq lines
        end

        it 'is idempotent' do
            configure!
            first = File.read(conf_path)
            configure!

            expect(File.read(conf_path)).to eq first
        end

        it 'never raises when modules, sysctl or the service fail, but logs' do
            failing.push('modprobe', 'sysctl -w', 'rc-service conntrackd restart')

            expect { configure! }.not_to raise_error
            expect(errors.join("\n")).to match(/modprobe|sysctl|conntrackd/)
        end

        it 'restarts only when the rendered configuration changed, otherwise just makes sure it runs' do
            configure!
            commands.clear
            configure!

            expect(commands.join("\n")).not_to include('conntrackd restart')
            expect(commands.join("\n")).to include('rc-service conntrackd start')
            expect(commands.join("\n")).to include('rc-update add conntrackd default')

            commands.clear
            ENV['ONEAPP_VNF_CONNTRACK_SYNC_PORT'] = '4001'
            configure!
            expect(commands.join("\n")).to include('rc-service conntrackd restart')
        end

        it 'requests a resync from the peer after (re)starting on a BACKUP node' do
            File.write(state_path, '{"state":"BACKUP"}')

            configure!

            resync = commands.grep(/conntrackd -C \S+ -n\b/)
            expect(resync.size).to eq 1
            expect(commands.index(resync.first)).to be > commands.index { |c| c.include?('conntrackd restart') }
            expect(resync.first).to match(/\Atimeout -k 1 \d+ /)
        end

        it 'rebuilds the caches and sends a bulk update after (re)starting on a MASTER node' do
            File.write(state_path, '{"state":"MASTER"}')

            configure!

            expect(commands.grep(/conntrackd -C \S+ -[RB]\b/).map { |c| c[/conntrackd -C \S+ -(\w)\b/, 1] }).to eq %w[R B]
        end

        it 'does not send resync requests when the role is unknown or the state file is garbage' do
            File.write(state_path, 'garbage')
            configure!
            File.delete(state_path)
            configure!

            expect(commands.join("\n")).not_to match(/conntrackd -C \S+ -[nRB]\b/)
        end

        it 'logs but does not raise when the resync request fails' do
            File.write(state_path, '{"state":"BACKUP"}')
            failing << ' -n'

            expect { configure! }.not_to raise_error
            expect(errors.join).to match(/resync/)
        end

        it 'does nothing at bootstrap' do
            expect { described_class.bootstrap }.not_to raise_error
            expect(commands).to be_empty
        end
    end

    describe 'hook' do
        before { router_env }

        let(:conf_flag) { "-C #{described_class::CONF_PATH}" }
        let(:clock)     { [1000.0] }
        let(:hanging)   { [] } # substrings of commands that hang until `timeout` kills them

        # Fake time: a normal command takes 0.2 s, a hanging one its timeout plus the kill grace.
        before do
            allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock[0] }
            allow(described_class).to receive(:bash) do |cmd, **|
                commands << cmd
                grace, limit = cmd.match(/\Atimeout -k (\d+) (\d+) /)&.captures&.map(&:to_i)
                if hanging.any? { |h| cmd.include?(h) }
                    clock[0] += limit + grace
                    raise '124: timed out'
                end
                clock[0] += 0.2
                raise "1: simulated failure of #{cmd}" if failing.any? { |f| cmd.include?(f) }

                ''
            end
        end

        def conntrackd_calls
            commands.grep(/conntrackd #{Regexp.escape(conf_flag)} -\w/).map { |c| c[/conntrackd -C \S+ -(\w)\b/, 1] }
        end

        it 'on up (MASTER) checks the daemon, commits, flushes, resyncs and sends a bulk update, in that order' do
            expect(described_class.ha_transition('up')).to be true

            expect(conntrackd_calls).to eq %w[s c f R B]
            expect(commands.join("\n")).not_to include('rc-service conntrackd start')
        end

        it 'on up starts a dead conntrackd, then carries on with the steps' do
            failing << ' -s'

            expect(described_class.ha_transition('up')).to be true

            expect(commands.join("\n")).to include('rc-service conntrackd start')
            expect(conntrackd_calls).to eq %w[s c f R B]
            expect(commands.index { |c| c.include?('rc-service conntrackd start') }).to be < commands.index { |c| c.match?(/conntrackd -C \S+ -c\b/) }
        end

        it 'on down (BACKUP) checks the daemon, shortens the kernel timers and requests a resync' do
            expect(described_class.ha_transition('down')).to be true

            expect(conntrackd_calls).to eq %w[s t n]
            expect(commands.join("\n")).not_to include('rc-service conntrackd start')
        end

        it 'on down starts conntrackd when it is not running' do
            failing << ' -s'

            expect(described_class.ha_transition('down')).to be true

            expect(commands.join("\n")).to include('rc-service conntrackd start')
            expect(conntrackd_calls).to eq %w[s t n]
        end

        it 'reports failure when conntrackd cannot be started' do
            failing.push(' -s', 'rc-service conntrackd start')

            expect(described_class.ha_transition('up')).to be false
            expect(described_class.ha_transition('down')).to be false
            expect(errors.join("\n")).to match(/rc-service conntrackd start/)
        end

        it 'bounds every call with timeout -k, and the start command fails if the start fails' do
            described_class.ha_transition('up')
            failing << ' -s'
            described_class.ha_transition('down')

            bounded = commands.select { |c| c.include?('conntrackd') || c.include?('rc-service') }
            expect(bounded).to all(match(/\Atimeout -k #{described_class::KILL_GRACE} \d+ /))
            start = commands.find { |c| c.include?('rc-service conntrackd start') }
            expect(start).to include('&& sleep 1')
            expect(start).not_to match(/;\s*sleep/)
        end

        def run_start_command(rc_service_exit)
            stub = File.join(dir, 'bin')
            FileUtils.mkdir_p stub
            File.write(File.join(stub, 'rc-service'), "#!/bin/sh\nexit #{rc_service_exit}\n")
            FileUtils.chmod 0o755, File.join(stub, 'rc-service')
            stub_const('Service::Conntrack::RC_LOG', File.join(dir, 'rc.log'))
            failing << ' -s'
            described_class.ha_transition('down')
            command = commands.find { |c| c.include?('rc-service conntrackd start') }
            system({ 'PATH' => "#{stub}:#{ENV.fetch('PATH')}" }, '/bin/sh', '-c', command, %i[out err] => File::NULL)
        end

        it 'really exits non-zero when the start fails (not the status of sleep)' do
            expect(run_start_command(1)).to be false
        end

        it 'really exits zero when the start works' do
            expect(run_start_command(0)).to be true
        end

        it 'keeps the worst case (all timeouts + kill grace + Ruby start-up) well inside the 30 s hook limit' do
            c = described_class
            expect(c::HOOK_BUDGET + c::KILL_GRACE).to be <= c::HOOK_CAP
            expect(c::HOOK_CAP + c::KILL_GRACE).to be <= 25 # >= 5 s margin to Failover's 30 s
            # even the sum of every timeout of the longest sequence is bounded by the budget
            longest = c::STEP_TIMEOUT + c::START_TIMEOUT + (c::UP_FLAGS.size * c::STEP_TIMEOUT)
            expect([longest, c::HOOK_BUDGET].min + c::KILL_GRACE).to be <= c::HOOK_CAP
        end

        %w[up down].each do |direction|
            it "stops in time when every step of #{direction} hangs" do
                hanging << 'conntrackd'
                started = clock[0]

                expect(described_class.ha_transition(direction)).to be false

                elapsed = clock[0] - started
                expect(elapsed).to be <= described_class::HOOK_BUDGET + described_class::KILL_GRACE
                expect(elapsed + described_class::KILL_GRACE).to be < 30 - 5
            end
        end

        it 'skips the remaining steps with an error once the budget is used up' do
            hanging << ' -f'
            clock[0] += 0 # steps cost 0.2 s each; the hanging one eats its whole timeout
            stub_const('Service::Conntrack::HOOK_BUDGET', 5)

            expect(described_class.ha_transition('up')).to be false

            expect(errors.join("\n")).to match(/budget used up/)
            expect(conntrackd_calls).not_to include('B')
        end

        it 'never lets one hanging step push a later step past the budget' do
            hanging << ' -c'
            started = clock[0]

            described_class.ha_transition('up')

            expect(clock[0] - started).to be <= described_class::HOOK_BUDGET + described_class::KILL_GRACE
            timeouts = commands.map { |c| c[/\Atimeout -k \d+ (\d+) /, 1]&.to_i }.compact
            expect(timeouts).to all(be <= described_class::START_TIMEOUT)
        end

        it 'is idempotent: running a direction twice issues the same commands' do
            described_class.ha_transition('up')
            once = commands.dup
            commands.clear
            described_class.ha_transition('up')

            expect(commands).to eq once
        end

        it 'keeps going and returns false, never raising, when steps fail' do
            failing << 'conntrackd'

            result = nil
            expect { result = described_class.ha_transition('up') }.not_to raise_error

            expect(result).to be false
            expect(conntrackd_calls.size).to eq 5 # one failure does not skip the next step
            expect(errors.join("\n")).to match(/conntrackd/)
        end

        it 'rejects an unknown direction without raising' do
            expect(described_class.ha_transition('sideways')).to be false
            expect(commands).to be_empty
        end

        it 'accepts symbols too (as the Failover module passes them around)' do
            expect(described_class.ha_transition(:up)).to be true
        end
    end

    describe 'generated hook script, executed' do
        let(:hook)    { File.join(dir, 'hook') }
        let(:env_file) { File.join(dir, 'one_env') }
        let(:marker)  { File.join(dir, 'pwned') }
        # the same file vrouter.rb loads, or it would be loaded twice
        let(:helpers) { File.exist?('/etc/one-appliance/lib/helpers.rb') ? '/etc/one-appliance/lib/helpers.rb' : File.expand_path('../../lib/helpers.rb', __dir__) }

        def write_hook(ruby: RbConfig.ruby, **opts)
            File.write(hook, described_class.hook_script(ruby: ruby, helpers: helpers, env_file: env_file, **opts))
            FileUtils.chmod 0o755, hook
        end

        def run_hook(*args, env: {})
            require 'open3'
            Open3.capture3({ 'PATH' => ENV.fetch('PATH') }.merge(env), hook, *args, unsetenv_others: false)
        end

        it 'is valid sh syntax' do
            write_hook
            expect(system('/bin/sh', '-n', hook)).to be true
        end

        it 'passes the direction to Ruby, propagates the exit status and is capped by timeout' do
            bin = File.join(dir, 'stub-ruby')
            File.write(bin, "#!/bin/sh\necho \"$@\" > #{dir}/args\nexit 3\n")
            FileUtils.chmod 0o755, bin
            write_hook(ruby: bin)

            _out, _err, status = run_hook('down')

            expect(status.exitstatus).to eq 3
            expect(File.read("#{dir}/args")).to include('Service::Conntrack.run_hook(ARGV[0]').and end_with("down\n")
        end

        it 'kills a hanging Ruby after the cap (stubbed to 1 s here)' do
            bin = File.join(dir, 'stub-ruby')
            File.write(bin, "#!/bin/sh\nexec sleep 30\n")
            FileUtils.chmod 0o755, bin
            stub_const('Service::Conntrack::HOOK_CAP', 1)
            write_hook(ruby: bin)

            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            _out, _err, status = run_hook('up')

            expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
            expect(status.success?).not_to be true
        end

        it 'loads the context in Ruby without ever evaluating it as shell code, on up and down' do
            File.write(env_file, <<~ENV)
                export ONEAPP_VNF_CONNTRACK_SYNC_ENABLED="YES"
                export ONEAPP_VNF_CONNTRACK_SYNC_PEER="$(touch #{marker})`touch #{marker}`"
            ENV
            write_hook

            %w[up down].each do |direction|
                _out, err, status = run_hook(direction)

                expect(File.exist?(marker)).to be false
                expect(status.exitstatus).to eq 0 # invalid configuration: nothing to do
                expect(err).to match(/nothing to do/) # ... which also proves the context was loaded
            end
        end

        it 'is a silent no-op when the context says the module is off' do
            File.write(env_file, %(export ONEAPP_VNF_CONNTRACK_SYNC_ENABLED="NO"\n))
            write_hook

            _out, err, status = run_hook('down')

            expect([status.exitstatus, err]).to eq [0, '']
        end

        it 'still works without a context file' do
            write_hook

            expect(run_hook('up').last.exitstatus).to eq 0
        end

        it 'rejects an unknown direction with a non-zero exit' do
            write_hook

            expect(run_hook('sideways').last.exitstatus).to eq 1
        end
    end
end
