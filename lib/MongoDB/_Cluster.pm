#
#  Copyright 2014 MongoDB, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#

package MongoDB::_Cluster;

use version;
our $VERSION = 'v0.704.4.1';

use Moose;
use MongoDB::Error;
use MongoDB::_Link;
use MongoDB::_Types;
use MongoDB::_Server;
use List::Util qw/first/;
use Syntax::Keyword::Junction qw/any none/;
use Time::HiRes qw/gettimeofday tv_interval usleep/;
use Try::Tiny;

use namespace::clean -except => 'meta';

with 'MongoDB::Role::_Client';

use constant {
    EPOCH => [ 0, 0 ], # tv struct for the epoch
};

#--------------------------------------------------------------------------#
# attributes
#--------------------------------------------------------------------------#

has uri => (
    is       => 'ro',
    isa      => 'MongoDB::_URI',
    required => 1,
);

has max_wire_version => (
    is       => 'ro',
    isa      => 'Num',
    required => 1,
);

has min_wire_version => (
    is       => 'ro',
    isa      => 'Num',
    required => 1,
);

has type => (
    is      => 'ro',
    isa     => 'ClusterType',
    writer  => '_set_type',
    default => 'Unknown'
);

has replica_set_name => (
    is      => 'ro',
    isa     => 'Str',
    default => '',
    writer  => '_set_replica_set_name', # :-)
);

has heartbeat_frequency_ms => (
    is      => 'ro',
    isa     => 'Num',
    default => 60_000,
);

has latency_threshold_ms => (
    is      => 'ro',
    isa     => 'Num',
    default => 15,
);

has socket_check_interval_ms => (
    is      => 'ro',
    isa     => 'Num',
    default => 5_000,
);

has server_selection_timeout_ms => (
    is      => 'ro',
    isa     => 'Num',
    default => 60_000,
);

has ewma_alpha => (
    is      => 'ro',
    isa     => 'Num',
    default => 0.2,
);

has link_options => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

has number_of_seeds => (
    is      => 'ro',
    isa     => 'Num',
    lazy    => 1,
    builder => '_build_number_of_seeds',
);

# servers, links and rtt_ewma_ms are all hashes on server address

has servers => (
    is      => 'ro',
    isa     => 'HashRef[MongoDB::_Server]',
    default => sub { {} },
);

has links => (
    is      => 'ro',
    isa     => 'HashRef[MongoDB::_Link]',
    default => sub { {} },
);

has rtt_ewma_ms => (
    is      => 'ro',
    isa     => 'HashRef[Num]',
    default => sub { {} },
);

#--------------------------------------------------------------------------#
# builders
#--------------------------------------------------------------------------#

sub _build_number_of_seeds {
    my ($self) = @_;
    return scalar @{ $self->uri->hostpairs };
}

sub BUILD {
    my ($self) = @_;
    my $type = $self->type;

    if ( my $set_name = $self->uri->options->{replicaSet} ) {
        $self->_set_replica_set_name($set_name);
        if ( $type eq 'Single' || $type eq 'ReplicaSetNoPrimary' ) {
            # these are valid, so nothing to do here
        }
        elsif ( $type eq 'Unknown' ) {
            $self->_set_type('ReplicaSetNoPrimary');
        }
        else {
            confess
              "Internal error: cluster with set name '$set_name' may not be initialized as type '$type'";
        }
    }

    my @addresses = @{ $self->uri->hostpairs };

    if ( $type eq 'Single' && @addresses > 1 ) {
        confess
          "Internal error: cluster type 'Single' cannot be used with multiple addresses: @addresses";
    }

    $self->_add_address_as_unknown($_) for @addresses;

    return;
}

#--------------------------------------------------------------------------#
# public methods
#--------------------------------------------------------------------------#

sub all_servers { return values %{ $_[0]->servers } }

sub check_address {
    my ( $self, $address ) = @_;

    if ( my $link = $self->links->{$address} ) {
        $self->_update_cluster_from_link( $address, $link );
    }
    else {
        # initialize_link will call update_cluster_from_link
        $self->_initialize_link($address);
    }

    return;
}

sub close_all_links {
    my ($self) = @_;
    delete $self->links->{ $_->address } for $self->all_servers;
    return;
}

