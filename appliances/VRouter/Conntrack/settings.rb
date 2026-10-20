# frozen_string_literal: true

require 'ipaddr'

module Service
module Conntrack
    class ConfigError < StandardError; end

    PREFIX = 'ONEAPP_VNF_CONNTRACK_SYNC_'

    MODES     = %w[FTFW NOTRACK].freeze
    PROTOCOLS = %w[TCP UDP ICMP].freeze

    DEFAULT_PORT        = 3780
    DEFAULT_MCAST_GROUP = '225.0.0.50'
    DEFAULT_PROTOCOLS   = 'TCP UDP'
    DEFAULT_HASH_LIMIT  = 65_536
    HASH_LIMIT_RANGE    = (1024..1_000_000).freeze

    Settings = Data.define(:interface, :local_ip, :peer, :mode, :port, :group, :protocols,
                           :hash_limit, :hash_size, :ignore)

    # Reads and validates the attributes. Every value is checked here, so
    # nothing unvalidated reaches the generated conntrackd.conf.
    module Parser
        extend self

        DOTTED_QUAD = /\A\d{1,3}(\.\d{1,3}){3}\z/

        def parse
            interface = pick_interface
            local_ip  = local_ip_of(interface)
            peer      = pick_peer(local_ip)
            group     = pick_group
            limit     = pick_hash_limit

            Settings.new(interface: interface, local_ip: local_ip, peer: peer,
                         mode: pick_mode, port: pick_port, group: group,
                         protocols: pick_protocols, hash_limit: limit, hash_size: limit / 8,
                         ignore: ignore_list(interface, peer || group))
        end

        private

        # Blank and whitespace-only values are treated as unset.
        def attr(name, default = nil)
            raw = ENV.fetch("#{PREFIX}#{name}", '').strip
            raw.empty? ? default : raw
        end

        def fail_with(name, message)
            raise ConfigError, "#{PREFIX}#{name}: #{message}"
        end

        def nic_ip(nic)
            ENV.fetch("#{nic.upcase}_IP", '').split(%[/])[0].to_s
        end

        # The NIC that carries the VRRP traffic: the first Keepalived interface
        # (same selection as Service::Keepalived) that is not a management NIC
        # and has an address. An explicit attribute wins, management NIC included.
        def pick_interface
            explicit = attr(:INTERFACE, nil)
            if explicit
                nic = explicit.strip.downcase
                fail_with(:INTERFACE, "#{explicit.inspect} is not a NIC with an address (expected ethN with ETHN_IP)") \
                    unless nic.match?(/\Aeth\d+\z/) && !nic_ip(nic).empty?
                return nic
            end

            candidates = parse_interfaces(env(:ONEAPP_VNF_KEEPALIVED_INTERFACES, '')).keys - detect_mgmt_nics
            nic = candidates.find { |n| !nic_ip(n).empty? }
            fail_with(:INTERFACE, 'no NIC found to carry the synchronisation, set it explicitly') if nic.nil?
            nic
        end

        def local_ip_of(nic)
            ip = nic_ip(nic)
            fail_with(:INTERFACE, "#{nic} has no address") unless ip.match?(DOTTED_QUAD)
            ip
        end

        def pick_peer(local_ip)
            peer = attr(:PEER, nil)
            return nil if peer.nil?

            peer = peer.strip
            fail_with(:PEER, "#{peer.inspect} is not an IPv4 address") unless valid_ipv4?(peer)
            fail_with(:PEER, "#{peer.inspect} is not a unicast address of the other node") unless unicast_peer?(peer)
            fail_with(:PEER, 'must not be the own address of this node') if peer == local_ip
            peer
        end

        def unicast_peer?(peer)
            addr = IPAddr.new(peer)
            !(IPAddr.new('127.0.0.0/8').include?(addr) || IPAddr.new('224.0.0.0/4').include?(addr) ||
              peer == '0.0.0.0' || peer == '255.255.255.255')
        end

        def pick_mode
            mode = attr(:MODE, 'FTFW').strip.upcase
            fail_with(:MODE, "#{mode.inspect} is not one of #{MODES.join(' ')}") unless MODES.include?(mode)
            mode
        end

        def pick_port
            raw = attr(:PORT, DEFAULT_PORT.to_s).strip
            fail_with(:PORT, "#{raw.inspect} is not a port (1..65535)") \
                unless raw.match?(/\A\d+\z/) && (1..65_535).cover?(raw.to_i)
            raw.to_i
        end

        def pick_group
            group = attr(:MCAST_GROUP, DEFAULT_MCAST_GROUP).strip
            fail_with(:MCAST_GROUP, "#{group.inspect} is not an IPv4 multicast address") \
                unless valid_ipv4?(group) && IPAddr.new('224.0.0.0/4').include?(IPAddr.new(group))
            group
        end

        def pick_protocols
            list = attr(:PROTOCOLS, DEFAULT_PROTOCOLS).split(/[\s,;]+/).reject(&:empty?).map(&:upcase).uniq
            bad  = list - PROTOCOLS
            fail_with(:PROTOCOLS, "unknown #{bad.join(' ')} (allowed: #{PROTOCOLS.join(' ')})") unless bad.empty?
            fail_with(:PROTOCOLS, 'at least one protocol is required') if list.empty?
            list
        end

        def pick_hash_limit
            raw = attr(:HASH_LIMIT, DEFAULT_HASH_LIMIT.to_s).strip
            fail_with(:HASH_LIMIT, "#{raw.inspect} is not an integer in #{HASH_LIMIT_RANGE}") \
                unless raw.match?(/\A\d+\z/) && HASH_LIMIT_RANGE.cover?(raw.to_i)
            raw.to_i
        end

        # Never synchronised: loopback, the management subnets, and the sync
        # endpoint itself (the multicast group, or the peer in unicast mode), so
        # the synchronisation traffic is not synchronised in turn. The addresses
        # of the node and the VIPs are kept on purpose: forwarded flows that are
        # NATed to them (SNAT to the VIP) must be replicated. IGNORE adds more.
        def ignore_list(interface, endpoint)
            mgmt = detect_mgmt_nics - [interface]
            subnets = nics_to_subnets(mgmt).values.flatten.select { |subnet| ipv4_subnet?(subnet) }

            (['127.0.0.1'] + subnets + [endpoint] + user_ignores).uniq
        end

        # conntrackd's IPv4_address entries cannot hold an IPv6 subnet.
        def ipv4_subnet?(subnet)
            IPAddr.new(subnet.split(%[/])[0]).ipv4?
        end

        def user_ignores
            attr(:IGNORE, '').split(/[\s,;]+/).reject(&:empty?).map { |item| normalise_ignore(item) }
        end

        def normalise_ignore(item)
            addr, len = item.split(%[/], 2)
            ok = valid_ipv4?(addr) && (len.nil? || (len.match?(/\A\d+\z/) && (0..32).cover?(len.to_i)))
            fail_with(:IGNORE, "#{item.inspect} is not an IPv4 address or CIDR") unless ok

            len.nil? ? addr : "#{IPAddr.new(item).to_s}/#{len.to_i}"
        end

        def valid_ipv4?(string)
            return false unless string.is_a?(String) && string.match?(DOTTED_QUAD)

            IPAddr.new(string).ipv4?
        rescue IPAddr::Error
            false
        end
    end
end
end
