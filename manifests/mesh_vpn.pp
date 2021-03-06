# Definition: gluon::mesh_vpn
#
# This class installs a Mesh VPN server
#
# Parameters:
# - The $community name
# - The $ip4_address of this gateway within the Mesh network
# - The $ip4_netmask wrt. $ip4_address
# - The $ip6_address of this gateway within the Mesh network; /64 mask is assumed
# - The $ip6_prefix of the Mesh network with trailing double colons
# - The $ip6_gateway of the Mesh network
# - The $fastd_port to configure fastd to listen on
# - The $site_config option, whether to provide a gluon site directory
# - The $city_name to use throughout site/site.conf
# - The $dhcp_range_start and $dhcp_range_end
# - The $dhcp_leasetime
# - The $mtu of the mesh vpn device
# - The $gateway_ipaddr of this gateway (used by other nodes to connect to here)
# - The $github_repo to sync peers files to and from
# - The $github_owner of the repo.
# - The $auto_update_pubkey to list in the gluon site/site.conf
# - The $auto_update_seckey_file which contains the secret key to $auto_update_pubkey,
#       used to automatically sign sysupgrade manifest.  Leave empty to sign manually.
#
# Actions:
# - Install a Freifunk Mesh VPN server
#
# Requires:
# - The gluon class
#
# Sample Usage:
#
#  gluon::mesh_vpn { 'ffan':
#      ip6_address     => '2001:470:5168::2',
#      ip6_prefix      => '2001:470:5168::',
#      ip4_address     => '10.123.1.2',
#      ip4_netmask     => '255.255.255.0',
#  }
#
define gluon::mesh_vpn (
    $ensure             = 'present',
    $community          = $name,
    $city_name          = undef,

    $ip4_address        = undef,
    $ip4_netmask        = '255.255.255.0',

    $ip6_address        = undef,
    $ip6_prefix         = undef,
    $ip6_gateway        = undef,

    $fastd_port         = 10000,
    $mtu                = 1426,

    $mesh_bssid         = undef,
    $mesh_bssid24       = undef,
    $mesh_macaddr       = undef,

    $dhcp_range_start   = undef,
    $dhcp_range_end     = undef,
    $dhcp_leasetime     = '10m',

    $github_owner       = undef,
    $github_repo        = undef,
    $peers_dir          = undef,
    $domain_seed        = undef,

    $cipher             = 'salsa2012+gmac',

    $gateway_ipaddr     = $ipaddress_eth0,

    $site_config                = true,
    $site_config_ssl            = false,
    $site_config_ssl_key        = undef, # @fixme $::apache::default_ssl_key,
    $site_config_ssl_cert       = undef, # @fixme $::apache::default_ssl_cert,
    $site_config_ssl_chain      = undef, # @fixme $::apache::default_ssl_chain,
    $site_config_ssl_ca         = undef, # @fixme $::apache::default_ssl_ca,
    $auto_update_pubkey         = undef,
    $auto_update_seckey_file    = undef,

    $enable_radvd       = true,
) {
    include gluon

    $real_peers_dir = $peers_dir

    # needed network interfaces
    #  - a batman device for the community
    #  - a bridge, which wraps the batman device
    network::interface { "br_$community":
        auto            => false,
        bridge_ports    => [ 'none' ],
        ipaddress       => $ip4_address,
        netmask         => $ip4_netmask,
        post_up         => [
            "ip -6 a a $ip6_address/64 dev br_$community",
            "if test -d /srv/netmon-$community; then ip -6 a a ${ip6_prefix}42/64 dev br_$community; fi"
        ],
        before          => Network::Interface["bat_$community"],
    }

    network::interface { "bat_$community":
        auto            => false,
        address         => false,
        family          => 'inet6',
        method          => 'manual',
        pre_up          => [
            "batctl -m bat_$community if add mesh_$community",
            ($::gluon::gateway ? { 
                true    => "batctl -m bat_$community gw server", 
                false   => "batctl -m bat_$community gw client" }),
            "ifup br_$community",
        ],
        up              => [
            "ip link set bat_$community up",
        ],
        post_up         => [
            "brctl addif br_$community bat_$community",
            "batctl -m bat_$community it 10000",
        ],
        pre_down        => [
            "brctl delif br_$community bat_$community || true",
        ],
        down            => [
            "ip link set bat_$community down",
        ],
        post_down       => [
            "ifdown br_$community || true",
        ],
        before          => Service['fastd'],
    }


    #
    # firewalling rules
    #
    if($::gluon::gateway) {
        # run all traffic from the mesh through the from_mesh mangle chain,
        # which finally marks it for policy based routing (i.e. to vpn provider)
        firewall { "150 possibly mark $community traffic":
            table           => 'mangle',
            chain           => 'PREROUTING',
            proto           => 'all',
            iniface         => "br_$community",
            jump            => 'from_mesh',
        }

        # don't mark traffic from other meshes to this one
        firewall { "100 accept mesh to $community traffic":
            table           => 'mangle',
            chain           => 'from_mesh',
            proto           => 'all',
            destination     => "$ip4_address/$ip4_netmask",
            jump            => 'RETURN',
        }

        # run all traffic from this mesh through "from_mesh" filter chain
        firewall { "110 handle outbound $community traffic":
            table           => 'filter',
            chain           => 'FORWARD',
            proto           => 'all',
            iniface         => "br_$community",
            source          => "$ip4_address/$ip4_netmask",
            jump            => 'from_mesh',
        }

        # pick traffic from "to_mesh" chain to this mesh
        firewall { "110 pick to_mesh traffic for $community":
            table           => 'filter',
            chain           => 'to_mesh',
            proto           => 'all',
            outiface        => "br_$community",
            destination     => "$ip4_address/$ip4_netmask",
            action          => 'accept',
        }

        # masquerade outgoing traffic from community's iprange
        firewall { "100 masquerade $community traffic":
            table           => 'nat',
            chain           => 'POSTROUTING',
            proto           => 'all',
            source          => "$ip4_address/$ip4_netmask",
            jump            => 'from_mesh',
        }
    }


    #
    # configure fastd instance
    #
    file { "/etc/fastd/$community":
        ensure      => directory,
        require     => Package['fastd'],
    }

    exec { "/root/fastd-$community-key.txt":
        command     => "/usr/bin/fastd --generate-key >> /root/fastd-$community-key.txt",
        creates     => "/root/fastd-$community-key.txt",
        require     => Package['fastd'],
    }

    exec { "/etc/fastd/$community/secret.conf":
        command     => "/bin/sed -ne '/Secret:/ { s/Secret: /secret \"/; s/$/\";/; p }' /root/fastd-$community-key.txt > /etc/fastd/$community/secret.conf",
        creates     => "/etc/fastd/$community/secret.conf",
        require     => [ 
            Exec["/root/fastd-$community-key.txt"],
            File["/etc/fastd/$community"],
        ]
    }

    $bind_fastd_port = $::gluon::gateway
    file { "/etc/fastd/$community/fastd.conf":
        ensure      => present,
        content     => template('gluon/fastd.conf'),
        #notify      => Service['fastd'],
        before      => Service['fastd'],
    }


    #
    # configure ipv6 router advertising daemon
    #
    if $::gluon::gateway and $enable_radvd {
        include gluon::radvd
        concat::fragment { "radvd-$community":
            target      => "/etc/radvd.conf",
            content     => template('gluon/radvd.conf'),
        }
    }


    if $::gluon::gateway and $site_config {
        include gluon::apache_common

        gluon::site_config { $name:
            city_name           => $city_name,
            ip4_address         => $ip4_address,
            ip4_netmask         => $ip4_netmask,
            ip6_address         => $ip6_address,
            ip6_prefix          => $ip6_prefix,
            ip6_gateway         => $ip6_gateway,
            ntp_server          => $ip6_address,
            fastd_port          => $fastd_port,
            auto_update_pubkey  => $auto_update_pubkey,
            mtu                 => $mtu,
            mesh_bssid          => $mesh_bssid,
            mesh_bssid24        => $mesh_bssid24,
            cipher              => $cipher,
            peers_dir           => $real_peers_dir,
            domain_seed         => $domain_seed,

            ssl                 => $site_config_ssl,
            ssl_key             => $site_config_ssl_key,
            ssl_cert            => $site_config_ssl_cert,
            ssl_chain           => $site_config_ssl_chain,
            ssl_ca              => $site_config_ssl_ca,
        }
    }

    if $real_peers_dir {
        if $::gluon::gateway {
            exec { "${real_peers_dir}/${hostname}":
                command     => "/bin/sed -ne '/Public:/ { s/Public: /key \"/; s/$/\";\\nremote $gateway_ipaddr:$fastd_port;/; p }' /root/fastd-$community-key.txt > ${real_peers_dir}/${hostname}",
                creates     => "${real_peers_dir}/${hostname}",
                require     => Exec["/root/fastd-$community-key.txt"],
            }
        }
        else {
            exec { "${real_peers_dir}/${hostname}":
                command     => "/bin/sed -ne '/Public:/ { s/Public: /key \"/; s/$/\";/; p }' /root/fastd-$community-key.txt > ${real_peers_dir}/${hostname}",
                creates     => "${real_peers_dir}/${hostname}",
                require     => Exec["/root/fastd-$community-key.txt"],
            }
        }
    }

    if $::gluon::gateway {
        if $dhcp_range_start and $dhcp_range_end {
            file { "/etc/dnsmasq.d/$community.conf":
                ensure      => present,
                content     => template('gluon/dnsmasq.conf'),
                notify      => Service['dnsmasq'],
                require     => Package['dnsmasq'],
            }
        }

        concat::fragment { "ffgw-on-$community":
            target      => "/usr/local/sbin/ffgw-on",
            content     => "batctl -m bat_$community gw server\n",
        }

        concat::fragment { "ffgw-off-$community":
            target      => "/usr/local/sbin/ffgw-off",
            content     => "batctl -m bat_$community gw off\n",
        }
    }


    concat::fragment { "nagios-$community-dns":
        target      => "/etc/nagios3/conf.d/gluon_localhost.cfg",
        content     => "define service {
                            host                            localhost
                            service_description             $community DNS
                            check_command                   check_mesh_dns!$ip4_address
                            use                             generic-service
                    }\n",
    }

    concat::fragment { "nagios-$community-promisc-bat":
        target      => "/etc/nagios3/conf.d/gluon_localhost.cfg",
        content     => "define service {
                            host                            localhost
                            service_description             $community Promiscuous Batman
                            check_command                   check_ifpromisc!bat_$community
                            use                             generic-service
                    }\n",
    }

    concat::fragment { "nagios-$community-promisc-br":
        target      => "/etc/nagios3/conf.d/gluon_localhost.cfg",
        content     => "define service {
                            host                            localhost
                            service_description             $community Promiscuous Bridge
                            check_command                   check_ifpromisc!br_$community
                            use                             generic-service
                    }\n",
    }

    concat::fragment { "nagios-$community-promisc-mesh":
        target      => "/etc/nagios3/conf.d/gluon_localhost.cfg",
        content     => "define service {
                            host                            localhost
                            service_description             $community Promiscuous Mesh
                            check_command                   check_ifpromisc!mesh_$community
                            use                             generic-service
                    }\n",
    }

    concat::fragment { "nagios-$community-fastd":
        target      => "/etc/nagios3/conf.d/gluon_localhost.cfg",
        content     => "define service {
                            host                            localhost
                            service_description             $community FastD
                            check_command                   check_fastd!$community
                            use                             generic-service
                    }\n",
    }
}