sub get_readable_link {
    my ( $self, $read_pref ) = @_;

    my $mode = $read_pref ? lc $read_pref->mode : 'primary';
    my $method =
      $self->type eq any(qw/Single Sharded/) ? '_find_any_link' : "_find_${mode}_link";

    if ( my $link = $self->_selection_timeout( $method, $read_pref ) ) {
        return $link;
    }
    else {
        MongoDB::ConnectionError->throw(
            "No readable server matching read preference available");
    }
}

sub get_specific_link {
    my ( $self, $address ) = @_;
    my $server = $self->servers->{$address};
    if ( $server
        && ( my $link = $self->_selection_timeout( '_get_server_link', $server ) ) )
    {
        return $link;
    }
    else {
        MongoDB::ConnectionError->throw("Server $address is no longer available");
    }
}

sub get_writable_link {
    my ($self) = @_;

    my $method =
      $self->type eq any(qw/Single Sharded/) ? '_find_any_link' : "_find_primary_link";

    if ( my $link = $self->_selection_timeout($method) ) {
        return $link;
    }
    else {
        MongoDB::ConnectionError->throw("No writable server available");
    }
}

sub scan_all_servers {
    my ($self) = @_;

    my ( $next, @ordinary, @to_check );
    my $start_time = [ gettimeofday() ];

    # anything not updated since scan start is eligible for a check; when all servers
    # are updated, the loop terminates
    while (1) {
        last
          unless @to_check = grep { !$_->updated_since($start_time) } $self->all_servers;

        if ( $next = first { $_->type eq 'RSPrimary' } @to_check ) {
            $self->check_address( $next->address );
        }
        elsif ( $next = first { $_->type eq 'PossiblePrimary' } @to_check ) {
            $self->check_address( $next->address );
        }
        elsif ( @ordinary = grep { $_->type eq none(qw/Unknown RSGhost/) } @to_check ) {
            $self->_check_oldest_server(@ordinary);
        }
        else {
            $self->_check_oldest_server(@to_check);
        }
    }

    return;
}

#--------------------------------------------------------------------------#
# private methods
#--------------------------------------------------------------------------#

sub _add_address_as_unknown {
    my ( $self, $address, $last_update ) = @_;

    $self->servers->{$address} = MongoDB::_Server->new(
        address          => $address,
        last_update_time => $last_update || EPOCH,
    );

    return;
}

sub _check_oldest_server {
    my ( $self, @to_check ) = @_;

    my @ordered =
      map { $_->[0] }
      sort { $a->[1] <=> $b->[1] || rand() <=> rand() } # random if equal
      map { [ $_, $_->last_update_time->[0] ] }         # ignore partial secs
      @to_check;

    $self->check_address( $ordered[0]->address );

    return;
}

sub _check_wire_versions {
    my ($self) = @_;

    for my $server ( grep { $_->is_available } $self->all_servers ) {
        my ( $server_min_wire_version, $server_max_wire_version ) =
          @{ $server->is_master }{qw/minWireVersion maxWireVersion/};

        if (   ( $server_min_wire_version || 0 ) > $self->max_wire_version
            || ( $server_max_wire_version || 0 ) < $self->min_wire_version )
        {
            MongoDB::Error->throw(
                "Incompatible wire protocol version. This version of the MongoDB driver is not compatible with the server. You probably need to upgrade this library."
            );
        }
    }

    return;
}

sub _dump {
    my ($self) = @_;
    printf( "Cluster type: %s\n", $self->type );
    printf( "Replica set: %s\n",  $self->replica_set_name );
    printf( "%s (%s)\n",          $_->address, $_->type ) for $self->all_servers;
    return;
}

sub _find_any_link {
    my ( $self ) = @_;
    return $self->_get_link_in_latency_window(
        [ grep { $_->is_available } $self->all_servers ] );
}

sub _find_nearest_link {
    my ( $self, $read_pref ) = @_;
    my @candidates = ( $self->_primaries, $self->_secondaries($read_pref) );
    return $self->_get_link_in_latency_window( \@candidates );
}

