# network interfaces need to be set up by mesh_vpn before
class gluon::alfred {
    # install alfred and start them for every B.A.T.M.A.N. interface
    package { 'alfred':
        ensure      => present,
        require     => Apt::Source['universe_factory'],
    }

    # if this class is used on gateways alfred is running as slave
    # otherwise it's running as master
    network::interface { "bat_$community":
        post_up         => [
            ($::gluon::gateway ? {
            true  => "start-stop-daemon -b --start --exec /usr/sbin/alfred -- -i bat_$community",
            false => "start-stop-daemon -b --start --exec /usr/sbin/alfred -- -m -i bat_$community"}),
            "start-stop-daemon -b --start --exec /usr/sbin/batadv-vis -- -si bat_$community"
            ],
    }
}
