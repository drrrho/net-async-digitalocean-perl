use strict;
use warnings;

use Test::More;
use Test::Exception;

use Data::Dumper;
$Data::Dumper::Indent = 1;

my $warn = shift @ARGV;
unless ($warn) {
    close STDERR;
    open (STDERR, ">/dev/null");
    select (STDERR); $| = 1;
}

use constant DONE => 1;

use JSON;
use HTTP::Status qw(:constants);

use IO::Async::Loop;
my $loop = IO::Async::Loop->new;

# $ENV{DIGITALOCEAN_API} //= 'http://0.0.0.0:8080/';

use Net::Async::DigitalOcean;

eval {
    Net::Async::DigitalOcean->new( loop => $loop, endpoint => undef );
}; if ($@) {
    plan skip_all => 'no endpoint defined ( e.g. export DIGITALOCEAN_API=http://0.0.0.0:8080/ )';
    done_testing;
}

{ # initalize and reset server state
    my $do = Net::Async::DigitalOcean->new( loop => $loop, endpoint => undef );
    eval {
	$do->meta_reset->get;
    }; if ($@) {
	diag "meta interface missing => no reset";
    }
}

if (DONE) {
    my $AGENDA = q{droplet associates: };

    my $do = Net::Async::DigitalOcean->new( loop => $loop, endpoint => undef );
    $do->start_actionables( 2 );

    my $f;

    my $dro = $do->create_droplet({
	"name"       => "example.com",
	"region"     => "nyc3",
	"size"       => "s-1vcpu-1gb",
	"image"      => "openfaas-18-04",
	"ssh_keys"   => [],
	"backups"    => 'true',
	"ipv6"       => 'true',
	"monitoring" => 'true',
	"tags"       => [	    "env:prod",	    "web"	    ],
	"user_data"  => "#cloud-config\nruncmd:\n  - touch /test.txt\n",
#	"vpc_uuid"   => "760e09ef-dc84-11e8-981e-3cfdfeaae000"
				  })->get;

    my $vol = $do->create_volume({
	"size_gigabytes"   => 10,
	"name"             => "example",
	"description"      => "Block store for examples",
	"region"           => "nyc1",
	"filesystem_type"  => "ext4",
	"filesystem_label" => "example",
	'tags'             => [],
			       })->get; $vol = $vol->{volume};
#warn Dumper $vol; 
    $do->volume_attach( $vol->{id}, { type       => 'attach',
				      droplet_id => $dro->{id},
				      region     => $vol->{region}->{slug} } )->get;
    my $vol2 = $do->create_volume({
	"size_gigabytes"   => 10,
	"name"             => "example2",
	"description"      => "Block store for examples",
	"region"           => "nyc1",
	"filesystem_type"  => "ext4",
	"filesystem_label" => "example",
	'tags'             => [],
			       })->get; $vol2 = $vol2->{volume};
    $do->volume_attach( $vol2->{id}, { type       => 'attach',
				       droplet_id => $dro->{id},
				       region     => $vol2->{region}->{slug} } )->get;
#-- list this
    $f = $do->associated_resources( id => $dro->{id} );
    isa_ok($f, 'IO::Async::Future', $AGENDA.'future');
    my $ass = $f->get;
    ok( eq_set( [ map { $_->{id} } @{ $ass->{volumes} } ],
		[ $vol->{id}, $vol2->{id} ]), $AGENDA.'found attached volumes');
    ok( eq_set( [ map { $_->{id} } @{ $ass->{snapshots} } ],
		[]), $AGENDA.'found no attached snapshots');
    ok( eq_set( [ map { $_->{id} } @{ $ass->{volume_snapshots} } ],
		[]), $AGENDA.'found no attached volume snapshots');
#--
    $do->snapshots ( volume => $vol->{id} )->get;
    $do->perform_droplet_actions( id => $dro->{id}, 'snapshot' )->get;

    $ass = $do->associated_resources( id => $dro->{id} )->get;
    my $sns = $do->snapshots ( droplet => $dro->{id} )->get; $sns = $sns->{snapshots};

    ok( eq_set( [ map { $_->{id} } @{ $ass->{volumes} } ],
		[ $vol->{id}, $vol2->{id} ]), $AGENDA.'found attached volumes');
    ok( eq_set( [ map { $_->{id} } @{ $ass->{snapshots} } ],
		[ map { $_->{id} } @$sns ]), $AGENDA.'found one attached snapshots');
    ok( eq_set( [ map { $_->{id} } @{ $ass->{volume_snapshots} } ],
		[]), $AGENDA.'found no attached volume snapshots');
#--
    $do->create_snapshot( $vol->{id}, { "name" => "big-data-snapshot1475261774" } )->get;
#--
    $ass = $do->associated_resources( id => $dro->{id} )->get;
    ok( eq_set ([ map { $_->{name} } @{ $ass->{volume_snapshots} } ], [ 'big-data-snapshot1475261774' ]), $AGENDA.'volume snapshot');
# warn Dumper $ass;
#--
    $f = $do->delete_with_associated_resources( id => $dro->{id} );
    isa_ok($f, 'IO::Async::Future', $AGENDA.'future for assoc');

    my $destroyed;
    $loop->watch_time( after => $_, code => sub { diag "polling associated resources " if $warn;
						 eval {
						     $ass = $do->associated_resources( check_status => $dro->{id} )->get;
#warn Dumper $ass;
						     is( $ass->{droplet}->{id}, $dro->{id}, $AGENDA.'status id');
						     is( $ass->{droplet}->{name}, $dro->{name}, $AGENDA.'status name');
						     diag "destroyed: ". $ass->{droplet}->{destroyed_at} if defined $ass->{droplet}->{destroyed_at};
						     $destroyed //= $ass->{droplet}->{destroyed_at};
						     ok($ass->{droplet}->{destroyed_at}, $AGENDA.'destroyed is destroyed') if $destroyed;
						     is((scalar @{$ass->{resources}->{volumes}}),   2, $AGENDA.'volumes pending');
						     is((scalar @{$ass->{resources}->{snapshots}}), 1, $AGENDA.'snapshots pending');
						     is((scalar @{$ass->{resources}->{volume_snapshots}}), 1, $AGENDA.'volume snapshots pending');
						     
						 }; if ($@) {
						     like ($@, qr/not found/i, $AGENDA.'droplet not found anymore');
						 } else { # it was ok
#						     ok( eq_set([qw(volumes snapshots volume_snapshots)], [keys %$ass]), $AGENDA.'found associations still there');
#						     warn Dumper $ass;
						 }
		       } ) for (1, 3, 5, 7, 9);
    $f->get; # block here
    ok( 1, $AGENDA."deleting all associated resources done");

    throws_ok {
	$do->associated_resources( id => $dro->{id} )->get;
    } qr/not found/i, $AGENDA.'droplet not found by id';

    $loop->watch_time( after => 20, code => sub { diag "stopping loop" if $warn; $loop->stop; });
    $loop->run;

# last $ass test
    ok( $ass->{droplet}->{destroyed_at}, $AGENDA."droplet destroyed");
    map { ok($_->{destroyed_at}, $AGENDA."$_ destroyed") } @{$ass->{resources}->{volumes}};
    map { ok($_->{destroyed_at}, $AGENDA."$_ destroyed") } @{$ass->{resources}->{snapshots}};
    map { ok($_->{destroyed_at}, $AGENDA."$_ destroyed") } @{$ass->{resources}->{volume_snapshots}};
}

done_testing;

__END__