sub _find_primary_link {
    my $self = shift;
    if ( my $primary = first { $_->is_writable } $self->all_servers ) {
        return $self->_get_server_link($primary);
    }
    return undef;
}

sub _find_primarypreferred_link {
    my ( $self, $read_pref ) = @_;
    return $self->_find_primary_link || $self->_find_secondary_link($read_pref);
}

sub _find_secondary_link {
    my ( $self, $read_pref ) = @_;

    my @candidates = $self->_secondaries($read_pref);
    return $self->_get_link_in_latency_window( \@candidates );
}

sub _find_secondarypreferred_link {
    my ( $self, $read_pref ) = @_;
    return $self->_find_secondary_link($read_pref) || $self->_find_primary_link;
}

sub _get_link_in_latency_window {
    my ( $self, $servers ) = @_;

    # order servers by RTT EWMA
    my $rtt_hash = $self->rtt_ewma_ms;
    my @candidates =
      sort { $a->{rtt} <=> $b->{rtt} }
      map { { server => $_, address => $_->address, rtt => $rtt_hash->{ $_->address } } }
      @$servers;

    my ( @links, $max_rtt );

    # take first valid link and any links from servers with RTT EWMA within
    # the latency window from the first server
    for my $c (@candidates) {
        last if @links && $c->{rtt} < $max_rtt;
        if ( $c->{link} = $self->_get_server_link( $c->{server} ) ) {
            $max_rtt = $c->{rtt} + $self->latency_threshold_ms if !@links;
            push @links, $c;
        }
    }

    # return a randomly chosen link if there any to choose
    return @links ? $links[ int( rand(@links) ) ]->{link} : undef;
}

sub _get_server_link {
    my ( $self, $server ) = @_;
    my $address = $server->address;
    my $link = $self->links->{$address};
    return $link && $link->remote_connected ? $link : $self->_initialize_link($address);
}

sub _has_no_primaries {
    my ($self) = @_;
    return 0 == $self->_primaries;
}

sub _initialize_link {
    my ( $self, $address ) = @_;

    my $link = try { MongoDB::_Link->new( $address, $self->link_options )->connect };

    if ( $link ) {
        $self->links->{$address} = $link;
        $self->_update_cluster_from_link( $address, $link );
        return $self->links->{$address}; # might be undef if the update killed it
    }

    # connection failed, so update cluster with Unknown description
    my $new_server = MongoDB::_Server->new(
        address          => $address,
        last_update_time => [ gettimeofday() ],
        is_master        => {},
    );
    $self->_update_cluster_from_server_desc( $address, $new_server );
    return;
}

sub _primaries {
    return grep { $_->type eq 'RSPrimary' } $_[0]->all_servers;
}

sub _remove_address {
    my ( $self, $address ) = @_;
    delete $self->$_->{$address} for qw/servers links rtt_ewma_ms/;
    return;
}

sub _remove_server {
    my ( $self, $server ) = @_;
    $self->_remove_address( $server->address );
    return;
}

sub _reset_server_to_unknown {
    my ( $self, $server ) = @_;

    my ( $address, $update ) = @{$server}{qw/address last_update_time/};
    $self->_remove_server($server);
    $self->_add_address_as_unknown( $address, $update );

    return;
}

sub _secondaries {
    my ( $self, $read_pref ) = @_;

    my @secondaries = grep { $_->type eq 'RSSecondary' } $_[0]->all_servers;

    if ( $read_pref->has_empty_tagsets ) {
        return @secondaries;
    }
    else {
        my $ts = $read_pref->tagset;
        return grep { $_->matches_tagset($ts) } @secondaries;
    }
}

# this implements the server selection timeout around whatever actual method
# is used for returning a link
sub _selection_timeout {
    my ( $self, $method, @args ) = @_;

    my $start_time = [ gettimeofday() ];

    while (1) {
        $self->_check_wire_versions;
        if ( my $link = $self->$method(@args) ) {
            return $link;
        }
        last if 1000 * tv_interval($start_time) > $self->server_selection_timeout_ms;
    }
    continue {
        usleep(15_000); # 15ms delay before rescanning
        $self->scan_all_servers;
    }

    return;             # caller has to throw appropriate timeout error
}

sub _update_cluster_from_link {
    my ( $self, $address, $link ) = @_;

    my $start_time = [ gettimeofday() ];
    my $is_master  = eval { $self->_send_admin_command( $link, [ ismaster => 1 ] )->result };
    my $end_time   = [ gettimeofday() ];
    my $rtt_ms     = int( 1000 * tv_interval( $start_time, $end_time ) );

    # if no $is_master, then we're updating with an Unknown
    my $new_server = MongoDB::_Server->new(
        address          => $address,
        last_update_time => $end_time,
        ( $is_master ? ( rtt_ms => $rtt_ms, is_master => $is_master ) : () ),
    );

    $self->_update_cluster_from_server_desc( $address, $new_server );

    return;
}

sub _update_cluster_from_server_desc {
    my ($self, $address, $new_server) = @_;

    # ignore spurious result not in the set; this isn't strictly necessary
    # for single-threaded operation, but spec tests expect it and if we
    # have async monitoring in the future, late responses could come back
    # after a server has been removed
    return unless $self->servers->{$address};

    $self->_update_ewma( $address, $new_server );

    # must come after ewma update
    $self->servers->{$address} = $new_server;

    my $method = "_update_" . $self->type;
    $self->$method( $address, $new_server );

    # if link is still around, tag it with server specifics
    $self->_update_link_metadata( $address, $new_server );

    return $new_server;
}

sub _update_ewma {
    my ( $self, $address, $new_server ) = @_;

    if ( $new_server->type eq 'Unknown' ) {
        delete $self->rtt_ewma_ms->{$address};
    }
    else {
        my $old_avg = $self->rtt_ewma_ms->{$address};
        my $alpha   = $self->ewma_alpha;
        my $rtt_ms  = $new_server->rtt_ms;
        $self->rtt_ewma_ms->{$address} =
          defined($old_avg) ? ( $alpha * $rtt_ms + ( 1 - $alpha ) * $old_avg ) : $rtt_ms;
    }

    return;
}

sub _update_link_metadata {
    my ( $self, $address, $server ) = @_;

    # if the link didn't get dropped from the cluster during the update, we
    # attach the server so the link knows where it came from
    if ( $self->links->{$address} ) {
        $self->links->{$address}->set_metadata($server);
    }

    return;
}

sub _update_rs_with_primary_from_member {
    my ( $self, $new_server ) = @_;

    if (  !$self->servers->{ $new_server->address }
        || $self->replica_set_name ne $new_server->set_name )
    {
        $self->_remove_server($new_server);
    }

    if ( $self->_has_no_primaries ) {
        $self->_set_type('ReplicaSetNoPrimary');

        # flag possible primary to amend scanning order
        my $primary = $new_server->primary;
        if (   length($primary)
            && $self->servers->{$primary}
            && $self->servers->{$primary}->type eq 'Unknown' )
        {
            $self->servers->{$primary}->_set_type('PossiblePrimary');
        }
    }

    return;
}

sub _update_rs_with_primary_from_primary {
    my ( $self, $new_server ) = @_;

    if ( !length $self->replica_set_name ) {
        $self->_set_replica_set_name( $new_server->set_name );
    }
    elsif ( $self->replica_set_name ne $new_server->set_name ) {
        # We found a primary but it doesn't have the setName
        # provided by the user or previously discovered
        $self->_remove_server($new_server);
        return;
    }

    # possibly invalidate an old primary (even if more than one!)
    for my $old_primary ( $self->_primaries ) {
        $self->_reset_server_to_unknown($old_primary)
          unless $old_primary->address eq $new_server->address;
    }

    # unknown set members need to be added to the cluster
    my %set_members =
      map { $_ => undef } map { @{ $new_server->$_ } } qw/hosts passives arbiters/;

    $self->_add_address_as_unknown($_)
      for grep { !exists $self->servers->{$_} } keys %set_members;

    # cluster servers no longer in the set need to be removed
    $self->_remove_address($_)
      for grep { !exists $set_members{$_} } keys %{ $self->servers };

    return;
}

sub _update_rs_without_primary {
    my ( $self, $new_server ) = @_;

    if ( !length $self->replica_set_name ) {
        $self->_set_replica_set_name( $new_server->set_name );
    }
    elsif ( $self->replica_set_name ne $new_server->set_name ) {
        $self->_remove_server($new_server);
        return;
    }

    # unknown set members need to be added to the cluster
    my %set_members =
      map { $_ => undef } map { @{ $new_server->$_ } } qw/hosts passives arbiters/;

    $self->_add_address_as_unknown($_)
      for grep { !exists $self->servers->{$_} } keys %set_members;

    # flag possible primary to amend scanning order
    my $primary = $new_server->primary;
    if (   length($primary)
        && $self->servers->{$primary}
        && $self->servers->{$primary}->type eq 'Unknown' )
    {
        $self->servers->{$primary}->_set_type('PossiblePrimary');
    }

    return;
}

#--------------------------------------------------------------------------#
# update methods by cluster types: behavior in each depends on new server
# type received
#--------------------------------------------------------------------------#

sub _update_ReplicaSetNoPrimary {
    my ( $self, $address, $new_server ) = @_;

    my $server_type = $new_server->type;

    if ( $server_type eq 'RSPrimary' ) {
        $self->_set_type('ReplicaSetWithPrimary');
        $self->_update_rs_with_primary_from_primary($new_server);
        # cluster changes might have removed all primaries
        $self->_set_type('ReplicaSetNoPrimary')
          if $self->_has_no_primaries;
    }
    elsif ( $server_type eq any(qw/ RSSecondary RSArbiter RSOther /) ) {
        $self->_update_rs_without_primary($new_server);
    }
    elsif ( $server_type eq any(qw/Standalone Mongos/) ) {
        $self->_remove_server($new_server);
    }
    else {
        # Unknown or RSGhost are no-ops
    }

    return;
}

sub _update_ReplicaSetWithPrimary {
    my ( $self, $address, $new_server ) = @_;

    my $server_type = $new_server->type;

    if ( $server_type eq 'RSPrimary' ) {
        $self->_update_rs_with_primary_from_primary($new_server);
    }
    elsif ( $server_type eq any(qw/ RSSecondary RSArbiter RSOther /) ) {
        $self->_update_rs_with_primary_from_member($new_server);
    }
    elsif ( $server_type eq any(qw/Unknown Standalone Mongos/) ) {
        $self->_remove_server($new_server)
          unless $server_type eq 'Unknown';
    }
    else {
        # RSGhost is no-op
    }

    # cluster changes might have removed all primaries
    $self->_set_type('ReplicaSetNoPrimary')
      if $self->_has_no_primaries;

    return;
}

sub _update_Sharded {
    my ( $self, $address, $new_server ) = @_;

    if ( $new_server->type eq any(qw/Unknown Mongos/) ) {
        # no-op
    }
    else {
        $self->_remove_server($new_server);
    }

    return;
}

sub _update_Single {
    my ( $self, $address, $new_server ) = @_;
    return; # ClusterType Single never changes type or membership
}

sub _update_Unknown {
    my ( $self, $address, $new_server ) = @_;

    my $server_type = $new_server->type;

    if ( $server_type eq 'Standalone' ) {
        if ( $self->number_of_seeds == 1 ) {
            $self->_set_type('Single');
        }
        else {
            # a standalone server with multiple seeds is a replica set member
            # in maintenance mode; we drop it and may pick it up later if it
            # rejoins the replica set.
            $self->_remove_address($address);
        }
    }
    elsif ( $server_type eq 'Mongos' ) {
        $self->_set_type('Sharded');
    }
    elsif ( $server_type eq 'RSPrimary' ) {
        $self->_set_type('ReplicaSetWithPrimary');
        $self->_update_rs_with_primary_from_primary($new_server);
        # cluster changes might have removed all primaries
        $self->_set_type('ReplicaSetNoPrimary')
          if $self->_has_no_primaries;
    }
    elsif ( $server_type eq any(qw/ RSSecondary RSArbiter RSOther /) ) {
        $self->_set_type('ReplicaSetNoPrimary');
        $self->_update_rs_without_primary($new_server);
    }
    else {
        # Unknown or RSGhost are no-ops
    }

    return;
}

__PACKAGE__->meta->make_immutable;

1;

# vim: ts=4 sts=4 sw=4 et:
